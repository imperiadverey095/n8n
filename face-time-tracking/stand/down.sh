#!/usr/bin/env bash
# Останавливает службы стенда. Данные на диске не трогает.
set -uo pipefail
cd "$(dirname "$0")"
. ./env.sh || exit 1

stop_by_pattern() {      # шаблон человекочитаемое_имя
	local pids
	pids=$(pgrep -f "$1" 2>/dev/null | grep -v "^$$\$")
	if [ -z "$pids" ]; then echo "  $2: не запущено"; return 0; fi
	echo "$pids" | xargs -r kill 2>/dev/null
	sleep 2
	echo "$pids" | xargs -r kill -9 2>/dev/null
	echo "  $2: остановлено"
}

echo "== Остановка"
stop_by_pattern 'bin/n8n start'      'n8n'
stop_by_pattern 'compreface-stub'    'распознавание'
stop_by_pattern 'hr-sink'            'приёмник кадровой системы'
stop_by_pattern 'smtp-sink'          'SMTP'

PG_BIN=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)
if [ -n "$PG_BIN" ] && [ -d "$PGDATA" ]; then
	PG_OWNER=$(stat -c '%U' "$PGDATA" 2>/dev/null || id -un)
	if [ "$PG_OWNER" = "$(id -un)" ]; then
		"$PG_BIN/pg_ctl" -D "$PGDATA" stop -m fast >/dev/null 2>&1
	else
		su "$PG_OWNER" -c "$PG_BIN/pg_ctl -D $PGDATA stop -m fast" >/dev/null 2>&1
	fi
	echo "  PostgreSQL: остановлено"
fi
