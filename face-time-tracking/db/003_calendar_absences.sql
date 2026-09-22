-- =============================================================================
--  Модуль «производственный календарь и отсутствия»
--  Применяется ПОСЛЕ db/001_schema.sql:
--      psql "$DATABASE_URL" -f db/001_schema.sql -f db/003_calendar_absences.sql
--
--  Зачем: без него отпуск, больничный и государственный праздник попадают
--  в табель как прогул, а сотруднику в отпуске уходит напоминание «нет отметок».
--
--  Что добавляет:
--    * timetrack.calendar_days — производственный календарь (праздники, переносы,
--      предпраздничные сокращённые дни); у сотрудника — свой календарь.
--    * timetrack.absences — отпуска, больничные, командировки и т. п.
--    * пересчёт fn_daily_summary / fn_timesheet / fn_attendance_issues с их учётом.
--
--  Скрипт идемпотентен: можно запускать повторно.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Производственный календарь
--    day_type: holiday    — нерабочий день (праздник), даже если он будний
--              workday    — рабочий день (перенос: рабочая суббота)
--              short_day  — предпраздничный: норма короче на shorten_minutes
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS timetrack.calendar_days (
    calendar_code   text NOT NULL DEFAULT 'default',
    day             date NOT NULL,
    day_type        text NOT NULL CHECK (day_type IN ('holiday', 'workday', 'short_day')),
    shorten_minutes int  NOT NULL DEFAULT 0 CHECK (shorten_minutes >= 0 AND shorten_minutes <= 480),
    name            text,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (calendar_code, day)
);

-- у каждого сотрудника свой календарь (разные страны/подразделения)
ALTER TABLE timetrack.employees
    ADD COLUMN IF NOT EXISTS calendar_code text NOT NULL DEFAULT 'default';

-- -----------------------------------------------------------------------------
-- 2. Отсутствия
--    counts_as_worked — засчитывать норму дня как отработанное время
--    (командировка и удалённая работа — да; отпуск и больничный — нет).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS timetrack.absences (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id      text NOT NULL REFERENCES timetrack.employees(employee_id) ON DELETE CASCADE,
    absence_type     text NOT NULL CHECK (absence_type IN
                          ('vacation', 'sick_leave', 'business_trip', 'remote', 'unpaid_leave', 'other')),
    date_from        date NOT NULL,
    date_to          date NOT NULL,
    status           text NOT NULL DEFAULT 'approved' CHECK (status IN ('planned', 'approved', 'cancelled')),
    counts_as_worked boolean NOT NULL DEFAULT false,
    external_id      text,
    comment          text,
    created_by       text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (date_to >= date_from),
    CHECK (date_to - date_from <= 400)
);
CREATE UNIQUE INDEX IF NOT EXISTS absences_external_idx
    ON timetrack.absences (employee_id, external_id) WHERE external_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS absences_natural_idx
    ON timetrack.absences (employee_id, absence_type, date_from, date_to) WHERE external_id IS NULL;
CREATE INDEX IF NOT EXISTS absences_period_idx
    ON timetrack.absences (employee_id, date_from, date_to) WHERE status <> 'cancelled';

-- -----------------------------------------------------------------------------
-- 3. Функции ведения календаря и отсутствий
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION timetrack.fn_upsert_calendar_day(
    p_day date, p_day_type text, p_shorten_minutes int DEFAULT 0,
    p_name text DEFAULT NULL, p_calendar_code text DEFAULT 'default', p_actor text DEFAULT 'system'
) RETURNS timetrack.calendar_days
LANGUAGE plpgsql AS $$
DECLARE
    v_row timetrack.calendar_days;
BEGIN
    IF p_day_type NOT IN ('holiday', 'workday', 'short_day') THEN
        RAISE EXCEPTION 'invalid day_type: %', p_day_type USING ERRCODE = '22023';
    END IF;

    INSERT INTO timetrack.calendar_days (calendar_code, day, day_type, shorten_minutes, name)
    VALUES (COALESCE(NULLIF(btrim(p_calendar_code), ''), 'default'), p_day, p_day_type,
            CASE WHEN p_day_type = 'short_day' THEN COALESCE(p_shorten_minutes, 60) ELSE 0 END,
            NULLIF(btrim(p_name), ''))
    ON CONFLICT (calendar_code, day) DO UPDATE SET
        day_type        = EXCLUDED.day_type,
        shorten_minutes = EXCLUDED.shorten_minutes,
        name            = COALESCE(EXCLUDED.name, timetrack.calendar_days.name),
        updated_at      = now()
    RETURNING * INTO v_row;

    PERFORM timetrack.fn_audit(p_actor, 'hr', 'calendar.upserted', 'calendar_day',
                               v_row.calendar_code || ':' || v_row.day::text,
                               jsonb_build_object('day_type', v_row.day_type, 'shorten_minutes', v_row.shorten_minutes));
    RETURN v_row;
