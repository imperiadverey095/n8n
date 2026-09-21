-- =============================================================================
--  Демонстрационные данные (НЕ для продакшена).
--  Создаёт трёх сотрудников, HR-токен, токен терминала и личный токен
--  сотрудника. Токены печатаются ОДИН раз в выводе psql — сохраните их.
--    psql "$DATABASE_URL" -f db/002_seed_demo.sql
-- =============================================================================
BEGIN;

DO $$
BEGIN
    PERFORM timetrack.fn_upsert_employee('EMP-001', 'Иванов Иван Иванович', 'ivanov@example.com', 'Склад', 'Кладовщик',
        'Europe/Moscow', '{"start":"09:00","end":"18:00","days":[1,2,3,4,5],"break_minutes":60}', 'HR-1001', 'active', 'seed');
    PERFORM timetrack.fn_upsert_employee('EMP-002', 'Петрова Анна Сергеевна', 'petrova@example.com', 'Офис', 'Бухгалтер',
        'Europe/Moscow', '{"start":"10:00","end":"19:00","days":[1,2,3,4,5],"break_minutes":60}', 'HR-1002', 'active', 'seed');
    PERFORM timetrack.fn_upsert_employee('EMP-003', 'Schmidt Anna', 'schmidt@example.com', 'Офис', 'Аналитик',
        'Europe/Berlin', '{"start":"08:00","end":"16:30","days":[1,2,3,4,5],"break_minutes":30}', 'HR-1003', 'active', 'seed');

    -- согласие на биометрию — только у первых двух (третий пользуется ручной отметкой)
    PERFORM timetrack.fn_grant_consent('EMP-001', 'v1.0', 'written_form', 'Согласие №2026-001', 'seed');
    PERFORM timetrack.fn_grant_consent('EMP-002', 'v1.0', 'written_form', 'Согласие №2026-002', 'seed');
END $$;

-- токены доступа: значение возвращается один раз
SELECT 'HR token'            AS token_kind, timetrack.fn_issue_token('HR portal', 'hr') AS token
UNION ALL
SELECT 'Device token',        timetrack.fn_issue_token('Kiosk main entrance', 'device', NULL, 'Проходная')
UNION ALL
SELECT 'HR system token',     timetrack.fn_issue_token('HR system integration', 'system')
UNION ALL
SELECT 'Employee EMP-001',    timetrack.fn_issue_token('EMP-001 mobile', 'employee', 'EMP-001')
UNION ALL
SELECT 'Employee EMP-003',    timetrack.fn_issue_token('EMP-003 mobile', 'employee', 'EMP-003');

-- пример истории за прошлую неделю для EMP-001 (для отчётов); время — по часовому поясу сотрудника
INSERT INTO timetrack.attendance_events (employee_id, event_type, occurred_at, source, device_id, confidence)
SELECT 'EMP-001', t.event_type,
       ((date_trunc('week', (now() AT TIME ZONE 'Europe/Moscow')) - interval '7 days' + t.offset_local) AT TIME ZONE 'Europe/Moscow'),
       'face', 'kiosk-demo', 0.97
  FROM (VALUES
    ('check_in',  interval '0 days 9 hours 5 minutes'),
    ('check_out', interval '0 days 18 hours 2 minutes'),
    ('check_in',  interval '1 days 9 hours 20 minutes'),
    ('check_out', interval '1 days 17 hours 55 minutes'),
    ('check_in',  interval '2 days 8 hours 58 minutes'),
    ('check_out', interval '2 days 13 hours 0 minutes'),
    ('check_in',  interval '2 days 13 hours 50 minutes'),
    ('check_out', interval '2 days 18 hours 30 minutes'),
    ('check_in',  interval '3 days 9 hours 2 minutes')
  ) AS t(event_type, offset_local);

COMMIT;
