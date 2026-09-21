-- =============================================================================
--  Самотест схемы: выполняется на пустой БД после 001_schema.sql
--  psql -v ON_ERROR_STOP=1 -f db/900_selftest.sql
--  Все проверки — через ASSERT; при ошибке скрипт падает с описанием.
--  Выполняется в транзакции и откатывается — БД остаётся чистой.
-- =============================================================================
BEGIN;
SET LOCAL timezone TO 'UTC';

-- ---------- 1. Сотрудники, токены, аутентификация ----------
DO $$
DECLARE
    v_emp   timetrack.employees;
    v_tok   text;
    v_auth  record;
BEGIN
    v_emp := timetrack.fn_upsert_employee('EMP-001', 'Иванов Иван', 'ivanov@example.com', 'Склад', 'Кладовщик',
                                          'Europe/Moscow', NULL, 'HR-77', NULL, 'selftest');
    ASSERT v_emp.status = 'active', 'новый сотрудник должен быть active';
    ASSERT v_emp.timezone = 'Europe/Moscow';

    -- обновление без часового пояса/статуса не должно их сбрасывать
    v_emp := timetrack.fn_upsert_employee('EMP-001', 'Иванов Иван И.', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'selftest');
    ASSERT v_emp.timezone = 'Europe/Moscow', 'timezone сброшен при обновлении';
    ASSERT v_emp.email = 'ivanov@example.com', 'email сброшен при обновлении';

    BEGIN
        PERFORM timetrack.fn_upsert_employee('EMP-BAD', 'X', NULL, NULL, NULL, 'Mars/Olympus', NULL, NULL, NULL, 'selftest');
        RAISE EXCEPTION 'ожидалась ошибка неверного часового пояса';
    EXCEPTION WHEN invalid_parameter_value OR SQLSTATE '22023' THEN
        NULL;
    END;

    v_tok := timetrack.fn_issue_token('Терминал у входа', 'device', NULL, 'Проходная');
    ASSERT length(v_tok) = 64, 'токен должен быть 64 hex-символа';
    SELECT * INTO v_auth FROM timetrack.fn_authenticate(v_tok);
    ASSERT v_auth.role = 'device', 'аутентификация по токену устройства';
    SELECT * INTO v_auth FROM timetrack.fn_authenticate('wrong-token-000000000000');
    ASSERT v_auth IS NULL, 'неверный токен не должен аутентифицироваться';
    SELECT * INTO v_auth FROM timetrack.fn_authenticate(NULL);
    ASSERT v_auth IS NULL, 'NULL токен';

    -- истёкший токен
    v_tok := timetrack.fn_issue_token('Старый', 'hr', NULL, NULL, now() - interval '1 minute');
    SELECT * INTO v_auth FROM timetrack.fn_authenticate(v_tok);
    ASSERT v_auth IS NULL, 'истёкший токен не должен работать';
    RAISE NOTICE 'OK 1: сотрудники и токены';
END $$;

-- ---------- 2. Согласие, регистрация, отметки ----------
DO $$
DECLARE
    r record;
    v_id bigint;
