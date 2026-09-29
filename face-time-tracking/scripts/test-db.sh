#!/usr/bin/env bash
# Прогоняет схему и самотест на временной базе.
#   DATABASE_URL=postgres://user:pass@host:5432/db scripts/test-db.sh   — на существующем сервере (создаст БД timetrack_selftest)
#   scripts/test-db.sh                                                — поднимет временный PostgreSQL через docker
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${DATABASE_URL:-}" ]]; then
  ADMIN_URL="$DATABASE_URL"
  DB="timetrack_selftest_$$"
  psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE ${DB}"
  TEST_URL="${ADMIN_URL%/*}/${DB}"
  trap 'psql "$ADMIN_URL" -q -c "DROP DATABASE IF EXISTS ${DB}"' EXIT
else
  command -v docker >/dev/null || { echo "нужен docker или DATABASE_URL"; exit 1; }
  CONTAINER="timetrack-selftest-$$"
  docker run -d --rm --name "$CONTAINER" -e POSTGRES_PASSWORD=test -p 127.0.0.1:0:5432 postgres:16-alpine >/dev/null
  trap 'docker stop "$CONTAINER" >/dev/null' EXIT
  PORT=$(docker port "$CONTAINER" 5432/tcp | head -1 | sed 's/.*://')
  TEST_URL="postgres://postgres:test@127.0.0.1:${PORT}/postgres"
  for i in $(seq 1 30); do
    docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done
fi

psql "$TEST_URL" -v ON_ERROR_STOP=1 -q -f db/001_schema.sql
psql "$TEST_URL" -v ON_ERROR_STOP=1 -q -f db/003_calendar_absences.sql
# самотест рассчитан на пустую схему и откатывает свои данные
psql "$TEST_URL" -v ON_ERROR_STOP=1 -f db/900_selftest.sql 2>&1 | grep -E "NOTICE|SELFTEST|ERROR"
# демо-данные должны применяться без ошибок (вывод токенов подавлен)
psql "$TEST_URL" -v ON_ERROR_STOP=1 -q -f db/002_seed_demo.sql >/dev/null
echo "schema + selftest + seed: OK"
