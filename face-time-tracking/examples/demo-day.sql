-- =============================================================================
--  Демонстрация: один рабочий день сотрудников на реальной БД.
--  Запуск (после db/001_schema.sql):  psql "$DATABASE_URL" -X -f examples/demo-day.sql
--  Каждый шаг — то, что делает соответствующий воркфлоу n8n после вебхука
--  (аутентификация, распознавание и т.п. происходят в n8n; здесь показан
--  результат обращения к функциям БД и то, что уходит в ответ терминалу).
-- =============================================================================
\set QUIET on
\pset pager off
\pset null '∅'
\set ON_ERROR_STOP on
\timing off

-- Демо-день: сегодня по Москве, если уже вечер (все отметки дня в прошлом),
-- иначе вчера. fn_clock принимает время снимка не старше 24 часов.
SELECT CASE WHEN (now() AT TIME ZONE 'Europe/Moscow')::time >= time '19:00'
            THEN (now() AT TIME ZONE 'Europe/Moscow')::date
            ELSE (now() AT TIME ZONE 'Europe/Moscow')::date - 1 END::text AS demo_day \gset
SELECT set_config('demo.day', :'demo_day', false) AS demo_set \gset
CREATE FUNCTION pg_temp.t(p_time text) RETURNS timestamptz LANGUAGE sql AS
$$ SELECT (current_setting('demo.day')::date + p_time::time) AT TIME ZONE 'Europe/Moscow' $$;
CREATE FUNCTION pg_temp.msk(p timestamptz) RETURNS text LANGUAGE sql AS
$$ SELECT to_char(p AT TIME ZONE 'Europe/Moscow', 'YYYY-MM-DD HH24:MI') $$;
\set QUIET off

\echo
\echo '########  Демо-день:' :demo_day '(время по Europe/Moscow)  ########'
\echo
\echo '=== Шаг 1. HR регистрирует сотрудника: POST /timetrack/employees/enroll (воркфлоу 01) ==='
\echo '--- карточка сотрудника (fn_upsert_employee) ---'
SELECT employee_id, full_name, department, timezone, work_schedule
  FROM timetrack.fn_upsert_employee('EMP-001', 'Иванов Иван Иванович', 'ivanov@example.com', 'Склад', 'Кладовщик',
       'Europe/Moscow', '{"start":"09:00","end":"18:00","days":[1,2,3,4,5],"break_minutes":60}', 'HR-1001', 'active', 'hr.portal');
\echo '--- согласие на обработку биометрии (fn_grant_consent) — без него регистрация лица невозможна ---'
SELECT timetrack.fn_grant_consent('EMP-001', 'v1.0', 'written_form', 'Согласие №2026-001', 'hr.portal') AS consent_id;
\echo '--- снимок ушёл в CompreFace (subject = EMP-001), вернулся image_id; в БД — только ссылка и хэш снимка ---'
SELECT timetrack.fn_record_enrollment('EMP-001', 'compreface', 'EMP-001',
       '5d3e1f0a-8c2b-4b6f-9a1e-2f7c1d9e0b11', 'c0ffee11aa22bb33…(sha256 снимка)', 'hr.portal') AS enrollment_id;

\echo
\echo '--- ещё два сотрудника: EMP-002 с согласием, EMP-003 без согласия (будет отмечаться вручную) ---'
\set QUIET on
SELECT timetrack.fn_upsert_employee('EMP-002', 'Петрова Анна Сергеевна', 'petrova@example.com', 'Офис', 'Бухгалтер',
       'Europe/Moscow', '{"start":"10:00","end":"19:00","days":[1,2,3,4,5],"break_minutes":60}', 'HR-1002', 'active', 'hr.portal') AS r \gset
SELECT timetrack.fn_upsert_employee('EMP-003', 'Сидоров Пётр', 'sidorov@example.com', 'Склад', 'Грузчик',
       'Europe/Moscow', '{"start":"08:00","end":"17:00","days":[1,2,3,4,5],"break_minutes":60}', 'HR-1003', 'active', 'hr.portal') AS r \gset
SELECT timetrack.fn_grant_consent('EMP-002', 'v1.0', 'written_form', 'Согласие №2026-002', 'hr.portal') AS r \gset
\set QUIET off
SELECT employee_id, full_name, department, timetrack.fn_has_consent(employee_id) AS consent
  FROM timetrack.employees ORDER BY employee_id;

\echo
\echo '=== Шаг 2. Токены доступа (fn_issue_token): значение показывается один раз, в БД — только sha256 ==='
SELECT 'Kiosk main entrance' AS client, 'device'   AS role, timetrack.fn_issue_token('Kiosk main entrance', 'device', NULL, 'Проходная') AS token
UNION ALL SELECT 'EMP-003 mobile', 'employee', timetrack.fn_issue_token('EMP-003 mobile', 'employee', 'EMP-003')
UNION ALL SELECT 'HR portal',      'hr',       timetrack.fn_issue_token('HR portal', 'hr');
\echo '--- как это хранится ---'
SELECT name, role, employee_id, left(token_hash, 20) || '…' AS token_hash FROM timetrack.api_clients ORDER BY created_at;