BEGIN
    -- без согласия распознавание лица отклоняется
    SELECT * INTO r FROM timetrack.fn_clock('EMP-001', 'auto', 'face', 'kiosk-1', 'Проходная', 0.97, NULL, 'h1', 'req-0');
    ASSERT r.ok = false AND r.code = 'consent_missing', 'ожидался consent_missing, получено ' || r.code;

    PERFORM timetrack.fn_grant_consent('EMP-001', 'v1.0', 'written_form', 'Согласие №1', 'selftest');
    ASSERT timetrack.fn_has_consent('EMP-001');
    PERFORM timetrack.fn_record_enrollment('EMP-001', 'compreface', 'EMP-001', 'face-uuid-1', 'imghash', 'selftest');

    -- первая отметка = приход
    SELECT * INTO r FROM timetrack.fn_clock('EMP-001', 'auto', 'face', 'kiosk-1', 'Проходная', 0.97, NULL, 'h1', 'req-1',
                                            now() - interval '9 hours');
    ASSERT r.ok AND r.code = 'recorded' AND r.event_type = 'check_in', 'первая отметка: ' || r.code || ' ' || COALESCE(r.event_type,'-');
    ASSERT r.full_name LIKE 'Иванов%';
    v_id := r.event_id;

    -- повтор того же request_id → то же событие
    SELECT * INTO r FROM timetrack.fn_clock('EMP-001', 'auto', 'face', 'kiosk-1', 'Проходная', 0.97, NULL, 'h1', 'req-1');
    ASSERT r.duplicate AND r.code = 'duplicate_request' AND r.event_id = v_id, 'идемпотентность по request_id';

    -- антидребезг: другой request_id через 30 секунд → debounced, событие не создаётся
    SELECT * INTO r FROM timetrack.fn_clock('EMP-001', 'auto', 'face', 'kiosk-1', 'Проходная', 0.95, NULL, 'h2', 'req-2',
                                            now() - interval '9 hours' + interval '30 seconds');
    ASSERT r.duplicate AND r.code = 'debounced' AND r.event_id = v_id, 'антидребезг: ' || r.code;

    -- через 8 часов auto → уход
    SELECT * INTO r FROM timetrack.fn_clock('EMP-001', 'auto', 'face', 'kiosk-1', 'Проходная', 0.96, NULL, 'h3', 'req-3',
                                            now() - interval '1 hour');
    ASSERT r.ok AND r.event_type = 'check_out', 'auto после прихода должен быть уход, получено ' || COALESCE(r.event_type, r.code);

    -- captured_at из будущего отвергается, событие пишется с now()
    SELECT * INTO r FROM timetrack.fn_clock('EMP-001', 'check_in', 'manual', NULL, NULL, NULL, NULL, NULL, 'req-4',
                                            now() + interval '2 days', '{}'::jsonb, 'EMP-001');
    ASSERT r.ok AND r.occurred_at <= now() + interval '1 second', 'captured_at из будущего должен быть отвергнут';
    ASSERT (SELECT metadata ? 'captured_at_rejected' FROM timetrack.attendance_events WHERE id = r.event_id);

    -- неизвестный сотрудник
    SELECT * INTO r FROM timetrack.fn_clock('EMP-404', 'auto', 'face');
    ASSERT r.ok = false AND r.code = 'employee_not_found';

    ASSERT (SELECT count(*) FROM timetrack.attendance_events WHERE employee_id = 'EMP-001') = 3, 'должно быть 3 события';
    ASSERT (SELECT count(*) FROM timetrack.hr_sync_outbox WHERE event_kind = 'attendance.created') = 3, 'outbox по событиям';
    ASSERT (SELECT count(*) FROM timetrack.audit_log WHERE action LIKE 'attendance.%') >= 3, 'аудит по отметкам';
    RAISE NOTICE 'OK 2: согласие, регистрация, отметки';
END $$;

-- ---------- 3. Забытый уход (>16 ч) ----------
DO $$
DECLARE
    r record;
BEGIN
    PERFORM timetrack.fn_upsert_employee('EMP-002', 'Петрова Анна', 'petrova@example.com', 'Офис', NULL, 'UTC', NULL, NULL, NULL, 'selftest');
    PERFORM timetrack.fn_grant_consent('EMP-002', 'v1.0');
    INSERT INTO timetrack.attendance_events (employee_id, event_type, occurred_at, source)
    VALUES ('EMP-002', 'check_in', now() - interval '30 hours', 'face');
    SELECT * INTO r FROM timetrack.fn_clock('EMP-002', 'auto', 'face', 'kiosk-1');
    ASSERT r.event_type = 'check_in', 'после 30 часов auto должен дать новый приход, получено ' || r.event_type;
    ASSERT (SELECT metadata ? 'previous_session_incomplete' FROM timetrack.attendance_events WHERE id = r.event_id);
    RAISE NOTICE 'OK 3: забытый уход';
END $$;

-- ---------- 4. Отчётность: сессии, дневная сводка, табель ----------
DO $$
DECLARE
    d record;
    t record;
    n int;
