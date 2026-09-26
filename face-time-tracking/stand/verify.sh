#!/usr/bin/env bash
# Состояние базы после сквозного прогона. Только SELECT — ничего не меняет.
set -uo pipefail
cd "$(dirname "$0")"
. ./env.sh || exit 1
DB="$TT_DB_URL"
echo "== Сотрудники и биометрия"
psql "$DB" -X -c "SELECT e.employee_id, e.full_name, timetrack.fn_has_consent(e.employee_id) AS consent,
  (SELECT count(*) FROM timetrack.face_enrollments f WHERE f.employee_id = e.employee_id AND f.active) AS enrollments
  FROM timetrack.employees e ORDER BY e.employee_id"
echo "== События учёта (фото нет, только хэш и схожесть)"
psql "$DB" -X -c "SELECT id, employee_id, event_type, to_char(occurred_at AT TIME ZONE 'Europe/Moscow','DD.MM HH24:MI') AS msk,
  source, device_id, confidence, left(image_hash, 12) AS image_hash, request_id, status
  FROM timetrack.attendance_events ORDER BY id"
echo "== Запросы на корректировку"
psql "$DB" -X -c "SELECT left(id::text,8) AS id, employee_id, action, requested_type,
  to_char(requested_time AT TIME ZONE 'Europe/Moscow','DD.MM HH24:MI') AS msk, status, reviewed_by FROM timetrack.correction_requests ORDER BY created_at"
echo "== Очередь событий для кадровой системы"
psql "$DB" -X -c "SELECT status, count(*) FROM timetrack.hr_sync_outbox GROUP BY status ORDER BY status"
echo "== Журнал аудита (последние 12)"
psql "$DB" -X -c "SELECT to_char(occurred_at AT TIME ZONE 'Europe/Moscow','HH24:MI:SS') AS msk, actor, actor_role, action, entity_type, entity_id
  FROM timetrack.audit_log ORDER BY id DESC LIMIT 12"