\echo
\echo '=== Шаг 3. 09:05 — Иванов встал перед терминалом: POST /timetrack/clock (воркфлоу 02) ==='
\echo '    n8n: токен терминала → снимок в CompreFace → subject EMP-001, similarity 0.987 ≥ 0.90 → fn_clock()'
SELECT ok, code, event_type, pg_temp.msk(occurred_at) AS local_time, duplicate, full_name
  FROM timetrack.fn_clock('EMP-001', 'auto', 'face', 'kiosk-1', 'Проходная', 0.987, NULL,
                          'a1a1a1…(sha256 снимка)', 'req-0905', pg_temp.t('09:05'),
                          '{"face_probability": 0.9993, "faces_detected": 1}', 'Kiosk main entrance', 120, 16, true, 48);

\echo
\echo '=== Шаг 4. Сеть моргнула — терминал повторил тот же запрос (тот же request_id) ==='
SELECT ok, code, event_type, pg_temp.msk(occurred_at) AS local_time, duplicate
  FROM timetrack.fn_clock('EMP-001', 'auto', 'face', 'kiosk-1', 'Проходная', 0.987, NULL,
                          'a1a1a1…', 'req-0905', pg_temp.t('09:05'), '{}', 'Kiosk main entrance', 120, 16, true, 48);

\echo
\echo '=== Шаг 5. 09:06 — Иванов ещё раз посмотрел в камеру (новый снимок): антидребезг 120 с ==='
SELECT ok, code, event_type, pg_temp.msk(occurred_at) AS local_time, duplicate
  FROM timetrack.fn_clock('EMP-001', 'auto', 'face', 'kiosk-1', 'Проходная', 0.951, NULL,
                          'b2b2b2…', 'req-0906', pg_temp.t('09:06'), '{}', 'Kiosk main entrance', 120, 16, true, 48);

\echo
\echo '=== Шаг 6. Обед 13:02 → 13:47 и уход 18:34: тип события определяется чередованием (auto) ==='
SELECT s.step, r.ok, r.code, r.event_type, pg_temp.msk(r.occurred_at) AS local_time
  FROM (VALUES (1, '13:02', 'req-1302'), (2, '13:47', 'req-1347'), (3, '18:34', 'req-1834')) AS s(step, at_time, req)
  CROSS JOIN LATERAL timetrack.fn_clock('EMP-001', 'auto', 'face', 'kiosk-1', 'Проходная', 0.97, NULL,
                                        NULL, s.req, pg_temp.t(s.at_time), '{}', 'Kiosk main entrance', 120, 16, true, 48) r
  ORDER BY s.step;

\echo
\echo '=== Шаг 7. Посетитель попробовал отметиться: CompreFace не нашёл subject → 404 unknown_face, фото не сохраняется ==='
SELECT timetrack.fn_audit('Kiosk main entrance', 'device', 'recognition.failed', 'device', 'kiosk-1',
       '{"code":"unknown_face","similarity":null,"faces_detected":1,"image_hash":"e5e5e5…","request_id":"req-visitor"}') AS audit_id;

\echo
\echo '=== Шаг 8. Сидоров (без согласия) подошёл к терминалу → отказ; отметился вручную личным токеном ==='
SELECT ok, code, event_type, full_name
  FROM timetrack.fn_clock('EMP-003', 'auto', 'face', 'kiosk-1', 'Проходная', 0.99, NULL, 'f6f6f6…', 'req-sid-1', pg_temp.t('08:03'));
\echo '--- POST /timetrack/clock/manual с личным токеном (source = manual, согласие не требуется) ---'
SELECT ok, code, event_type, pg_temp.msk(occurred_at) AS local_time
  FROM timetrack.fn_clock('EMP-003', 'check_in', 'manual', NULL, NULL, NULL, NULL, NULL, 'req-sid-2', pg_temp.t('08:03'),
                          '{"via":"manual_api"}', 'EMP-003 mobile', 120, 16, false, 48);
\echo '    (вечером Сидоров забыл отметить уход — увидим это в отчёте)'

\echo
\echo '=== Шаг 9. Что легло в attendance_events (фото нет, есть хэш, схожесть, источник) ==='
SELECT id, employee_id, event_type, pg_temp.msk(occurred_at) AS local_time, source, device_id, confidence, request_id, status
  FROM timetrack.attendance_events ORDER BY id;

