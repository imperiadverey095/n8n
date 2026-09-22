-- =============================================================================
--  Face Time Tracking — схема базы данных учёта рабочего времени
--  PostgreSQL 13+ (используются gen_random_uuid(), sha256(), jsonb, окна)
--
--  Принципы:
--   * Фотографии сотрудников НЕ хранятся в этой БД. Хранится только ссылка на
--     биометрический шаблон во внешнем сервисе распознавания (CompreFace) и
--     хэш снимка, по которому было создано событие (для аудита/дедупликации).
--   * Все изменения проходят через функции fn_* — они атомарны, пишут аудит и
--     кладут события в outbox для HR-системы. Воркфлоу n8n вызывают только их.
--   * Скрипт идемпотентен: можно запускать повторно (CREATE ... IF NOT EXISTS,
--     CREATE OR REPLACE FUNCTION).
-- =============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS timetrack;

-- -----------------------------------------------------------------------------
-- 1. Сотрудники
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS timetrack.employees (
    employee_id     text PRIMARY KEY CHECK (employee_id ~ '^[A-Za-z0-9._-]{1,64}$'),
    full_name       text NOT NULL,
    email           text UNIQUE,
    department      text,
    position        text,
    timezone        text NOT NULL DEFAULT 'UTC',
    -- график: {"start":"09:00","end":"18:00","days":[1..7 ISO],"break_minutes":60}
    work_schedule   jsonb NOT NULL DEFAULT '{"start":"09:00","end":"18:00","days":[1,2,3,4,5],"break_minutes":60}'::jsonb,
    status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive','terminated')),
    terminated_at   timestamptz,
    hr_external_id  text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION timetrack.trg_set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS employees_set_updated_at ON timetrack.employees;
CREATE TRIGGER employees_set_updated_at
    BEFORE UPDATE ON timetrack.employees
    FOR EACH ROW EXECUTE FUNCTION timetrack.trg_set_updated_at();

-- -----------------------------------------------------------------------------
-- 2. API-клиенты: терминалы (device), сотрудники (employee), HR, системы
--    Токен хранится только в виде sha256-хэша.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS timetrack.api_clients (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name          text NOT NULL,
    role          text NOT NULL CHECK (role IN ('device','employee','hr','system')),
    token_hash    text NOT NULL UNIQUE,
    employee_id   text REFERENCES timetrack.employees(employee_id) ON DELETE CASCADE,
    location      text,
    active        boolean NOT NULL DEFAULT true,
    expires_at    timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_used_at  timestamptz,
    CHECK (role <> 'employee' OR employee_id IS NOT NULL)
);

-- -----------------------------------------------------------------------------
-- 3. Согласия на обработку биометрических данных
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS timetrack.biometric_consents (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id     text NOT NULL REFERENCES timetrack.employees(employee_id) ON DELETE CASCADE,
    consent_version text NOT NULL,
    granted_at      timestamptz NOT NULL DEFAULT now(),
    granted_via     text,          -- например: 'written_form', 'hr_portal'
    document_ref    text,          -- номер/ссылка на подписанный документ
    revoked_at      timestamptz,
    revoke_reason   text
);
CREATE INDEX IF NOT EXISTS biometric_consents_active_idx
    ON timetrack.biometric_consents (employee_id) WHERE revoked_at IS NULL;

-- -----------------------------------------------------------------------------
-- 4. Регистрации лиц: только ссылки на шаблоны во внешнем сервисе
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS timetrack.face_enrollments (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id         text NOT NULL REFERENCES timetrack.employees(employee_id) ON DELETE CASCADE,
    provider            text NOT NULL DEFAULT 'compreface',
    provider_subject_id text NOT NULL,
    provider_face_id    text,
    image_hash          text,
    enrolled_by         text,
    enrolled_at         timestamptz NOT NULL DEFAULT now(),
    active              boolean NOT NULL DEFAULT true,
    deactivated_at      timestamptz
);
CREATE INDEX IF NOT EXISTS face_enrollments_active_idx
    ON timetrack.face_enrollments (employee_id) WHERE active;

-- -----------------------------------------------------------------------------
-- 5. События учёта времени (приход/уход)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS timetrack.attendance_events (
    id              bigserial PRIMARY KEY,
    employee_id     text NOT NULL REFERENCES timetrack.employees(employee_id),
    event_type      text NOT NULL CHECK (event_type IN ('check_in','check_out')),
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    source          text NOT NULL DEFAULT 'face' CHECK (source IN ('face','manual','correction','import')),
    device_id       text,
    location        text,
    confidence      numeric(5,4),          -- схожесть лица (0..1)
    liveness_score  numeric(5,4),          -- оценка «живости», если её даёт клиент/провайдер
    image_hash      text,                  -- sha256 снимка; сам снимок не хранится
    request_id      text UNIQUE,           -- ключ идемпотентности от терминала
    status          text NOT NULL DEFAULT 'valid' CHECK (status IN ('valid','corrected','voided')),
    superseded_by   bigint REFERENCES timetrack.attendance_events(id),
    created_by      text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    metadata        jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS attendance_events_emp_time_idx
    ON timetrack.attendance_events (employee_id, occurred_at DESC) WHERE status = 'valid';
CREATE INDEX IF NOT EXISTS attendance_events_time_idx
    ON timetrack.attendance_events (occurred_at);

-- -----------------------------------------------------------------------------
-- 6. Запросы сотрудников на корректировку
--    action: add    — добавить пропущенную отметку
--            change — изменить время/тип существующей отметки
--            void   — аннулировать ошибочную отметку
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS timetrack.correction_requests (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id     text NOT NULL REFERENCES timetrack.employees(employee_id) ON DELETE CASCADE,
    event_id        bigint REFERENCES timetrack.attendance_events(id),
    action          text NOT NULL CHECK (action IN ('add','change','void')),
    requested_type  text CHECK (requested_type IN ('check_in','check_out')),
    requested_time  timestamptz,
    reason          text NOT NULL,
    status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','cancelled')),
    reviewed_by     text,
    reviewed_at     timestamptz,
    review_comment  text,
    result_event_id bigint REFERENCES timetrack.attendance_events(id),
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (action = 'void' OR (requested_type IS NOT NULL AND requested_time IS NOT NULL)),
    CHECK (action = 'add'  OR event_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS correction_requests_pending_idx
    ON timetrack.correction_requests (created_at) WHERE status = 'pending';

-- -----------------------------------------------------------------------------
-- 7. Журнал аудита (кто, что, когда; без биометрии и без фото)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS timetrack.audit_log (
    id           bigserial PRIMARY KEY,
    occurred_at  timestamptz NOT NULL DEFAULT now(),
    actor        text,
    actor_role   text,
    action       text NOT NULL,
    entity_type  text,
    entity_id    text,
    details      jsonb NOT NULL DEFAULT '{}'::jsonb,
    client_ip    text
);
CREATE INDEX IF NOT EXISTS audit_log_time_idx   ON timetrack.audit_log (occurred_at);
CREATE INDEX IF NOT EXISTS audit_log_entity_idx ON timetrack.audit_log (entity_type, entity_id);

-- -----------------------------------------------------------------------------
-- 8. Outbox для интеграции с HR-системой (надёжная доставка «хотя бы один раз»)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS timetrack.hr_sync_outbox (
    id              bigserial PRIMARY KEY,
    event_kind      text NOT NULL,     -- attendance.created | attendance.updated | employee.upserted | consent.revoked
    entity_type     text NOT NULL,
    entity_id       text NOT NULL,
    payload         jsonb NOT NULL,
    status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sent','failed','dead')),
    attempts        int  NOT NULL DEFAULT 0,
    last_error      text,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now(),
    sent_at         timestamptz
);
CREATE INDEX IF NOT EXISTS hr_sync_outbox_due_idx
    ON timetrack.hr_sync_outbox (next_attempt_at) WHERE status IN ('pending','failed');

-- =============================================================================
--  Служебные функции
-- =============================================================================

CREATE OR REPLACE FUNCTION timetrack.fn_audit(
    p_actor text, p_actor_role text, p_action text,
    p_entity_type text, p_entity_id text,
    p_details jsonb DEFAULT '{}'::jsonb, p_client_ip text DEFAULT NULL
) RETURNS bigint
LANGUAGE sql AS $$
    INSERT INTO timetrack.audit_log (actor, actor_role, action, entity_type, entity_id, details, client_ip)
    VALUES (p_actor, p_actor_role, p_action, p_entity_type, p_entity_id, COALESCE(p_details, '{}'::jsonb), p_client_ip)
    RETURNING id
$$;

CREATE OR REPLACE FUNCTION timetrack.fn_outbox(
    p_event_kind text, p_entity_type text, p_entity_id text, p_payload jsonb
) RETURNS bigint
LANGUAGE sql AS $$
    INSERT INTO timetrack.hr_sync_outbox (event_kind, entity_type, entity_id, payload)
    VALUES (p_event_kind, p_entity_type, p_entity_id, COALESCE(p_payload, '{}'::jsonb))
    RETURNING id
$$;

-- -----------------------------------------------------------------------------
-- Аутентификация API-клиентов
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION timetrack.fn_token_hash(p_token text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
$$;

-- Выпуск токена. Значение возвращается ОДИН раз и больше нигде не хранится.
CREATE OR REPLACE FUNCTION timetrack.fn_issue_token(
    p_name text, p_role text,
    p_employee_id text DEFAULT NULL, p_location text DEFAULT NULL,
    p_expires_at timestamptz DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    v_token text;
BEGIN
    v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
    INSERT INTO timetrack.api_clients (name, role, token_hash, employee_id, location, expires_at)
    VALUES (p_name, p_role, timetrack.fn_token_hash(v_token), p_employee_id, p_location, p_expires_at);
    RETURN v_token;
END $$;

CREATE OR REPLACE FUNCTION timetrack.fn_authenticate(p_token text)
RETURNS TABLE (client_id uuid, client_name text, role text, employee_id text, location text)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_token IS NULL OR length(p_token) < 16 THEN
        RETURN;
    END IF;
    RETURN QUERY
        UPDATE timetrack.api_clients c
           SET last_used_at = now()
         WHERE c.active
           AND (c.expires_at IS NULL OR c.expires_at > now())
           AND c.token_hash = timetrack.fn_token_hash(p_token)
        RETURNING c.id, c.name, c.role, c.employee_id, c.location;
END $$;

-- -----------------------------------------------------------------------------
-- Сотрудники и согласия
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION timetrack.fn_upsert_employee(
    p_employee_id text, p_full_name text, p_email text DEFAULT NULL,
    p_department text DEFAULT NULL, p_position text DEFAULT NULL,
    p_timezone text DEFAULT NULL, p_work_schedule jsonb DEFAULT NULL,
    p_hr_external_id text DEFAULT NULL, p_status text DEFAULT NULL,
    p_actor text DEFAULT 'system'
) RETURNS timetrack.employees
LANGUAGE plpgsql AS $$
DECLARE
    v_row timetrack.employees;
    v_tz  text := NULLIF(btrim(p_timezone), '');
BEGIN
    IF v_tz IS NOT NULL THEN
        PERFORM now() AT TIME ZONE v_tz;   -- ошибка при неизвестном часовом поясе
    END IF;
    IF p_status IS NOT NULL AND p_status NOT IN ('active','inactive','terminated') THEN
        RAISE EXCEPTION 'invalid employee status: %', p_status USING ERRCODE = '22023';
    END IF;

    INSERT INTO timetrack.employees AS e
        (employee_id, full_name, email, department, position, timezone, work_schedule, hr_external_id, status, terminated_at)
    VALUES (
        p_employee_id, p_full_name, NULLIF(btrim(p_email), ''),
        NULLIF(btrim(p_department), ''), NULLIF(btrim(p_position), ''),
        COALESCE(v_tz, 'UTC'),
        COALESCE(p_work_schedule, '{"start":"09:00","end":"18:00","days":[1,2,3,4,5],"break_minutes":60}'::jsonb),
        NULLIF(btrim(p_hr_external_id), ''), COALESCE(p_status, 'active'),
        CASE WHEN p_status = 'terminated' THEN now() END
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

CREATE OR REPLACE FUNCTION timetrack.fn_has_consent(p_employee_id text) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM timetrack.biometric_consents c
         WHERE c.employee_id = p_employee_id AND c.revoked_at IS NULL
    )
$$;

CREATE OR REPLACE FUNCTION timetrack.fn_grant_consent(
    p_employee_id text, p_consent_version text,
    p_granted_via text DEFAULT NULL, p_document_ref text DEFAULT NULL,
    p_actor text DEFAULT 'system'
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_id uuid;
BEGIN
    SELECT c.id INTO v_id
      FROM timetrack.biometric_consents c
     WHERE c.employee_id = p_employee_id AND c.revoked_at IS NULL AND c.consent_version = p_consent_version
     LIMIT 1;
    IF v_id IS NOT NULL THEN
        RETURN v_id;   -- уже есть действующее согласие этой версии
    END IF;

    INSERT INTO timetrack.biometric_consents (employee_id, consent_version, granted_via, document_ref)
    VALUES (p_employee_id, p_consent_version, p_granted_via, p_document_ref)
    RETURNING id INTO v_id;

    PERFORM timetrack.fn_audit(p_actor, 'hr', 'consent.granted', 'employee', p_employee_id,
                               jsonb_build_object('consent_id', v_id, 'version', p_consent_version));
    RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION timetrack.fn_record_enrollment(
    p_employee_id text, p_provider text, p_provider_subject_id text,
    p_provider_face_id text DEFAULT NULL, p_image_hash text DEFAULT NULL,
    p_actor text DEFAULT 'system'
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO timetrack.face_enrollments (employee_id, provider, provider_subject_id, provider_face_id, image_hash, enrolled_by)
    VALUES (p_employee_id, COALESCE(p_provider, 'compreface'), p_provider_subject_id, p_provider_face_id, p_image_hash, p_actor)
    RETURNING id INTO v_id;

    PERFORM timetrack.fn_audit(p_actor, 'hr', 'biometrics.enrolled', 'employee', p_employee_id,
                               jsonb_build_object('enrollment_id', v_id, 'provider', p_provider, 'face_id', p_provider_face_id));
    RETURN v_id;
END $$;

-- Отзыв биометрии: деактивирует регистрации и согласия. Удаление шаблона во
-- внешнем сервисе делает воркфлоу (HTTP DELETE) до/после вызова этой функции.
CREATE OR REPLACE FUNCTION timetrack.fn_revoke_biometrics(
    p_employee_id text, p_reason text DEFAULT NULL,
    p_actor text DEFAULT 'system', p_actor_role text DEFAULT 'hr'
) RETURNS TABLE (enrollments_deactivated int, consents_revoked int)
LANGUAGE plpgsql AS $$
DECLARE
    v_enr int;
    v_con int;
BEGIN
    UPDATE timetrack.face_enrollments f
       SET active = false, deactivated_at = now()
     WHERE f.employee_id = p_employee_id AND f.active;
    GET DIAGNOSTICS v_enr = ROW_COUNT;

    UPDATE timetrack.biometric_consents c
       SET revoked_at = now(), revoke_reason = p_reason
     WHERE c.employee_id = p_employee_id AND c.revoked_at IS NULL;
    GET DIAGNOSTICS v_con = ROW_COUNT;

    PERFORM timetrack.fn_audit(p_actor, p_actor_role, 'biometrics.revoked', 'employee', p_employee_id,
                               jsonb_build_object('reason', p_reason, 'enrollments', v_enr, 'consents', v_con));
    PERFORM timetrack.fn_outbox('consent.revoked', 'employee', p_employee_id,
                                jsonb_build_object('employee_id', p_employee_id, 'reason', p_reason));
    RETURN QUERY SELECT v_enr, v_con;
END $$;

-- -----------------------------------------------------------------------------
-- Отметка прихода/ухода. Единая точка записи событий.
--   p_event_type: 'check_in' | 'check_out' | 'auto' (чередование) | NULL (= auto)
--   p_request_id: ключ идемпотентности (повтор запроса не создаёт второе событие)
--   p_captured_at: время снимка с терминала (офлайн-очередь), принимается,
--                  если оно не старше 24 ч и не из будущего
-- -----------------------------------------------------------------------------
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
    p_require_consent   boolean     DEFAULT true
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

    -- 2. Время события
    IF p_captured_at IS NOT NULL THEN
        IF p_captured_at BETWEEN now() - interval '24 hours' AND now() + interval '5 minutes' THEN
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

    INSERT INTO timetrack.attendance_events
        (employee_id, event_type, occurred_at, source, device_id, location,
         confidence, liveness_score, image_hash, request_id, created_by, metadata)
    VALUES
        (p_employee_id, v_type, v_at, COALESCE(p_source, 'face'), p_device_id, p_location,
         p_confidence, p_liveness_score, p_image_hash, NULLIF(p_request_id, ''), p_actor, v_meta)
    RETURNING * INTO v_row;

    PERFORM timetrack.fn_audit(p_actor, v_role, 'attendance.' || v_type, 'attendance_event', v_row.id::text,
                               jsonb_build_object('employee_id', p_employee_id, 'source', v_row.source,
                                                  'device_id', p_device_id, 'confidence', p_confidence));

    RETURN QUERY SELECT true, 'recorded', v_row.id, v_row.event_type, v_row.occurred_at, false,
                        v_emp.employee_id, v_emp.full_name, v_emp.timezone;
END $$;

-- -----------------------------------------------------------------------------
-- Outbox → HR-система: триггер на события учёта
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION timetrack.trg_attendance_outbox() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM timetrack.fn_outbox(
        CASE WHEN TG_OP = 'INSERT' THEN 'attendance.created' ELSE 'attendance.updated' END,
        'attendance_event', NEW.id::text,
        jsonb_build_object(
            'event_id', NEW.id, 'employee_id', NEW.employee_id, 'event_type', NEW.event_type,
            'occurred_at', NEW.occurred_at, 'source', NEW.source, 'status', NEW.status,
            'superseded_by', NEW.superseded_by, 'device_id', NEW.device_id, 'location', NEW.location
        )
    );
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS attendance_outbox ON timetrack.attendance_events;
CREATE TRIGGER attendance_outbox
    AFTER INSERT OR UPDATE OF status ON timetrack.attendance_events
    FOR EACH ROW EXECUTE FUNCTION timetrack.trg_attendance_outbox();

-- Забрать пачку событий для отправки (с блокировкой строк — безопасно для
-- параллельных запусков воркфлоу).
CREATE OR REPLACE FUNCTION timetrack.fn_outbox_claim(p_limit int DEFAULT 100)
RETURNS SETOF timetrack.hr_sync_outbox
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
        WITH picked AS (
            SELECT o.id
              FROM timetrack.hr_sync_outbox o
             WHERE o.status IN ('pending', 'failed') AND o.next_attempt_at <= now()
             ORDER BY o.id
             LIMIT GREATEST(p_limit, 1)
             FOR UPDATE SKIP LOCKED
        )
        UPDATE timetrack.hr_sync_outbox o
           SET attempts = o.attempts + 1,
               next_attempt_at = now() + interval '10 minutes'   -- страховка от «зависшей» отправки
          FROM picked
         WHERE o.id = picked.id
        RETURNING o.*;
END $$;

CREATE OR REPLACE FUNCTION timetrack.fn_outbox_mark(
    p_id bigint, p_ok boolean, p_error text DEFAULT NULL, p_max_attempts int DEFAULT 10
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok THEN
        UPDATE timetrack.hr_sync_outbox o
           SET status = 'sent', sent_at = now(), last_error = NULL
         WHERE o.id = p_id;
    ELSE
        UPDATE timetrack.hr_sync_outbox o
           SET status = CASE WHEN o.attempts >= p_max_attempts THEN 'dead' ELSE 'failed' END,
               last_error = left(p_error, 2000),
               -- экспоненциальная пауза: 2, 4, 8 … минут, максимум 6 часов
               next_attempt_at = now() + LEAST(make_interval(mins => (2 ^ LEAST(o.attempts, 9))::int), interval '6 hours')
         WHERE o.id = p_id;
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Корректировки
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION timetrack.fn_request_correction(
    p_employee_id text, p_action text, p_event_id bigint,
    p_requested_type text, p_requested_time timestamptz, p_reason text,
    p_actor text DEFAULT NULL, p_max_age_days int DEFAULT 45
) RETURNS TABLE (ok boolean, code text, request jsonb)
LANGUAGE plpgsql AS $$
DECLARE
    v_ev  timetrack.attendance_events;
    v_req timetrack.correction_requests;
BEGIN
    IF p_action IS NULL OR p_action NOT IN ('add', 'change', 'void') THEN
        RETURN QUERY SELECT false, 'invalid_action', NULL::jsonb; RETURN;
    END IF;
    IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
        RETURN QUERY SELECT false, 'reason_required', NULL::jsonb; RETURN;
    END IF;

    IF p_action IN ('change', 'void') THEN
        SELECT a.* INTO v_ev FROM timetrack.attendance_events a WHERE a.id = p_event_id;
        IF NOT FOUND OR v_ev.employee_id <> p_employee_id THEN
            RETURN QUERY SELECT false, 'event_not_found', NULL::jsonb; RETURN;
        END IF;
        IF v_ev.status <> 'valid' THEN
            RETURN QUERY SELECT false, 'event_not_editable', NULL::jsonb; RETURN;
        END IF;
        IF v_ev.occurred_at < now() - make_interval(days => p_max_age_days) THEN
            RETURN QUERY SELECT false, 'event_too_old', NULL::jsonb; RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM timetrack.correction_requests c WHERE c.event_id = p_event_id AND c.status = 'pending') THEN
            RETURN QUERY SELECT false, 'already_pending', NULL::jsonb; RETURN;
        END IF;
    END IF;

    IF p_action IN ('add', 'change') THEN
        IF p_requested_type IS NULL OR p_requested_type NOT IN ('check_in', 'check_out') OR p_requested_time IS NULL THEN
            RETURN QUERY SELECT false, 'invalid_request', NULL::jsonb; RETURN;
        END IF;
        IF p_requested_time > now() + interval '5 minutes' THEN
            RETURN QUERY SELECT false, 'time_in_future', NULL::jsonb; RETURN;
        END IF;
        IF p_requested_time < now() - make_interval(days => p_max_age_days) THEN
            RETURN QUERY SELECT false, 'time_too_old', NULL::jsonb; RETURN;
        END IF;
    END IF;

    INSERT INTO timetrack.correction_requests (employee_id, event_id, action, requested_type, requested_time, reason)
    VALUES (
        p_employee_id,
        CASE WHEN p_action = 'add'  THEN NULL ELSE p_event_id END,
        p_action,
        CASE WHEN p_action = 'void' THEN NULL ELSE p_requested_type END,
        CASE WHEN p_action = 'void' THEN NULL ELSE p_requested_time END,
        btrim(p_reason)
    )
    RETURNING * INTO v_req;

    PERFORM timetrack.fn_audit(COALESCE(p_actor, p_employee_id), 'employee', 'correction.requested',
                               'correction_request', v_req.id::text,
                               jsonb_build_object('action', p_action, 'event_id', p_event_id));
    RETURN QUERY SELECT true, 'created', to_jsonb(v_req);
END $$;

CREATE OR REPLACE FUNCTION timetrack.fn_review_correction(
    p_request_id uuid, p_decision text, p_comment text DEFAULT NULL, p_reviewer text DEFAULT 'hr'
) RETURNS TABLE (ok boolean, code text, request jsonb, result_event jsonb)
LANGUAGE plpgsql AS $$
DECLARE
    v_req timetrack.correction_requests;
    v_old timetrack.attendance_events;
    v_new timetrack.attendance_events;
BEGIN
    SELECT c.* INTO v_req FROM timetrack.correction_requests c WHERE c.id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'request_not_found', NULL::jsonb, NULL::jsonb; RETURN;
    END IF;
    IF v_req.status <> 'pending' THEN
        RETURN QUERY SELECT false, 'already_reviewed', to_jsonb(v_req), NULL::jsonb; RETURN;
    END IF;
    IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
        RETURN QUERY SELECT false, 'invalid_decision', to_jsonb(v_req), NULL::jsonb; RETURN;
    END IF;

    IF p_decision = 'approved' THEN
        IF v_req.action IN ('change', 'void') THEN
            SELECT a.* INTO v_old FROM timetrack.attendance_events a WHERE a.id = v_req.event_id FOR UPDATE;
            IF NOT FOUND OR v_old.status <> 'valid' THEN
                RETURN QUERY SELECT false, 'event_not_editable', to_jsonb(v_req), NULL::jsonb; RETURN;
            END IF;
        END IF;
        IF v_req.action IN ('add', 'change') THEN
            INSERT INTO timetrack.attendance_events (employee_id, event_type, occurred_at, source, created_by, metadata)
            VALUES (v_req.employee_id, v_req.requested_type, v_req.requested_time, 'correction', p_reviewer,
                    jsonb_build_object('correction_request_id', v_req.id, 'replaces_event_id', v_req.event_id,
                                       'reason', v_req.reason))
            RETURNING * INTO v_new;
        END IF;
        IF v_req.action IN ('change', 'void') THEN
            UPDATE timetrack.attendance_events a
               SET status = CASE WHEN v_req.action = 'change' THEN 'corrected' ELSE 'voided' END,
                   superseded_by = v_new.id
             WHERE a.id = v_req.event_id;
        END IF;
    END IF;

    UPDATE timetrack.correction_requests c
       SET status = p_decision, reviewed_by = p_reviewer, reviewed_at = now(),
           review_comment = p_comment, result_event_id = v_new.id
     WHERE c.id = p_request_id
    RETURNING c.* INTO v_req;

    PERFORM timetrack.fn_audit(p_reviewer, 'hr', 'correction.' || p_decision, 'correction_request', v_req.id::text,
                               jsonb_build_object('employee_id', v_req.employee_id, 'event_id', v_req.event_id,
                                                  'result_event_id', v_new.id, 'comment', p_comment));
    RETURN QUERY SELECT true, p_decision, to_jsonb(v_req),
                        CASE WHEN v_new.id IS NULL THEN NULL::jsonb ELSE to_jsonb(v_new) END;
END $$;

-- =============================================================================
--  Отчётность
-- =============================================================================

-- Рабочие сессии: пара «приход → следующий уход». Незакрытые сессии помечаются.
CREATE OR REPLACE FUNCTION timetrack.fn_sessions(p_employee_id text, p_from date, p_to date)
RETURNS TABLE (
    employee_id    text,
    work_date      date,
    check_in       timestamptz,
    check_out      timestamptz,
    worked_minutes int,
    in_event_id    bigint,
    out_event_id   bigint,
    in_source      text,
    out_source     text,
    incomplete     boolean
)
LANGUAGE sql STABLE AS $$
    WITH emp AS (
        SELECT e.employee_id, e.timezone FROM timetrack.employees e WHERE e.employee_id = p_employee_id
    ),
    ev AS (
        SELECT a.id, a.employee_id, a.event_type, a.occurred_at, a.source,
               (a.occurred_at AT TIME ZONE emp.timezone)::date AS work_date,
               LEAD(a.event_type)  OVER w AS next_type,
               LEAD(a.occurred_at) OVER w AS next_at,
               LEAD(a.id)          OVER w AS next_id,
               LEAD(a.source)      OVER w AS next_source
          FROM timetrack.attendance_events a
          JOIN emp ON emp.employee_id = a.employee_id
         WHERE a.status = 'valid'
           -- окно расширено на сутки в обе стороны, чтобы захватить смены через полночь
           AND a.occurred_at >= (p_from::timestamp AT TIME ZONE emp.timezone) - interval '1 day'
           AND a.occurred_at <  ((p_to + 1)::timestamp AT TIME ZONE emp.timezone) + interval '1 day'
        WINDOW w AS (PARTITION BY a.employee_id ORDER BY a.occurred_at, a.id)
    )
    SELECT ev.employee_id,
           ev.work_date,
           ev.occurred_at AS check_in,
           CASE WHEN ev.next_type = 'check_out' THEN ev.next_at END AS check_out,
           CASE WHEN ev.next_type = 'check_out'
                THEN (EXTRACT(EPOCH FROM (ev.next_at - ev.occurred_at)) / 60)::int END AS worked_minutes,
           ev.id AS in_event_id,
           CASE WHEN ev.next_type = 'check_out' THEN ev.next_id END AS out_event_id,
           ev.source AS in_source,
           CASE WHEN ev.next_type = 'check_out' THEN ev.next_source END AS out_source,
           (ev.next_type IS DISTINCT FROM 'check_out') AS incomplete
      FROM ev
     WHERE ev.event_type = 'check_in'
       AND ev.work_date BETWEEN p_from AND p_to
     ORDER BY ev.occurred_at
$$;

-- Дневная сводка по сотруднику за период (включая дни без отметок).
--   scheduled_minutes — плановая длительность смены без обеда
--   worked_minutes    — фактически отработано; если сотрудник не отмечал обед,
--                       из непрерывной смены вычитается break_minutes графика
--   status: present | late | incomplete | absent | day_off
CREATE OR REPLACE FUNCTION timetrack.fn_daily_summary(p_employee_id text, p_from date, p_to date)
RETURNS TABLE (
    employee_id         text,
    work_date           date,
    scheduled           boolean,
    scheduled_minutes   int,
    first_in            timestamptz,
    last_out            timestamptz,
    sessions            int,
    worked_minutes      int,
    break_minutes       int,
    late_minutes        int,
    early_leave_minutes int,
    overtime_minutes    int,
    incomplete          boolean,
    status              text
)
LANGUAGE sql STABLE AS $$
    WITH emp AS (
        SELECT e.employee_id, e.timezone, e.work_schedule AS ws
          FROM timetrack.employees e WHERE e.employee_id = p_employee_id
    ),
    days AS (
        SELECT d::date AS work_date FROM generate_series(p_from, p_to, interval '1 day') AS d
    ),
    sched AS (
        SELECT days.work_date,
               COALESCE((emp.ws -> 'days') @> to_jsonb(EXTRACT(ISODOW FROM days.work_date)::int), false) AS scheduled,
               (days.work_date::timestamp + COALESCE((emp.ws ->> 'start')::time, time '09:00')) AT TIME ZONE emp.timezone AS sched_start,
               (days.work_date::timestamp + COALESCE((emp.ws ->> 'end')::time,   time '18:00')) AT TIME ZONE emp.timezone AS sched_end,
               COALESCE((emp.ws ->> 'break_minutes')::int, 0) AS std_break,
               -- обед удерживается только со смены длиннее порога (по умолчанию 6 ч)
               COALESCE((emp.ws ->> 'break_after_minutes')::int, 360) AS break_after
          FROM days CROSS JOIN emp
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
               sched.break_after,
               agg.first_in, agg.last_out, COALESCE(agg.sessions, 0) AS sessions,
               COALESCE(agg.incomplete, false) AS incomplete,
               CASE WHEN sched.scheduled
                    THEN GREATEST((EXTRACT(EPOCH FROM (sched.sched_end - sched.sched_start)) / 60)::int - sched.std_break, 0)
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
           c.scheduled,
           c.scheduled_minutes,
           c.first_in,
           c.last_out,
           c.sessions,
           c.worked_minutes,
           CASE WHEN c.sessions = 0 THEN 0 ELSE (c.gap_minutes + c.auto_break)::int END AS break_minutes,
           CASE WHEN c.scheduled AND c.first_in IS NOT NULL
                THEN GREATEST((EXTRACT(EPOCH FROM (c.first_in - c.sched_start)) / 60)::int, 0) ELSE 0 END AS late_minutes,
           CASE WHEN c.scheduled AND c.last_out IS NOT NULL AND NOT c.incomplete
                THEN GREATEST((EXTRACT(EPOCH FROM (c.sched_end - c.last_out)) / 60)::int, 0) ELSE 0 END AS early_leave_minutes,
           CASE WHEN c.scheduled THEN GREATEST(c.worked_minutes - c.scheduled_minutes, 0)
                ELSE c.worked_minutes END AS overtime_minutes,
           c.incomplete,
           CASE
               WHEN c.sessions = 0 AND c.scheduled     THEN 'absent'
               WHEN c.sessions = 0 AND NOT c.scheduled THEN 'day_off'
               WHEN c.incomplete                       THEN 'incomplete'
               WHEN c.scheduled AND c.first_in > c.sched_start + interval '1 minute' THEN 'late'
               ELSE 'present'
           END AS status
      FROM calc3 c
     ORDER BY c.work_date
$$;

-- Табель: одна строка на сотрудника с JSON-разделами. Используется отчётами.
--   p_employee_id = NULL → все сотрудники (с фильтром по подразделению)
CREATE OR REPLACE FUNCTION timetrack.fn_timesheet(
    p_employee_id text, p_from date, p_to date,
    p_department text DEFAULT NULL, p_include_inactive boolean DEFAULT false
) RETURNS TABLE (employee jsonb, days jsonb, sessions jsonb, corrections jsonb, totals jsonb)
LANGUAGE sql STABLE AS $$
    SELECT
        jsonb_build_object(
            'employee_id', e.employee_id, 'full_name', e.full_name, 'email', e.email,
            'department', e.department, 'position', e.position, 'timezone', e.timezone,
            'status', e.status, 'work_schedule', e.work_schedule
        ) AS employee,
        ds.days,
        COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.check_in)
                    FROM timetrack.fn_sessions(e.employee_id, p_from, p_to) s), '[]'::jsonb) AS sessions,
        COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.created_at)
                    FROM timetrack.correction_requests c
                   WHERE c.employee_id = e.employee_id
                     AND (c.requested_time::date BETWEEN p_from AND p_to
                          OR c.created_at::date BETWEEN p_from AND p_to)), '[]'::jsonb) AS corrections,
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
                     'scheduled_minutes',   COALESCE(SUM(d.scheduled_minutes), 0),
                     'worked_minutes',      COALESCE(SUM(d.worked_minutes), 0),
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

-- Проблемные дни (для напоминаний сотрудникам): незакрытые смены и прогулы
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

-- =============================================================================
--  Хранение и удаление данных (retention)
-- =============================================================================

-- Чьи биометрические шаблоны пора удалить: уволенные N+ дней назад и те, кто
-- отозвал согласие, но регистрация ещё активна.
CREATE OR REPLACE FUNCTION timetrack.fn_biometrics_due_for_deletion(p_days_after_termination int DEFAULT 30)
RETURNS TABLE (employee_id text, provider text, provider_subject_id text, reason text)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT f.employee_id, f.provider, f.provider_subject_id,
           CASE WHEN e.status = 'terminated' THEN 'terminated' ELSE 'consent_revoked' END AS reason
      FROM timetrack.face_enrollments f
      JOIN timetrack.employees e ON e.employee_id = f.employee_id
     WHERE f.active
       AND (
            (e.status = 'terminated' AND e.terminated_at <= now() - make_interval(days => p_days_after_termination))
         OR NOT timetrack.fn_has_consent(e.employee_id)
       )
$$;

CREATE OR REPLACE FUNCTION timetrack.fn_purge_audit_log(p_retention_days int DEFAULT 730) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_n bigint;
BEGIN
    DELETE FROM timetrack.audit_log a WHERE a.occurred_at < now() - make_interval(days => GREATEST(p_retention_days, 30));
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION timetrack.fn_purge_outbox(p_retention_days int DEFAULT 30) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_n bigint;
BEGIN
    DELETE FROM timetrack.hr_sync_outbox o
     WHERE o.status = 'sent' AND o.sent_at < now() - make_interval(days => GREATEST(p_retention_days, 1));
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;

-- Обезличивание старых событий (по умолчанию НЕ вызывается: табели обычно
-- хранятся годами по требованиям трудового законодательства). Удаляет только
-- технические поля, не сами события.
CREATE OR REPLACE FUNCTION timetrack.fn_anonymize_old_events(p_retention_days int) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_n bigint;
BEGIN
    UPDATE timetrack.attendance_events a
       SET image_hash = NULL, confidence = NULL, liveness_score = NULL, device_id = NULL,
           metadata = '{}'::jsonb
     WHERE a.occurred_at < now() - make_interval(days => GREATEST(p_retention_days, 365))
       AND (a.image_hash IS NOT NULL OR a.confidence IS NOT NULL OR a.metadata <> '{}'::jsonb);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;

COMMIT;