END $$;

-- Отсутствие. Без external_id повторный вызов с теми же типом и периодом
-- обновляет существующую запись (идемпотентная синхронизация из HR-системы).
CREATE OR REPLACE FUNCTION timetrack.fn_upsert_absence(
    p_employee_id text, p_absence_type text, p_date_from date, p_date_to date,
    p_status text DEFAULT 'approved', p_external_id text DEFAULT NULL,
    p_comment text DEFAULT NULL, p_counts_as_worked boolean DEFAULT NULL,
    p_actor text DEFAULT 'system'
) RETURNS TABLE (ok boolean, code text, absence jsonb)
LANGUAGE plpgsql AS $$
DECLARE
    v_row    timetrack.absences;
    v_ext    text := NULLIF(btrim(p_external_id), '');
    v_counts boolean;
BEGIN
    IF p_absence_type IS NULL OR p_absence_type NOT IN
       ('vacation', 'sick_leave', 'business_trip', 'remote', 'unpaid_leave', 'other') THEN
        RETURN QUERY SELECT false, 'invalid_absence_type', NULL::jsonb; RETURN;
    END IF;
    IF p_date_from IS NULL OR p_date_to IS NULL OR p_date_to < p_date_from THEN
        RETURN QUERY SELECT false, 'invalid_period', NULL::jsonb; RETURN;
    END IF;
    IF p_date_to - p_date_from > 400 THEN
        RETURN QUERY SELECT false, 'period_too_long', NULL::jsonb; RETURN;
    END IF;
    IF p_status IS NOT NULL AND p_status NOT IN ('planned', 'approved', 'cancelled') THEN
        RETURN QUERY SELECT false, 'invalid_status', NULL::jsonb; RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM timetrack.employees e WHERE e.employee_id = p_employee_id) THEN
        RETURN QUERY SELECT false, 'employee_not_found', NULL::jsonb; RETURN;
    END IF;

    -- командировка и удалёнка засчитываются как отработанная норма, остальное — нет
    v_counts := COALESCE(p_counts_as_worked, p_absence_type IN ('business_trip', 'remote'));

    IF v_ext IS NULL THEN
        INSERT INTO timetrack.absences AS a
            (employee_id, absence_type, date_from, date_to, status, counts_as_worked, comment, created_by)
        VALUES (p_employee_id, p_absence_type, p_date_from, p_date_to,
                COALESCE(p_status, 'approved'), v_counts, NULLIF(btrim(p_comment), ''), p_actor)
        ON CONFLICT (employee_id, absence_type, date_from, date_to) WHERE external_id IS NULL
        DO UPDATE SET status = COALESCE(p_status, a.status), counts_as_worked = v_counts,
                      comment = COALESCE(NULLIF(btrim(p_comment), ''), a.comment), updated_at = now()
        RETURNING * INTO v_row;
    ELSE
        INSERT INTO timetrack.absences AS a
            (employee_id, absence_type, date_from, date_to, status, counts_as_worked, external_id, comment, created_by)
        VALUES (p_employee_id, p_absence_type, p_date_from, p_date_to,
                COALESCE(p_status, 'approved'), v_counts, v_ext, NULLIF(btrim(p_comment), ''), p_actor)
        ON CONFLICT (employee_id, external_id) WHERE external_id IS NOT NULL
        DO UPDATE SET absence_type = EXCLUDED.absence_type, date_from = EXCLUDED.date_from,
                      date_to = EXCLUDED.date_to, status = COALESCE(p_status, a.status),
                      counts_as_worked = v_counts,
                      comment = COALESCE(NULLIF(btrim(p_comment), ''), a.comment), updated_at = now()
        RETURNING * INTO v_row;
    END IF;

    PERFORM timetrack.fn_audit(p_actor, 'hr', 'absence.upserted', 'absence', v_row.id::text,
                               jsonb_build_object('employee_id', v_row.employee_id, 'type', v_row.absence_type,
                                                  'from', v_row.date_from, 'to', v_row.date_to, 'status', v_row.status));
    PERFORM timetrack.fn_outbox('absence.upserted', 'absence', v_row.id::text, to_jsonb(v_row));
    RETURN QUERY SELECT true, 'saved', to_jsonb(v_row);
