#!/usr/bin/env bash
# Нагрузочная и конкурентная проверка отметок (fn_clock) на pgbench.
#   DATABASE_URL=postgres://user:pass@host:5432/postgres scripts/test-concurrency.sh [клиентов] [секунд]
#
# Проверяет два свойства, которые нельзя увидеть в однопоточном самотесте:
#   1. пропускная способность отметок при N одновременных терминалах;
#   2. идемпотентность под гонкой: параллельные повторы одного request_id
#      (терминал переотправляет запрос при обрыве связи) должны получать
#      ответ «дубликат», а не ошибку базы, и создавать ровно одно событие.
set -euo pipefail
cd "$(dirname "$0")/.."
CLIENTS="${1:-20}"
SECONDS_RUN="${2:-10}"
: "${DATABASE_URL:?нужен DATABASE_URL (например postgres://postgres@127.0.0.1:5432/postgres)}"
PGBENCH="${PGBENCH:-$(command -v pgbench || ls /usr/lib/postgresql/*/bin/pgbench 2>/dev/null | head -1)}"
[[ -n "$PGBENCH" ]] || { echo "не найден pgbench (пакет postgresql-client)"; exit 1; }

DB="timetrack_load_$$"
psql "$DATABASE_URL" -X -q -c "CREATE DATABASE ${DB}"
TEST_URL="${DATABASE_URL%/*}/${DB}"
trap 'psql "$DATABASE_URL" -X -q -c "DROP DATABASE IF EXISTS ${DB}" >/dev/null 2>&1 || true; rm -f /tmp/tt-clock-$$.sql /tmp/tt-dup-$$.sql' EXIT

psql "$TEST_URL" -X -q -v ON_ERROR_STOP=1 -f db/001_schema.sql
psql "$TEST_URL" -X -q -v ON_ERROR_STOP=1 -f db/003_calendar_absences.sql
psql "$TEST_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
  FOR i IN 1..50 LOOP
    PERFORM timetrack.fn_upsert_employee('LOAD-' || lpad(i::text, 3, '0'), 'Нагрузка ' || i, NULL, 'Цех', NULL, 'Europe/Moscow', NULL, NULL, NULL, 'loadtest');
    PERFORM timetrack.fn_grant_consent('LOAD-' || lpad(i::text, 3, '0'), 'v1.0');
  END LOOP;
END $$;
SQL

cat > /tmp/tt-clock-$$.sql <<'SQL'
\set emp random(1, 50)
SELECT ok, code FROM timetrack.fn_clock('LOAD-' || lpad(:emp::text, 3, '0'), 'auto', 'face', 'kiosk-load', 'Проходная', 0.97, NULL, 'hash', NULL, NULL, '{}', 'loadtest', 0, 16, true);
SQL
cat > /tmp/tt-dup-$$.sql <<'SQL'
SELECT ok, code FROM timetrack.fn_clock('LOAD-001', 'check_in', 'face', 'kiosk-race', NULL, 0.97, NULL, NULL, 'race-key-1', NULL, '{}', 'loadtest', 0, 16, true);
SQL

echo "== 1. Пропускная способность: ${CLIENTS} терминалов, ${SECONDS_RUN} с"
"$PGBENCH" "$TEST_URL" -n -c "$CLIENTS" -j 4 -T "$SECONDS_RUN" -f /tmp/tt-clock-$$.sql 2>&1 \
  | grep -E "number of transactions actually|number of failed|latency average|^tps"

echo "== 2. Гонка по одному request_id: ${CLIENTS} клиентов × 15 транзакций"
"$PGBENCH" "$TEST_URL" -n -c "$CLIENTS" -j 4 -t 15 -f /tmp/tt-dup-$$.sql 2>&1 \
  | grep -E "number of transactions actually|number of failed|^tps"

FAILED=$(psql "$TEST_URL" -X -At -c "SELECT count(*) FROM timetrack.attendance_events WHERE request_id = 'race-key-1'")
DUPS=$(psql "$TEST_URL" -X -At -c "SELECT COALESCE(sum(c) - count(*), 0) FROM (SELECT count(*) AS c FROM timetrack.attendance_events WHERE request_id IS NOT NULL GROUP BY request_id) x")
echo "== Проверки"
[[ "$FAILED" == "1" ]] && echo "  ok: по спорному request_id создано ровно одно событие" || { echo "  ПРОВАЛ: событий с race-key-1 = $FAILED"; exit 1; }
[[ "$DUPS" == "0" ]] && echo "  ok: дублей по ключам идемпотентности нет" || { echo "  ПРОВАЛ: найдено дублей: $DUPS"; exit 1; }
echo "concurrency test: OK"