\echo
\echo '=== Шаг 10. HR импортирует календарь и отпуск: POST /timetrack/hr/calendar и /hr/absences (воркфлоу 06) ==='
\echo '--- Петрова в отпуске в демо-день: без этого день попал бы в табель как прогул ---'
SELECT ok, code, absence ->> 'absence_type' AS type, absence ->> 'date_from' AS date_from, absence ->> 'date_to' AS date_to
  FROM timetrack.fn_upsert_absence('EMP-002', 'vacation', :'demo_day'::date, (:'demo_day'::date + 4), 'approved', 'HR-VAC-7781', 'Ежегодный отпуск', NULL, 'hr.portal');
\echo '--- производственный календарь: следующий день объявлен праздником, сотрудники переведены на него ---'
SELECT calendar_code, day, day_type, name
  FROM timetrack.fn_upsert_calendar_day((:'demo_day'::date + 1), 'holiday', 0, 'Демонстрационный праздник', 'ru', 'hr.portal');
\set QUIET on
DO $$
DECLARE e record;
BEGIN
    FOR e IN SELECT employee_id, full_name FROM timetrack.employees LOOP
        PERFORM timetrack.fn_upsert_employee(e.employee_id, e.full_name, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'hr.portal', 'ru');
    END LOOP;
END $$;
\set QUIET off
SELECT employee_id, full_name, calendar_code FROM timetrack.employees ORDER BY employee_id;

\echo
\echo '=== Шаг 11. Дневная сводка (fn_daily_summary) — то, что показывает GET /timetrack/reports?type=standard ==='
SELECT e.employee_id, d.day_type, d.status, d.absence_type, pg_temp.msk(d.first_in) AS first_in, pg_temp.msk(d.last_out) AS last_out,
       d.sessions, d.worked_minutes, d.break_minutes, d.scheduled_minutes, d.late_minutes, d.overtime_minutes, d.incomplete
  FROM (VALUES ('EMP-001'), ('EMP-002'), ('EMP-003')) AS e(employee_id)
  CROSS JOIN LATERAL timetrack.fn_daily_summary(e.employee_id, :'demo_day'::date, :'demo_day'::date) d
  ORDER BY e.employee_id;
\echo '    EMP-001: 09:05–13:02 и 13:47–18:34 = 524 мин; перерыв 45 < 60 → доудержано 15 → 509 отработано,'
\echo '             опоздание 5 мин, сверхурочно 509 − 480 = 29.  EMP-002: отпуск, а не прогул.  EMP-003: незакрытая смена.'

\echo
\echo '=== Шаг 12. Сидоров просит добавить пропущенный уход в 17:30: POST /timetrack/me/corrections (воркфлоу 04) ==='
SELECT ok, code, request ->> 'id' AS request_id, request ->> 'status' AS status, request ->> 'reason' AS reason
  FROM timetrack.fn_request_correction('EMP-003', 'add', NULL, 'check_out', pg_temp.t('17:30'),
                                       'Забыл отметиться на выходе, ушёл в 17:30', 'EMP-003 mobile') \gset corr_
\echo '--- запрос в очереди HR: GET /timetrack/hr/corrections?status=pending ---'
SELECT c.id, c.employee_id, c.action, c.requested_type, pg_temp.msk(c.requested_time) AS requested_time, c.status
  FROM timetrack.correction_requests c;
\echo '--- HR одобряет: POST /timetrack/hr/corrections/review (fn_review_correction) ---'
SELECT ok, code, result_event ->> 'id' AS new_event_id, result_event ->> 'source' AS source, request ->> 'reviewed_by' AS reviewed_by
  FROM timetrack.fn_review_correction(:'corr_request_id'::uuid, 'approved', 'Подтверждено по видео с проходной', 'hr.manager');
\echo '--- сводка EMP-003 после корректировки ---'
SELECT d.status, pg_temp.msk(d.first_in) AS first_in, pg_temp.msk(d.last_out) AS last_out, d.worked_minutes, d.late_minutes, d.incomplete
  FROM timetrack.fn_daily_summary('EMP-003', :'demo_day'::date, :'demo_day'::date) d;

\echo
\echo '=== Шаг 13. Итоги дня для табеля (fn_timesheet → totals) ==='
SELECT t.employee ->> 'employee_id' AS employee_id, t.employee ->> 'full_name' AS full_name, t.totals
  FROM timetrack.fn_timesheet(NULL, :'demo_day'::date, :'demo_day'::date) t;

\echo
\echo '=== Шаг 14. Outbox для HR-системы: что уйдёт воркфлоу 06 (POST на hrSystemUrl) ==='
SELECT id, event_kind, entity_id, status, payload - 'location' - 'device_id' AS payload
  FROM timetrack.hr_sync_outbox ORDER BY id LIMIT 6;

\echo
\echo '=== Шаг 15. Журнал аудита: кто и что делал ==='
SELECT pg_temp.msk(occurred_at) AS "when", actor, actor_role, action, entity_type, entity_id
  FROM timetrack.audit_log ORDER BY id;