BEGIN
    -- EMP-003: график 09:00-18:00 пн-пт, обед 60 мин, пояс Europe/Berlin
    PERFORM timetrack.fn_upsert_employee('EMP-003', 'Schmidt Anna', 'schmidt@example.com', 'Офис', NULL, 'Europe/Berlin',
        '{"start":"09:00","end":"18:00","days":[1,2,3,4,5],"break_minutes":60}'::jsonb, NULL, NULL, 'selftest');
    -- Понедельник 2026-06-01 (ISO dow 1): приход 09:15, уход 18:30 без обеда → 555 мин, минус авто-обед 60 = 495
    INSERT INTO timetrack.attendance_events (employee_id, event_type, occurred_at, source) VALUES
      ('EMP-003', 'check_in',  '2026-06-01 09:15+02', 'face'),
      ('EMP-003', 'check_out', '2026-06-01 18:30+02', 'face'),
    -- Вторник: две сессии с обедом 45 мин (09:00-13:00, 13:45-18:00) → 495 отработано, перерыв 45 → доудержание 15 → 480
      ('EMP-003', 'check_in',  '2026-06-02 09:00+02', 'face'),
      ('EMP-003', 'check_out', '2026-06-02 13:00+02', 'face'),
      ('EMP-003', 'check_in',  '2026-06-02 13:45+02', 'face'),
      ('EMP-003', 'check_out', '2026-06-02 18:00+02', 'manual'),
    -- Среда: приход без ухода (незакрытая смена)
      ('EMP-003', 'check_in',  '2026-06-03 08:50+02', 'face'),
    -- Четверг: ничего (прогул). Пятница: ничего (прогул). Суббота: работа в выходной 10:00-14:00 → 240 сверхурочно
      ('EMP-003', 'check_in',  '2026-06-06 10:00+02', 'face'),
      ('EMP-003', 'check_out', '2026-06-06 14:00+02', 'face'),
    -- Ночная смена через полночь в воскресенье 22:00 → пн 06:00 (относится к воскресенью)
      ('EMP-003', 'check_in',  '2026-06-07 22:00+02', 'face'),
      ('EMP-003', 'check_out', '2026-06-08 06:00+02', 'face');

    SELECT count(*) INTO n FROM timetrack.fn_sessions('EMP-003', '2026-06-01', '2026-06-07');
    ASSERT n = 6, 'ожидалось 6 сессий, получено ' || n;

    SELECT * INTO d FROM timetrack.fn_daily_summary('EMP-003', '2026-06-01', '2026-06-07') WHERE work_date = '2026-06-01';
    ASSERT d.scheduled AND d.scheduled_minutes = 480, 'пн: план 480, получено ' || d.scheduled_minutes;
    ASSERT d.worked_minutes = 495, 'пн: отработано 495, получено ' || d.worked_minutes;
    ASSERT d.break_minutes = 60, 'пн: авто-обед 60, получено ' || d.break_minutes;
    ASSERT d.late_minutes = 15, 'пн: опоздание 15, получено ' || d.late_minutes;
    ASSERT d.overtime_minutes = 15, 'пн: сверхурочно 15, получено ' || d.overtime_minutes;
    ASSERT d.status = 'late', 'пн: статус late, получено ' || d.status;

    SELECT * INTO d FROM timetrack.fn_daily_summary('EMP-003', '2026-06-01', '2026-06-07') WHERE work_date = '2026-06-02';
    ASSERT d.sessions = 2 AND d.worked_minutes = 480, 'вт: 2 сессии, 480 мин, получено ' || d.sessions || '/' || d.worked_minutes;
    ASSERT d.break_minutes = 60, 'вт: перерыв 45 + доудержание 15 = 60, получено ' || d.break_minutes;
    ASSERT d.status = 'present' AND d.late_minutes = 0 AND d.early_leave_minutes = 0, 'вт: present';

    SELECT * INTO d FROM timetrack.fn_daily_summary('EMP-003', '2026-06-01', '2026-06-07') WHERE work_date = '2026-06-03';
    ASSERT d.status = 'incomplete' AND d.incomplete AND d.worked_minutes = 0, 'ср: незакрытая смена';
    ASSERT d.break_minutes = 0, 'ср: у незакрытой смены нет перерывов, получено ' || d.break_minutes;

    SELECT * INTO d FROM timetrack.fn_daily_summary('EMP-003', '2026-06-01', '2026-06-07') WHERE work_date = '2026-06-04';
    ASSERT d.status = 'absent', 'чт: прогул, получено ' || d.status;
    ASSERT d.break_minutes = 0 AND d.worked_minutes = 0, 'чт: без отметок нет ни работы, ни перерывов';

    -- короткая сессия (20 мин) в пятницу: удержание обеда не может превышать отработанное
    INSERT INTO timetrack.attendance_events (employee_id, event_type, occurred_at, source) VALUES
      ('EMP-003', 'check_in',  '2026-06-05 09:00+02', 'face'),
      ('EMP-003', 'check_out', '2026-06-05 09:20+02', 'face');
    SELECT * INTO d FROM timetrack.fn_daily_summary('EMP-003', '2026-06-01', '2026-06-07') WHERE work_date = '2026-06-05';
    ASSERT d.worked_minutes = 0 AND d.break_minutes = 20 AND d.status = 'present', 'пт: 20 мин работы целиком уходят в обед, получено ' || d.worked_minutes || '/' || d.break_minutes || '/' || d.status;
    SELECT count(*) INTO n FROM timetrack.fn_sessions('EMP-003', '2026-06-01', '2026-06-07');
    ASSERT n = 7, 'после пятницы ожидалось 7 сессий, получено ' || n;

    SELECT * INTO d FROM timetrack.fn_daily_summary('EMP-003', '2026-06-01', '2026-06-07') WHERE work_date = '2026-06-06';
    ASSERT NOT d.scheduled AND d.worked_minutes = 180 AND d.overtime_minutes = 180, 'сб: 240 мин минус авто-обед 60 = 180 сверхурочно, получено ' || d.worked_minutes;

    SELECT * INTO d FROM timetrack.fn_daily_summary('EMP-003', '2026-06-01', '2026-06-07') WHERE work_date = '2026-06-07';
    ASSERT d.sessions = 1 AND d.worked_minutes = 420 AND d.status = 'present', 'вс: ночная смена 480-60 = 420, получено ' || d.worked_minutes || ' ' || d.status;

    SELECT * INTO t FROM timetrack.fn_timesheet('EMP-003', '2026-06-01', '2026-06-07');
    ASSERT (t.totals ->> 'scheduled_days')::int = 5, 'табель: 5 плановых дней';
    ASSERT (t.totals ->> 'days_absent')::int = 1, 'табель: 1 прогул, получено ' || (t.totals ->> 'days_absent');
    ASSERT (t.totals ->> 'days_incomplete')::int = 1;
    ASSERT (t.totals ->> 'worked_minutes')::int = 495 + 480 + 0 + 180 + 420, 'табель: сумма минут, получено ' || (t.totals ->> 'worked_minutes');
    ASSERT jsonb_array_length(t.days) = 7 AND jsonb_array_length(t.sessions) = 7;
    ASSERT t.employee ->> 'full_name' = 'Schmidt Anna';

    -- табель по всем сотрудникам отдела
    SELECT count(*) INTO n FROM timetrack.fn_timesheet(NULL, '2026-06-01', '2026-06-07', 'Офис');
    ASSERT n = 2, 'в отделе Офис 2 активных сотрудника, получено ' || n;

    -- проблемные дни для напоминаний
    SELECT count(*) INTO n FROM timetrack.fn_attendance_issues('2026-06-01', '2026-06-07') i WHERE i.employee_id = 'EMP-003';
    ASSERT n = 1;
    RAISE NOTICE 'OK 4: отчётность';