END $$;

CREATE OR REPLACE FUNCTION timetrack.fn_cancel_absence(
    p_id uuid, p_actor text DEFAULT 'system'
) RETURNS TABLE (ok boolean, code text, absence jsonb)
LANGUAGE plpgsql AS $$
DECLARE
    v_row timetrack.absences;
BEGIN
    UPDATE timetrack.absences a SET status = 'cancelled', updated_at = now()
     WHERE a.id = p_id AND a.status <> 'cancelled'
    RETURNING * INTO v_row;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'absence_not_found', NULL::jsonb; RETURN;
    END IF;
    PERFORM timetrack.fn_audit(p_actor, 'hr', 'absence.cancelled', 'absence', v_row.id::text,
                               jsonb_build_object('employee_id', v_row.employee_id, 'type', v_row.absence_type));
    PERFORM timetrack.fn_outbox('absence.upserted', 'absence', v_row.id::text, to_jsonb(v_row));
    RETURN QUERY SELECT true, 'cancelled', to_jsonb(v_row);
END $$;

-- Действующее отсутствие сотрудника на конкретную дату (если их несколько —
-- по приоритету: больничный важнее отпуска, отпуск важнее командировки).
CREATE OR REPLACE FUNCTION timetrack.fn_absence_on(p_employee_id text, p_day date)
RETURNS timetrack.absences
LANGUAGE sql STABLE AS $$
    SELECT a.* FROM timetrack.absences a
     WHERE a.employee_id = p_employee_id AND a.status <> 'cancelled'
       AND p_day BETWEEN a.date_from AND a.date_to
     ORDER BY array_position(ARRAY['sick_leave','vacation','business_trip','remote','unpaid_leave','other'], a.absence_type),
              a.created_at DESC
     LIMIT 1
$$;

-- -----------------------------------------------------------------------------
-- 4. Карточка сотрудника: тот же fn_upsert_employee плюс код календаря
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS timetrack.fn_upsert_employee(text, text, text, text, text, text, jsonb, text, text, text);
CREATE OR REPLACE FUNCTION timetrack.fn_upsert_employee(
    p_employee_id text, p_full_name text, p_email text DEFAULT NULL,
    p_department text DEFAULT NULL, p_position text DEFAULT NULL,
    p_timezone text DEFAULT NULL, p_work_schedule jsonb DEFAULT NULL,
    p_hr_external_id text DEFAULT NULL, p_status text DEFAULT NULL,
    p_actor text DEFAULT 'system', p_calendar_code text DEFAULT NULL
) RETURNS timetrack.employees
LANGUAGE plpgsql AS $$
DECLARE
    v_row timetrack.employees;
    v_tz  text := NULLIF(btrim(p_timezone), '');
    v_cal text := NULLIF(btrim(p_calendar_code), '');
BEGIN
    IF v_tz IS NOT NULL THEN
        PERFORM now() AT TIME ZONE v_tz;   -- ошибка при неизвестном часовом поясе
    END IF;
    IF p_status IS NOT NULL AND p_status NOT IN ('active','inactive','terminated') THEN
        RAISE EXCEPTION 'invalid employee status: %', p_status USING ERRCODE = '22023';
    END IF;

    INSERT INTO timetrack.employees AS e
        (employee_id, full_name, email, department, position, timezone, work_schedule,
         hr_external_id, status, terminated_at, calendar_code)
    VALUES (
        p_employee_id, p_full_name, NULLIF(btrim(p_email), ''),
        NULLIF(btrim(p_department), ''), NULLIF(btrim(p_position), ''),
        COALESCE(v_tz, 'UTC'),
        COALESCE(p_work_schedule, '{"start":"09:00","end":"18:00","days":[1,2,3,4,5],"break_minutes":60}'::jsonb),
        NULLIF(btrim(p_hr_external_id), ''), COALESCE(p_status, 'active'),
        CASE WHEN p_status = 'terminated' THEN now() END,
        COALESCE(v_cal, 'default')
    )
    ON CONFLICT (employee_id) DO UPDATE SET
        full_name      = EXCLUDED.full_name,
        email          = COALESCE(EXCLUDED.email, e.email),
        department     = COALESCE(EXCLUDED.department, e.department),
        position       = COALESCE(EXCLUDED.position, e.position),
        timezone       = COALESCE(v_tz, e.timezone),
        work_schedule  = COALESCE(p_work_schedule, e.work_schedule),
        hr_external_id = COALESCE(EXCLUDED.hr_external_id, e.hr_external_id),
        status         = COALESCE(p_status, e.status),
        calendar_code  = COALESCE(v_cal, e.calendar_code),
        terminated_at  = CASE WHEN COALESCE(p_status, e.status) = 'terminated'
                              THEN COALESCE(e.terminated_at, now()) ELSE NULL END
    RETURNING * INTO v_row;

    PERFORM timetrack.fn_audit(p_actor, 'hr', 'employee.upserted', 'employee', v_row.employee_id,
                               jsonb_build_object('status', v_row.status, 'department', v_row.department));
    PERFORM timetrack.fn_outbox('employee.upserted', 'employee', v_row.employee_id,
                                jsonb_build_object('employee_id', v_row.employee_id, 'status', v_row.status,
                                                   'hr_external_id', v_row.hr_external_id));
    RETURN v_row;
