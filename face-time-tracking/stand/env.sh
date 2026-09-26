#!/usr/bin/env bash
# Окружение локального стенда: n8n как npm-пакет, PostgreSQL рядом, внешние
# сервисы заменены заглушками. Подключается через `. ./env.sh` из остальных
# скриптов каталога.
#
# Секреты сюда не зашиваются: значения берутся из stand/.env (см. .env.example),
# который не коммитится. Так требует AGENTS.md — секреты передаются окружением.

STAND_HOME="${STAND_HOME:-$HOME/n8n-stand}"
REPO_STAND="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$REPO_STAND/.." && pwd)"
export STAND_HOME REPO_STAND PROJECT_ROOT

# Значения из .env рядом со скриптами, если файл есть.
if [ -f "$REPO_STAND/.env" ]; then
	set -a
	. "$REPO_STAND/.env"
	set +a
fi

# --- обязательные значения -------------------------------------------------
if [ -z "${N8N_ENCRYPTION_KEY:-}" ]; then
	echo "env.sh: задайте N8N_ENCRYPTION_KEY (в stand/.env или в окружении)" >&2
	echo "        пример: openssl rand -hex 16" >&2
	return 1 2>/dev/null || exit 1
fi
export N8N_ENCRYPTION_KEY

# --- база данных учёта -----------------------------------------------------
export TT_DB_HOST="${TT_DB_HOST:-127.0.0.1}"
export TT_DB_PORT="${TT_DB_PORT:-54329}"
export TT_DB_NAME="${TT_DB_NAME:-timetrack}"
export TT_DB_USER="${TT_DB_USER:-postgres}"
export TT_DB_PASSWORD="${TT_DB_PASSWORD:-}"
export PGDATA="${PGDATA:-$HOME/pgdata}"
# Строка подключения для psql в скриптах стенда. Пароль в неё не подставляется:
# он уходит в PGPASSWORD, чтобы не светиться в списке процессов.
export TT_DB_URL="postgres://${TT_DB_USER}@${TT_DB_HOST}:${TT_DB_PORT}/${TT_DB_NAME}"
[ -n "$TT_DB_PASSWORD" ] && export PGPASSWORD="$TT_DB_PASSWORD"

# --- заглушки внешних сервисов --------------------------------------------
export CF_PORT="${CF_PORT:-8010}"
export CF_API_KEY="${CF_API_KEY:-stub-recognition-key}"
export HR_SINK_PORT="${HR_SINK_PORT:-8011}"
export HR_API_TOKEN="${HR_API_TOKEN:-stub-hr-token}"
export SMTP_PORT="${SMTP_PORT:-1025}"
export SMTP_USER="${SMTP_USER:-timetrack@example.com}"
export SMTP_PASSWORD="${SMTP_PASSWORD:-stub-smtp-password}"

# --- n8n -------------------------------------------------------------------
# n8n 2.x требует Node.js 24; если он лежит отдельно, добавьте его в PATH здесь.
[ -d /opt/node24/bin ] && export PATH=/opt/node24/bin:$PATH
export N8N_USER_FOLDER="$STAND_HOME/.n8n"
export N8N_PORT="${N8N_PORT:-5678}"
export N8N_HOST=localhost
export N8N_PROTOCOL=http
export WEBHOOK_URL="http://localhost:${N8N_PORT}/"
export GENERIC_TIMEZONE="${GENERIC_TIMEZONE:-Europe/Moscow}"
export N8N_DIAGNOSTICS_ENABLED=false
export N8N_VERSION_NOTIFICATIONS_ENABLED=false
export N8N_TEMPLATES_ENABLED=false
export N8N_SECURE_COOKIE=false
export N8N_DEFAULT_BINARY_DATA_MODE=filesystem
export EXECUTIONS_DATA_PRUNE=true
export EXECUTIONS_DATA_MAX_AGE=168
export DB_SQLITE_POOL_SIZE=1
export N8N_BLOCK_ENV_ACCESS_IN_NODE=false
# Без IPv6 запуск падает с «address '::' is not available».
export N8N_LISTEN_ADDRESS=127.0.0.1