END $$;

-- ---------- 5. Корректировки ----------
DO $$
DECLARE
    r    record;
    rv   record;
    v_ev bigint;
    v_req uuid;
BEGIN
    -- сотрудник хочет добавить пропущенный уход
    INSERT INTO timetrack.attendance_events (employee_id, event_type, occurred_at, source)
    VALUES ('EMP-002', 'check_in', now() - interval '3 days', 'face') RETURNING id INTO v_ev;

    SELECT * INTO r FROM timetrack.fn_request_correction('EMP-002', 'add', NULL, 'check_out', now() - interval '3 days' + interval '8 hours', 'Забыл отметиться на выходе', 'EMP-002');
    ASSERT r.ok AND r.code = 'created', 'запрос add: ' || r.code;
    v_req := (r.request ->> 'id')::uuid;

    -- чужое событие нельзя корректировать
    SELECT * INTO r FROM timetrack.fn_request_correction('EMP-001', 'change', v_ev, 'check_in', now() - interval '3 days', 'Хочу поменять чужое', 'EMP-001');
    ASSERT r.ok = false AND r.code = 'event_not_found', 'чужое событие: ' || r.code;

    -- без причины нельзя
    SELECT * INTO r FROM timetrack.fn_request_correction('EMP-002', 'void', v_ev, NULL, NULL, '', 'EMP-002');
    ASSERT r.ok = false AND r.code = 'reason_required';

    -- время из будущего
    SELECT * INTO r FROM timetrack.fn_request_correction('EMP-002', 'add', NULL, 'check_out', now() + interval '1 day', 'Тест', 'EMP-002');
    ASSERT r.ok = false AND r.code = 'time_in_future';

    -- HR одобряет добавление
    SELECT * INTO rv FROM timetrack.fn_review_correction(v_req, 'approved', 'Подтверждено по камерам', 'hr.manager');
    ASSERT rv.ok AND rv.code = 'approved', 'одобрение: ' || rv.code;
    ASSERT (rv.result_event ->> 'source') = 'correction' AND (rv.result_event ->> 'event_type') = 'check_out';
    ASSERT (rv.request ->> 'status') = 'approved' AND (rv.request ->> 'reviewed_by') = 'hr.manager';

    -- повторное решение невозможно
    SELECT * INTO rv FROM timetrack.fn_review_correction(v_req, 'rejected', NULL, 'hr.manager');
    ASSERT rv.ok = false AND rv.code = 'already_reviewed';

    -- изменение времени существующего события: старое помечается corrected
    SELECT * INTO r FROM timetrack.fn_request_correction('EMP-002', 'change', v_ev, 'check_in', now() - interval '3 days' - interval '20 minutes', 'Терминал завис, пришёл раньше', 'EMP-002');
    ASSERT r.ok, 'запрос change: ' || r.code;
    -- второй открытый запрос на то же событие запрещён
    SELECT * INTO rv FROM timetrack.fn_request_correction('EMP-002', 'void', v_ev, NULL, NULL, 'Дубль', 'EMP-002');
    ASSERT rv.ok = false AND rv.code = 'already_pending', 'дубль запроса: ' || rv.code;

    SELECT * INTO rv FROM timetrack.fn_review_correction((r.request ->> 'id')::uuid, 'approved', NULL, 'hr.manager');
    ASSERT rv.ok;
    ASSERT (SELECT status FROM timetrack.attendance_events WHERE id = v_ev) = 'corrected';
    ASSERT (SELECT superseded_by FROM timetrack.attendance_events WHERE id = v_ev) = (rv.result_event ->> 'id')::bigint;
    -- скорректированное событие не участвует в сессиях
    ASSERT (SELECT count(*) FROM timetrack.fn_sessions('EMP-002', (now() - interval '4 days')::date, now()::date)
             WHERE in_event_id = v_ev) = 0, 'старое событие не должно попадать в сессии';

    -- отклонение
    SELECT * INTO r FROM timetrack.fn_request_correction('EMP-002', 'add', NULL, 'check_in', now() - interval '1 day', 'Просто так', 'EMP-002');
    SELECT * INTO rv FROM timetrack.fn_review_correction((r.request ->> 'id')::uuid, 'rejected', 'Нет подтверждения', 'hr.manager');
    ASSERT rv.ok AND rv.code = 'rejected' AND rv.result_event IS NULL;
    RAISE NOTICE 'OK 5: корректировки';