END $$;

-- -----------------------------------------------------------------------------
-- 4a. Отметка: окно приёма «задним числом» стало настраиваемым
--     (p_max_backdate_hours, по умолчанию прежние 24 часа). Нужно площадкам,
--     где терминал копит офлайн-очередь дольше суток.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS timetrack.fn_clock(text, text, text, text, text, numeric, numeric, text, text,
                                           timestamptz, jsonb, text, int, int, boolean);
CREATE OR REPLACE FUNCTION timetrack.fn_clock(
    p_employee_id       text,
    p_event_type        text        DEFAULT 'auto',
    p_source            text        DEFAULT 'face',
    p_device_id         text        DEFAULT NULL,
    p_location          text        DEFAULT NULL,
    p_confidence        numeric     DEFAULT NULL,
    p_liveness_score    numeric     DEFAULT NULL,
    p_image_hash        text        DEFAULT NULL,
    p_request_id        text        DEFAULT NULL,
    p_captured_at       timestamptz DEFAULT NULL,
    p_metadata          jsonb       DEFAULT '{}'::jsonb,
    p_actor             text        DEFAULT NULL,
    p_debounce_seconds  int         DEFAULT 120,
    p_max_session_hours int         DEFAULT 16,
    p_require_consent   boolean     DEFAULT true,
    p_max_backdate_hours int        DEFAULT 24
) RETURNS TABLE (
    ok           boolean,
    code         text,
    event_id     bigint,
    event_type   text,
    occurred_at  timestamptz,
    duplicate    boolean,
    employee_id  text,
    full_name    text,
    timezone     text
)
LANGUAGE plpgsql AS $$
DECLARE
    v_emp  timetrack.employees;
    v_last timetrack.attendance_events;
    v_row  timetrack.attendance_events;
    v_type text;
    v_at   timestamptz := now();
    v_meta jsonb := COALESCE(p_metadata, '{}'::jsonb);
    v_role text := CASE WHEN p_source = 'manual' THEN 'employee' ELSE 'device' END;
    v_abs  timetrack.absences;
