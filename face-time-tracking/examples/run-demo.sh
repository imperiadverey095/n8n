#!/usr/bin/env bash
# Полный прогон демонстрации на чистой базе:
#   схема → сценарий дня (examples/demo-day.sql) → отчёт кодом воркфлоу (HTML/CSV/JSON)
#   → скриншот HTML → смоделированный HTTP-обмен терминала с воркфлоу 02.
# Использует сервер PostgreSQL из DATABASE_URL (создаёт БД timetrack_demo) либо параметры PG* окружения.
#   DATABASE_URL=postgres://user:pass@host:5432/postgres examples/run-demo.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=examples/output
mkdir -p "$OUT"
ADMIN_URL="${DATABASE_URL:-postgres://${PGUSER:-postgres}@${PGHOST:-localhost}:${PGPORT:-5432}/postgres}"
DB="timetrack_demo"
psql "$ADMIN_URL" -X -q -c "DROP DATABASE IF EXISTS ${DB}" -c "CREATE DATABASE ${DB}"
DEMO_URL="${ADMIN_URL%/*}/${DB}"
psql "$DEMO_URL" -X -q -v ON_ERROR_STOP=1 -f db/001_schema.sql
psql "$DEMO_URL" -X -q -v ON_ERROR_STOP=1 -f db/003_calendar_absences.sql
# токены печатаются в терминал, но в сохраняемый артефакт идут замаскированными
psql "$DEMO_URL" -X -f examples/demo-day.sql | tee "$OUT/demo-day.raw" 
sed -E 's/[0-9a-f]{64}/<значение токена показано один раз в терминале>/g' "$OUT/demo-day.raw" > "$OUT/demo-day.txt"
rm -f "$OUT/demo-day.raw"
DATABASE_URL="$DEMO_URL" node examples/render-report.mjs
DATABASE_URL="$DEMO_URL" node examples/simulate-clock-request.mjs | tee "$OUT/simulated-http.txt"
CHROME="${CHROME:-$(command -v chromium || command -v google-chrome || ls /opt/pw-browsers/chromium_headless_shell-*/chrome-linux/headless_shell 2>/dev/null | head -1 || true)}"
if [[ -n "$CHROME" ]]; then
  "$CHROME" --headless --disable-gpu --no-sandbox --hide-scrollbars --window-size=1100,1500 \
    --screenshot="$PWD/$OUT/report.png" "file://$PWD/$OUT/report.html" >/dev/null 2>&1 && echo "screenshot: $OUT/report.png"
fi
echo "demo finished: $OUT/"