END $$;

-- ---------- 6. Outbox ----------
DO $$
DECLARE
    n int;
    v_id bigint;
BEGIN
    SELECT count(*) INTO n FROM timetrack.fn_outbox_claim(2);
    ASSERT n = 2, 'claim должен вернуть 2 строки';
    SELECT id INTO v_id FROM timetrack.hr_sync_outbox WHERE attempts = 1 ORDER BY id LIMIT 1;
    PERFORM timetrack.fn_outbox_mark(v_id, true);
    ASSERT (SELECT status FROM timetrack.hr_sync_outbox WHERE id = v_id) = 'sent';
    SELECT id INTO v_id FROM timetrack.hr_sync_outbox WHERE attempts = 1 AND status <> 'sent' ORDER BY id LIMIT 1;
    PERFORM timetrack.fn_outbox_mark(v_id, false, 'HTTP 503');
    ASSERT (SELECT status FROM timetrack.hr_sync_outbox WHERE id = v_id) = 'failed';
    ASSERT (SELECT next_attempt_at > now() FROM timetrack.hr_sync_outbox WHERE id = v_id), 'после ошибки должна быть пауза';
    -- после 10 попыток → dead
    UPDATE timetrack.hr_sync_outbox SET attempts = 10 WHERE id = v_id;
    PERFORM timetrack.fn_outbox_mark(v_id, false, 'HTTP 503');
    ASSERT (SELECT status FROM timetrack.hr_sync_outbox WHERE id = v_id) = 'dead';
    RAISE NOTICE 'OK 6: outbox';