BEGIN
    -- 0. Идемпотентность: повтор того же request_id возвращает уже созданное событие
    IF NULLIF(p_request_id, '') IS NOT NULL THEN
        SELECT a.* INTO v_row FROM timetrack.attendance_events a WHERE a.request_id = p_request_id;
        IF FOUND THEN
            SELECT e.* INTO v_emp FROM timetrack.employees e WHERE e.employee_id = v_row.employee_id;
            RETURN QUERY SELECT true, 'duplicate_request', v_row.id, v_row.event_type, v_row.occurred_at, true,
                                v_emp.employee_id, v_emp.full_name, v_emp.timezone;
            RETURN;
        END IF;
    END IF;

    -- 1. Сотрудник. FOR UPDATE сериализует одновременные отметки одного человека.
    SELECT e.* INTO v_emp FROM timetrack.employees e WHERE e.employee_id = p_employee_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'employee_not_found', NULL::bigint, NULL::text, NULL::timestamptz, false,
                            p_employee_id, NULL::text, NULL::text;
        RETURN;
    END IF;
    IF v_emp.status <> 'active' THEN
        RETURN QUERY SELECT false, 'employee_inactive', NULL::bigint, NULL::text, NULL::timestamptz, false,
                            v_emp.employee_id, v_emp.full_name, v_emp.timezone;
        RETURN;
    END IF;
    IF p_source = 'face' AND p_require_consent AND NOT timetrack.fn_has_consent(p_employee_id) THEN
        PERFORM timetrack.fn_audit(p_actor, v_role, 'attendance.rejected', 'employee', p_employee_id,
                                   jsonb_build_object('reason', 'consent_missing', 'device_id', p_device_id));
        RETURN QUERY SELECT false, 'consent_missing', NULL::bigint, NULL::text, NULL::timestamptz, false,
                            v_emp.employee_id, v_emp.full_name, v_emp.timezone;
        RETURN;
    END IF;

    -- 1a. Повторная проверка идемпотентности уже под блокировкой сотрудника:
    --     параллельные повторы одного request_id ждали здесь и не видели строку
    --     в шаге 0 (их снимок был сделан до получения блокировки).
    IF NULLIF(p_request_id, '') IS NOT NULL THEN
        SELECT a.* INTO v_row FROM timetrack.attendance_events a WHERE a.request_id = p_request_id;
        IF FOUND THEN
            RETURN QUERY SELECT true, 'duplicate_request', v_row.id, v_row.event_type, v_row.occurred_at, true,
                                v_emp.employee_id, v_emp.full_name, v_emp.timezone;
            RETURN;
        END IF;
    END IF;

    -- 2. Время события
    IF p_captured_at IS NOT NULL THEN
        IF p_captured_at BETWEEN now() - make_interval(hours => GREATEST(COALESCE(p_max_backdate_hours, 24), 1))
                             AND now() + interval '5 minutes' THEN
            v_at := p_captured_at;
        ELSE
            v_meta := v_meta || jsonb_build_object('captured_at_rejected', p_captured_at);
        END IF;
    END IF;

    -- 3. Последнее действительное событие
    SELECT a.* INTO v_last
      FROM timetrack.attendance_events a
     WHERE a.employee_id = p_employee_id AND a.status = 'valid' AND a.occurred_at <= v_at
     ORDER BY a.occurred_at DESC, a.id DESC
     LIMIT 1;

    -- 4. Антидребезг: повторная отметка в окне N секунд считается той же отметкой
    IF v_last.id IS NOT NULL AND v_at - v_last.occurred_at < make_interval(secs => p_debounce_seconds) THEN
        RETURN QUERY SELECT true, 'debounced', v_last.id, v_last.event_type, v_last.occurred_at, true,
                            v_emp.employee_id, v_emp.full_name, v_emp.timezone;
        RETURN;
    END IF;

    -- 5. Тип события
    IF p_event_type IN ('check_in', 'check_out') THEN
        v_type := p_event_type;
    ELSIF v_last.id IS NULL OR v_last.event_type = 'check_out' THEN
        v_type := 'check_in';
    ELSIF v_at - v_last.occurred_at > make_interval(hours => p_max_session_hours) THEN
        -- забытый уход: старая смена остаётся незакрытой, новая отметка — приход
        v_type := 'check_in';
        v_meta := v_meta || jsonb_build_object('previous_session_incomplete', v_last.id);
    ELSE
        v_type := 'check_out';
    END IF;

    -- 5a. Отметка в день оформленного отсутствия — повод для разбора, но не отказ
    v_abs := timetrack.fn_absence_on(p_employee_id, (v_at AT TIME ZONE v_emp.timezone)::date);
    IF v_abs.id IS NOT NULL AND NOT v_abs.counts_as_worked THEN
        v_meta := v_meta || jsonb_build_object('during_absence', v_abs.absence_type);
    END IF;

    BEGIN
        INSERT INTO timetrack.attendance_events
            (employee_id, event_type, occurred_at, source, device_id, location,
             confidence, liveness_score, image_hash, request_id, created_by, metadata)
        VALUES
            (p_employee_id, v_type, v_at, COALESCE(p_source, 'face'), p_device_id, p_location,
             p_confidence, p_liveness_score, p_image_hash, NULLIF(p_request_id, ''), p_actor, v_meta)
        RETURNING * INTO v_row;
    EXCEPTION WHEN unique_violation THEN
        -- то же событие успел записать параллельный запрос: отвечаем как на дубликат,
        -- а не ошибкой базы (терминал повторяет запрос при обрыве связи)
        SELECT a.* INTO v_row FROM timetrack.attendance_events a WHERE a.request_id = NULLIF(p_request_id, '');
        IF NOT FOUND THEN
            RAISE;
        END IF;
        RETURN QUERY SELECT true, 'duplicate_request', v_row.id, v_row.event_type, v_row.occurred_at, true,
                            v_emp.employee_id, v_emp.full_name, v_emp.timezone;
        RETURN;
    END;

    PERFORM timetrack.fn_audit(p_actor, v_role, 'attendance.' || v_type, 'attendance_event', v_row.id::text,
                               jsonb_build_object('employee_id', p_employee_id, 'source', v_row.source,
                                                  'device_id', p_device_id, 'confidence', p_confidence));

    RETURN QUERY SELECT true, 'recorded', v_row.id, v_row.event_type, v_row.occurred_at, false,
                        v_emp.employee_id, v_emp.full_name, v_emp.timezone;
