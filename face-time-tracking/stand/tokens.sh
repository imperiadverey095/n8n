#!/usr/bin/env bash
# Выпускает токен доступа и кладёт его в файл с правами 600.
#   ./tokens.sh employee EMP-001          — личный кабинет сотрудника
#   ./tokens.sh device   'Kiosk 2' 'Цех 2'
#   ./tokens.sh hr       'HR portal'
#   ./tokens.sh system   'Scheduler'
#
# Значение токена не печатается: оно нужно скриптам, а не глазам. Все значения
# уходят в psql через переменные (:'name'), а SQL читается со stdin — при -c
# psql переменные не подставляет, а склейка строк открыла бы дорогу инъекции.
set -euo pipefail
cd "$(dirname "$0")"
. ./env.sh

ROLE=${1:-}
EMP=''
LOC=''
case "$ROLE" in
	employee)
		EMP=${2:?укажите employee_id}
		NAME="Личный кабинет $EMP"
		FILE=tok.employee
		;;
	device)
		NAME=${2:-Kiosk 1}
		LOC=${3:-}
		FILE=tok.device
		;;
	hr|system)
		NAME=${2:-$ROLE}
		FILE="tok.$ROLE"
		;;
	*)
		echo "использование: $0 {employee <EMP-ID>|device [имя] [место]|hr [имя]|system [имя]}" >&2
		exit 1
		;;
esac

umask 077
# Прежние токены с тем же именем отключаем, иначе на стенде копятся действующие
# токены от старых запусков.
psql "$TT_DB_URL" -X -q -v name="$NAME" -f - >/dev/null <<'SQL'
UPDATE timetrack.api_clients SET active = false WHERE name = :'name' AND active;
SQL

psql "$TT_DB_URL" -X -t -A -v name="$NAME" -v role="$ROLE" -v emp="$EMP" -v loc="$LOC" \
	-f - > "$STAND_HOME/$FILE" <<'SQL'
SELECT timetrack.fn_issue_token(:'name', :'role', NULLIF(:'emp', ''), NULLIF(:'loc', ''));
SQL
chmod 600 "$STAND_HOME/$FILE"
[ -s "$STAND_HOME/$FILE" ] || { echo "tokens.sh: токен не выпущен" >&2; exit 1; }
echo "выпущен $FILE (роль $ROLE), значение в $STAND_HOME/$FILE"