END $$;

-- ---------- 7. Отзыв биометрии и retention ----------
DO $$
DECLARE
    r record;
    n int;
BEGIN
    SELECT * INTO r FROM timetrack.fn_revoke_biometrics('EMP-001', 'employee_request', 'EMP-001', 'employee');
    ASSERT r.enrollments_deactivated = 1 AND r.consents_revoked = 1, 'отзыв: ' || r.enrollments_deactivated || '/' || r.consents_revoked;
    ASSERT NOT timetrack.fn_has_consent('EMP-001');
    -- после отзыва распознавание по лицу отклоняется, ручная отметка работает
    SELECT * INTO r FROM timetrack.fn_clock('EMP-001', 'auto', 'face', 'kiosk-1');
    ASSERT r.ok = false AND r.code = 'consent_missing';
    SELECT * INTO r FROM timetrack.fn_clock('EMP-001', 'check_in', 'manual', NULL, NULL, NULL, NULL, NULL, 'req-m1', NULL, '{}'::jsonb, 'EMP-001');
    ASSERT r.ok, 'ручная отметка без биометрии: ' || r.code;

    -- уволенный сотрудник с активной регистрацией попадает в список на удаление через 30 дней
    PERFORM timetrack.fn_grant_consent('EMP-002', 'v1.0');
    PERFORM timetrack.fn_record_enrollment('EMP-002', 'compreface', 'EMP-002', 'face-2');
    PERFORM timetrack.fn_upsert_employee('EMP-002', 'Петрова Анна', NULL, NULL, NULL, NULL, NULL, NULL, 'terminated', 'selftest');
    UPDATE timetrack.employees SET terminated_at = now() - interval '40 days' WHERE employee_id = 'EMP-002';
    SELECT count(*) INTO n FROM timetrack.fn_biometrics_due_for_deletion(30) WHERE employee_id = 'EMP-002';
    ASSERT n = 1, 'уволенный должен быть в списке на удаление биометрии';
    SELECT count(*) INTO n FROM timetrack.fn_biometrics_due_for_deletion(60) WHERE employee_id = 'EMP-002';
    ASSERT n = 0, 'при сроке 60 дней ещё рано';
    -- уволенный не может отмечаться
    SELECT * INTO r FROM timetrack.fn_clock('EMP-002', 'auto', 'face', 'kiosk-1');
    ASSERT r.ok = false AND r.code = 'employee_inactive';

    ASSERT timetrack.fn_purge_audit_log(3650) = 0;
    ASSERT timetrack.fn_purge_outbox(30) = 0;
    RAISE NOTICE 'OK 7: отзыв биометрии и retention';
END $$;

SELECT 'SELFTEST PASSED' AS result;
ROLLBACK;