END $$;

-- -----------------------------------------------------------------------------
-- 5. Дневная сводка с учётом календаря и отсутствий
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS timetrack.fn_daily_summary(text, date, date);
CREATE FUNCTION timetrack.fn_daily_summary(p_employee_id text, p_from date, p_to date)
RETURNS TABLE (
    employee_id         text,
    work_date           date,
    day_type            text,     -- workday | weekend | holiday | short_day
    scheduled           boolean,
    scheduled_minutes   int,
    absence_type        text,     -- NULL, если отсутствия нет
    first_in            timestamptz,
    last_out            timestamptz,
    sessions            int,
    worked_minutes      int,      -- фактически отработано
    credited_minutes    int,      -- зачтено по норме (командировка, удалёнка)
    break_minutes       int,
    late_minutes        int,
    early_leave_minutes int,
    overtime_minutes    int,
    incomplete          boolean,
    status              text
)
LANGUAGE sql STABLE AS $$
    WITH emp AS (
        SELECT e.employee_id, e.timezone, e.work_schedule AS ws, e.calendar_code
          FROM timetrack.employees e WHERE e.employee_id = p_employee_id
    ),
    days AS (
        SELECT d::date AS work_date FROM generate_series(p_from, p_to, interval '1 day') AS d
    ),
    sched AS (
        SELECT days.work_date,
               cal.day_type AS cal_type,
               COALESCE(cal.shorten_minutes, 0) AS shorten,
               -- праздник отменяет рабочий день, перенос делает рабочим даже выходной
               CASE cal.day_type
                   WHEN 'holiday' THEN false
                   WHEN 'workday' THEN true
                   ELSE COALESCE((emp.ws -> 'days') @> to_jsonb(EXTRACT(ISODOW FROM days.work_date)::int), false)
               END AS scheduled,
               (days.work_date::timestamp + COALESCE((emp.ws ->> 'start')::time, time '09:00')) AT TIME ZONE emp.timezone AS sched_start,
               (days.work_date::timestamp + COALESCE((emp.ws ->> 'end')::time,   time '18:00')) AT TIME ZONE emp.timezone AS sched_end,
               COALESCE((emp.ws ->> 'break_minutes')::int, 0) AS std_break,
               -- обед удерживается только со смены длиннее порога (по умолчанию 6 ч)
               COALESCE((emp.ws ->> 'break_after_minutes')::int, 360) AS break_after,
               abs.absence_type,
               COALESCE(abs.counts_as_worked, false) AS counts_as_worked
          FROM days
          CROSS JOIN emp
          LEFT JOIN timetrack.calendar_days cal
                 ON cal.calendar_code = emp.calendar_code AND cal.day = days.work_date
          LEFT JOIN LATERAL timetrack.fn_absence_on(emp.employee_id, days.work_date) abs ON true
    ),
    s AS (
        SELECT * FROM timetrack.fn_sessions(p_employee_id, p_from, p_to)
    ),
    agg AS (
        SELECT s.work_date,
               MIN(s.check_in)  AS first_in,
               MAX(s.check_out) AS last_out,
               COUNT(*)::int    AS sessions,
               COALESCE(SUM(s.worked_minutes), 0)::int AS worked_raw,
               bool_or(s.incomplete) AS incomplete,
               COALESCE((EXTRACT(EPOCH FROM (MAX(s.check_out) - MIN(s.check_in))) / 60)::int, 0) AS span_minutes
          FROM s
         GROUP BY s.work_date
    ),
    calc AS (
        SELECT sched.work_date, sched.scheduled, sched.sched_start, sched.sched_end, sched.std_break,
               sched.break_after, sched.cal_type, sched.shorten, sched.absence_type, sched.counts_as_worked,
               agg.first_in, agg.last_out, COALESCE(agg.sessions, 0) AS sessions,
               COALESCE(agg.incomplete, false) AS incomplete,
               CASE WHEN sched.scheduled
                    THEN GREATEST((EXTRACT(EPOCH FROM (sched.sched_end - sched.sched_start)) / 60)::int
                                  - sched.std_break - sched.shorten, 0)
                    ELSE 0 END AS scheduled_minutes,
               -- перерывы между сессиями; если их меньше стандартного обеда — доудерживаем разницу
               GREATEST(COALESCE(agg.span_minutes, 0) - COALESCE(agg.worked_raw, 0), 0) AS gap_minutes,
               COALESCE(agg.worked_raw, 0) AS worked_raw
          FROM sched LEFT JOIN agg ON agg.work_date = sched.work_date
    ),
    calc2 AS (
        -- Сотрудник не отмечал обед: удерживаем недостающую часть, но только если
        -- смена длиннее порога break_after (короткий выход обедом не облагается)
        -- и не больше фактически отработанного времени.
        SELECT calc.*,
               CASE WHEN calc.worked_raw >= calc.break_after
                    THEN LEAST(GREATEST(calc.std_break - calc.gap_minutes, 0), calc.worked_raw)
                    ELSE 0 END AS auto_break
          FROM calc
    ),
    calc3 AS (
        SELECT calc2.*, GREATEST(calc2.worked_raw - calc2.auto_break, 0) AS worked_minutes FROM calc2
    )
    SELECT p_employee_id AS employee_id,
           c.work_date,
           CASE
               WHEN c.cal_type = 'holiday'   THEN 'holiday'
               WHEN c.cal_type = 'short_day' AND c.scheduled THEN 'short_day'
               WHEN c.scheduled              THEN 'workday'
               ELSE 'weekend'
           END AS day_type,
           c.scheduled,
           c.scheduled_minutes,
           c.absence_type,
           c.first_in,
           c.last_out,
           c.sessions,
           c.worked_minutes,
           -- норма зачитывается только когда сотрудник не отмечался (командировка/удалёнка)
           CASE WHEN c.counts_as_worked AND c.sessions = 0 THEN c.scheduled_minutes ELSE 0 END AS credited_minutes,
           CASE WHEN c.sessions = 0 THEN 0 ELSE (c.gap_minutes + c.auto_break)::int END AS break_minutes,
           CASE WHEN c.scheduled AND c.absence_type IS NULL AND c.first_in IS NOT NULL
                THEN GREATEST((EXTRACT(EPOCH FROM (c.first_in - c.sched_start)) / 60)::int, 0) ELSE 0 END AS late_minutes,
           CASE WHEN c.scheduled AND c.absence_type IS NULL AND c.last_out IS NOT NULL AND NOT c.incomplete
                THEN GREATEST((EXTRACT(EPOCH FROM (c.sched_end - c.last_out)) / 60)::int, 0) ELSE 0 END AS early_leave_minutes,
           CASE
               -- работа во время отпуска/больничного целиком считается сверхурочной
               WHEN c.absence_type IS NOT NULL AND NOT c.counts_as_worked THEN c.worked_minutes
               WHEN c.scheduled THEN GREATEST(c.worked_minutes - c.scheduled_minutes, 0)
               ELSE c.worked_minutes
           END AS overtime_minutes,
           c.incomplete,
           CASE
               WHEN c.sessions > 0 AND c.incomplete                          THEN 'incomplete'
               WHEN c.sessions > 0 AND c.scheduled AND c.absence_type IS NULL
                    AND c.first_in > c.sched_start + interval '1 minute'     THEN 'late'
               WHEN c.sessions > 0                                          THEN 'present'
               WHEN c.absence_type IS NOT NULL                              THEN c.absence_type
               WHEN c.scheduled                                             THEN 'absent'
               WHEN c.cal_type = 'holiday'                                  THEN 'holiday'
               ELSE 'day_off'
           END AS status
      FROM calc3 c
     ORDER BY c.work_date
