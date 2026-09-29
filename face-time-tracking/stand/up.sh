#!/usr/bin/env bash
# Поднимает стенд целиком: PostgreSQL, три заглушки, n8n.
# Идемпотентен — уже запущенные службы пропускаются. PID каждой запущенной службы
# записывается в $STAND_HOME/<имя>.pid: по нему её останавливает down.sh.
set -uo pipefail
cd "$(dirname "$0")"
. ./env.sh || exit 1

# В журналах заглушек и n8n — идентификаторы сотрудников и темы писем.
umask 077
mkdir -p "$STAND_HOME" "$STAND_HOME/mail"

busy() { (echo > "/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

start_stub() {           # имя_файла порт человекочитаемое_имя
	local file=$1 port=$2 title=$3 name
	name=$(basename "$file" .mjs)
	if busy "$port"; then echo "  $title уже слушает :$port"; return 0; fi
	nohup node "./$file" > "$STAND_HOME/$name.log" 2>&1 &
	echo $! > "$STAND_HOME/$name.pid"
	# На холодном старте node поднимается дольше секунды, поэтому ждём порт с
	# запасом, а не проверяем один раз: иначе живая служба объявляется упавшей.
	for _ in $(seq 1 20); do
		busy "$port" && { echo "  $title поднят на :$port"; return 0; }
		sleep 0.5
	done
	echo "  $title НЕ поднялся, см. $STAND_HOME/$name.log"
}

echo "== PostgreSQL"
if busy "$TT_DB_PORT"; then
	echo "  уже слушает :$TT_DB_PORT"
elif pg_ctl_as_owner -l "$PGDATA/../pg.log" -o "-p $TT_DB_PORT -k /tmp" start -w -t 60 >/dev/null; then
	echo "  поднят на :$TT_DB_PORT"
else
	echo "  НЕ поднялся, см. журнал рядом с $PGDATA" >&2
fi

echo "== Заглушки"
start_stub compreface-stub.mjs "$CF_PORT"      "распознавание"
start_stub hr-sink.mjs         "$HR_SINK_PORT" "приёмник кадровой системы"
start_stub smtp-sink.mjs       "$SMTP_PORT"    "SMTP"

echo "== n8n"
if busy "$N8N_PORT"; then
	echo "  уже слушает :$N8N_PORT"
else
	mkdir -p "$N8N_BINARY_DATA_STORAGE_PATH"
	# exec — чтобы в n8n.pid попал сам процесс n8n, а не промежуточная оболочка.
	( cd "$STAND_HOME" && exec nohup n8n start > "$STAND_HOME/n8n.log" 2>&1 ) &
	echo $! > "$STAND_HOME/n8n.pid"
	printf '  запускается'
	# healthz отвечает 200 раньше, чем n8n активирует воркфлоу, — тогда вебхуки ещё
	# отдают 404, и прогон сразу после «готов» проваливается. Готовность — это ответ
	# вебхука отметки: без токена он должен вернуть 401, а не 404.
	ready=0
	for _ in $(seq 1 60); do
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST "http://localhost:$N8N_PORT/webhook/timetrack/clock" 2>/dev/null)
		if [ "$code" = "401" ]; then ready=1; break; fi
		printf '.'; sleep 5
	done
	echo
	if [ "$ready" = 1 ]; then
		echo "  готов на :$N8N_PORT, вебхуки зарегистрированы"
	elif busy "$N8N_PORT"; then
		echo "  n8n запущен, но вебхук отметки не отвечает — импортированы ли воркфлоу? (./import.sh)" >&2
	else
		echo "  НЕ поднялся, см. $STAND_HOME/n8n.log" >&2
	fi
fi

echo
echo "Дальше: ./sync-workflows.sh && ./import.sh   — перенести и опубликовать воркфлоу"
echo "        ./verify.sh                          — показать состояние базы"
