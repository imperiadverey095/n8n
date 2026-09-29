#!/usr/bin/env bash
# Окружение локального стенда: n8n как npm-пакет, PostgreSQL рядом, внешние
# сервисы заменены заглушками. Подключается через `. ./env.sh` из остальных
# скриптов каталога.
#
# Секреты сюда не зашиваются: значения берутся из stand/.env (см. .env.example),
# который не коммитится. Так требует AGENTS.md — секреты передаются окружением.

REPO_STAND="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$REPO_STAND/.." && pwd)"

# Значения из .env читаются буквально, как это делает docker compose, а не
# выполняются оболочкой: при `. .env` пароль «pa$word» молча превращался в «pa»,
# а «$(…)» в значении выполнялся. Переменная, уже заданная в окружении, важнее
# файла — так её можно переопределить на один запуск.
if [ -f "$REPO_STAND/.env" ]; then
	# Сначала собираем значения файла (при повторе ключа побеждает последнее, как в
	# compose), потом выставляем те, что не заданы в окружении.
	declare -A _dotenv=()
	while IFS= read -r _line || [ -n "$_line" ]; do
		_line=${_line%$'\r'}
		case "$_line" in ''|'#'*) continue ;; esac
		_key=${_line%%=*}
		if [[ ! "$_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || [ "$_key" = "$_line" ]; then
			echo "env.sh: в .env пропущена строка не вида KEY=VALUE" >&2
			continue
		fi
		_value=${_line#*=}
		# кавычки вокруг всего значения снимаем, как docker compose
		if [[ "$_value" =~ ^\"(.*)\"$ ]] || [[ "$_value" =~ ^\'(.*)\'$ ]]; then
			_value=${BASH_REMATCH[1]}
		fi
		_dotenv[$_key]=$_value
	done < "$REPO_STAND/.env"
	for _key in "${!_dotenv[@]}"; do
		if [ -z "${!_key+x}" ]; then export "$_key=${_dotenv[$_key]}"; fi
	done
	unset _line _key _value _dotenv
fi

STAND_HOME="${STAND_HOME:-$HOME/n8n-stand}"
export STAND_HOME REPO_STAND PROJECT_ROOT

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

# Порты подставляются в адреса воркфлоу через sed и в команды запуска — допускаем
# только числа, чтобы опечатка в .env давала понятную ошибку, а не битый адрес.
for _port_var in TT_DB_PORT CF_PORT HR_SINK_PORT SMTP_PORT; do
	if [[ ! "${!_port_var}" =~ ^[0-9]{1,5}$ ]]; then
		echo "env.sh: $_port_var должен быть числом, а не «${!_port_var}»" >&2
		return 1 2>/dev/null || exit 1
	fi
done
unset _port_var

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
# Снимки не должны попадать на постоянный носитель: хранилище бинарных данных в
# tmpfs, а выполнения воркфлоу с биометрией не сохраняются и удаляются вместе со
# снимком при очистке. На стенде очистка раз в минуту, чтобы проверка шла быстро.
export N8N_BINARY_DATA_STORAGE_PATH="${N8N_BINARY_DATA_STORAGE_PATH:-/dev/shm/n8n-stand-binary}"
export EXECUTIONS_DATA_PRUNE_HARD_DELETE_INTERVAL="${EXECUTIONS_DATA_PRUNE_HARD_DELETE_INTERVAL:-1}"
export EXECUTIONS_DATA_PRUNE=true
export EXECUTIONS_DATA_MAX_AGE=168
export DB_SQLITE_POOL_SIZE=1
export N8N_BLOCK_ENV_ACCESS_IN_NODE=false
# Без IPv6 запуск падает с «address '::' is not available».
export N8N_LISTEN_ADDRESS=127.0.0.1

# --- PostgreSQL ------------------------------------------------------------
# pg_ctl кластера стенда. Кластер обычно принадлежит пользователю postgres,
# поэтому запуск от владельца — через runuser со списком аргументов, а не su -c
# со склеенной строкой: путь с пробелом ломал команду, а «;» в нём выполнялся.
pg_ctl_as_owner() {
	local bin owner
	bin=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)
	[ -z "$bin" ] && bin=$(dirname "$(command -v pg_ctl 2>/dev/null)")
	if [ -z "$bin" ] || [ ! -x "$bin/pg_ctl" ]; then
		echo "pg_ctl не найден" >&2
		return 127
	fi
	if [ ! -d "$PGDATA" ]; then
		echo "каталог кластера PostgreSQL не найден: $PGDATA (задайте PGDATA в stand/.env)" >&2
		return 1
	fi
	owner=$(stat -c '%U' "$PGDATA")
	if [ "$owner" = "$(id -un)" ]; then
		"$bin/pg_ctl" -D "$PGDATA" "$@"
	else
		runuser -u "$owner" -- "$bin/pg_ctl" -D "$PGDATA" "$@"
	fi
}
