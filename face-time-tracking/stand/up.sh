#!/usr/bin/env bash
# Поднимает стенд целиком: PostgreSQL, три заглушки, n8n.
# Идемпотентен — уже запущенные службы пропускаются.
set -uo pipefail
cd "$(dirname "$0")"
. ./env.sh || exit 1

mkdir -p "$STAND_HOME" "$STAND_HOME/mail"

busy() { (echo > "/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

start_stub() {           # имя_файла порт человекочитаемое_имя
	local file=$1 port=$2 title=$3
	if busy "$port"; then echo "  $title уже слушает :$port"; return 0; fi
	nohup node "./$file" > "$STAND_HOME/$(basename "$file" .mjs).log" 2>&1 &
	sleep 1
	busy "$port" && echo "  $title поднят на :$port" || echo "  $title НЕ поднялся, см. $STAND_HOME/$(basename "$file" .mjs).log"
}

echo "== PostgreSQL"
if busy "$TT_DB_PORT"; then
	echo "  уже слушает :$TT_DB_PORT"
else
	PG_BIN=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)
	[ -z "$PG_BIN" ] && PG_BIN=$(dirname "$(command -v pg_ctl 2>/dev/null)")
	if [ -z "$PG_BIN" ] || [ ! -x "$PG_BIN/pg_ctl" ]; then
		echo "  pg_ctl не найден — запустите PostgreSQL сами на порту $TT_DB_PORT" >&2
	else
		# Кластер обычно принадлежит пользователю postgres, поэтому запуск от него.
		PG_OWNER=$(stat -c '%U' "$PGDATA" 2>/dev/null || echo "$USER")
		if [ "$PG_OWNER" = "$(id -un)" ]; then
			"$PG_BIN/pg_ctl" -D "$PGDATA" -l "$PGDATA/../pg.log" -o "-p $TT_DB_PORT -k /tmp" start -w -t 60 >/dev/null
		else
			su "$PG_OWNER" -c "$PG_BIN/pg_ctl -D $PGDATA -l $PGDATA/../pg.log -o '-p $TT_DB_PORT -k /tmp' start -w -t 60" >/dev/null
		fi
		busy "$TT_DB_PORT" && echo "  поднят на :$TT_DB_PORT" || echo "  НЕ поднялся, см. журнал рядом с $PGDATA" >&2
	fi
fi

echo "== Заглушки"
start_stub compreface-stub.mjs "$CF_PORT"      "распознавание"
start_stub hr-sink.mjs         "$HR_SINK_PORT" "приёмник кадровой системы"
start_stub smtp-sink.mjs       "$SMTP_PORT"    "SMTP"

echo "== n8n"
if busy "$N8N_PORT"; then
	echo "  уже слушает :$N8N_PORT"
else
	( cd "$STAND_HOME" && nohup n8n start > "$STAND_HOME/n8n.log" 2>&1 & )
	printf '  запускается'
	for _ in $(seq 1 40); do
		if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$N8N_PORT/healthz" 2>/dev/null)" = "200" ]; then
			echo; echo "  готов на :$N8N_PORT"; break
		fi
		printf '.'; sleep 5
	done
	busy "$N8N_PORT" || { echo; echo "  НЕ поднялся, см. $STAND_HOME/n8n.log" >&2; }
fi

echo
echo "Дальше: ./sync-workflows.sh && ./import.sh   — перенести и опубликовать воркфлоу"
echo "        ./verify.sh                          — показать состояние базы"