$$;

-- -----------------------------------------------------------------------------
-- 6. Табель: добавлены раздел absences и счётчики отсутствий в totals
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS timetrack.fn_timesheet(text, date, date, text, boolean);
CREATE FUNCTION timetrack.fn_timesheet(
    p_employee_id text, p_from date, p_to date,
    p_department text DEFAULT NULL, p_include_inactive boolean DEFAULT false
) RETURNS TABLE (employee jsonb, days jsonb, sessions jsonb, corrections jsonb, absences jsonb, totals jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        jsonb_build_object(
            'employee_id', e.employee_id, 'full_name', e.full_name, 'email', e.email,
            'department', e.department, 'position', e.position, 'timezone', e.timezone,
            'status', e.status, 'work_schedule', e.work_schedule, 'calendar_code', e.calendar_code
        ) AS employee,
        ds.days,
        COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.check_in)
                    FROM timetrack.fn_sessions(e.employee_id, p_from, p_to) s), '[]'::jsonb) AS sessions,
        COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.created_at)
                    FROM timetrack.correction_requests c
                   WHERE c.employee_id = e.employee_id
                     AND (c.requested_time::date BETWEEN p_from AND p_to
                          OR c.created_at::date BETWEEN p_from AND p_to)), '[]'::jsonb) AS corrections,
        COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.date_from)
                    FROM timetrack.absences a
                   WHERE a.employee_id = e.employee_id AND a.status <> 'cancelled'
                     AND a.date_from <= p_to AND a.date_to >= p_from), '[]'::jsonb) AS absences,
        ds.totals
      FROM timetrack.employees e
      CROSS JOIN LATERAL (
          SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.work_date), '[]'::jsonb) AS days,
                 jsonb_build_object(
                     'scheduled_days',      COUNT(*) FILTER (WHERE d.scheduled),
                     'days_present',        COUNT(*) FILTER (WHERE d.status IN ('present', 'late', 'incomplete')),
                     'days_absent',         COUNT(*) FILTER (WHERE d.status = 'absent'),
                     'days_incomplete',     COUNT(*) FILTER (WHERE d.status = 'incomplete'),
                     'late_days',           COUNT(*) FILTER (WHERE d.late_minutes > 0),
                     'days_vacation',       COUNT(*) FILTER (WHERE d.absence_type = 'vacation'      AND d.scheduled),
                     'days_sick_leave',     COUNT(*) FILTER (WHERE d.absence_type = 'sick_leave'    AND d.scheduled),
                     'days_business_trip',  COUNT(*) FILTER (WHERE d.absence_type = 'business_trip' AND d.scheduled),
                     'days_other_absence',  COUNT(*) FILTER (WHERE d.absence_type IN ('remote', 'unpaid_leave', 'other') AND d.scheduled),
                     'days_holiday',        COUNT(*) FILTER (WHERE d.day_type = 'holiday'),
                     'scheduled_minutes',   COALESCE(SUM(d.scheduled_minutes), 0),
                     'worked_minutes',      COALESCE(SUM(d.worked_minutes), 0),
                     'credited_minutes',    COALESCE(SUM(d.credited_minutes), 0),
                     'late_minutes',        COALESCE(SUM(d.late_minutes), 0),
                     'early_leave_minutes', COALESCE(SUM(d.early_leave_minutes), 0),
                     'overtime_minutes',    COALESCE(SUM(d.overtime_minutes), 0)
                 ) AS totals
            FROM timetrack.fn_daily_summary(e.employee_id, p_from, p_to) d
      ) ds
     WHERE (p_employee_id IS NULL OR e.employee_id = p_employee_id)
       AND (p_department IS NULL OR e.department = p_department)
       AND (p_include_inactive OR e.status = 'active' OR e.employee_id = p_employee_id)
     ORDER BY e.full_name
$$;

-- -----------------------------------------------------------------------------
-- 7. Проблемные дни: отпуск, больничный и праздник больше не считаются проблемой
--    (статусы absence_type и holiday не попадают в выборку по построению)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION timetrack.fn_attendance_issues(p_from date, p_to date)
RETURNS TABLE (employee_id text, full_name text, email text, issues jsonb)
LANGUAGE sql STABLE AS $$
    SELECT e.employee_id, e.full_name, e.email, x.issues
      FROM timetrack.employees e
      CROSS JOIN LATERAL (
          SELECT jsonb_agg(jsonb_build_object('work_date', d.work_date, 'status', d.status,
                                              'first_in', d.first_in, 'last_out', d.last_out)
                           ORDER BY d.work_date) AS issues
            FROM timetrack.fn_daily_summary(e.employee_id, p_from, p_to) d
           WHERE d.status IN ('incomplete', 'absent')
      ) x
     WHERE e.status = 'active' AND x.issues IS NOT NULL
     ORDER BY e.full_name
$$;

COMMIT;
