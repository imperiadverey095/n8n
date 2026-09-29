#!/usr/bin/env bash
# Останавливает службы стенда. Данные на диске не трогает.
#
# Процессы находятся по PID-файлам, которые пишет up.sh, а перед остановкой
# проверяется, что под этим PID действительно наша служба. Поиск по шаблону
# командной строки (pgrep -f) задевал посторонние процессы — например, редактор
# с открытым файлом, в имени которого есть «hr-sink».
set -uo pipefail
cd "$(dirname "$0")"
. ./env.sh || exit 1

stop_pidfile() {         # имя метка_в_командной_строке человекочитаемое_имя
	local name=$1 marker=$2 title=$3 pidfile pid cmdline
	pidfile="$STAND_HOME/$name.pid"
	if [ ! -f "$pidfile" ]; then
		echo "  $title: не запущено через up.sh (нет $name.pid)"
		return 0
	fi
	pid=$(cat "$pidfile")
	cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
	if [ -z "$cmdline" ]; then
		echo "  $title: процесс уже завершён"
		rm -f "$pidfile"
		return 0
	fi
	case "$cmdline" in
		*"$marker"*) ;;
		*)
			# PID переиспользован другим процессом — трогать его нельзя.
			echo "  $title: PID $pid занят посторонним процессом, не трогаю"
			rm -f "$pidfile"
			return 0
			;;
	esac
	kill "$pid" 2>/dev/null
	for _ in $(seq 1 20); do
		[ -d "/proc/$pid" ] || break
		sleep 0.5
	done
	[ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null
	rm -f "$pidfile"
	echo "  $title: остановлено"
}

echo "== Остановка"
stop_pidfile n8n             'bin/n8n'             'n8n'
stop_pidfile compreface-stub 'compreface-stub.mjs' 'распознавание'
stop_pidfile hr-sink         'hr-sink.mjs'         'приёмник кадровой системы'
stop_pidfile smtp-sink       'smtp-sink.mjs'       'SMTP'

if [ -d "$PGDATA" ] && pg_ctl_as_owner status >/dev/null 2>&1; then
	pg_ctl_as_owner stop -m fast >/dev/null 2>&1 && echo "  PostgreSQL: остановлено" || echo "  PostgreSQL: остановить не удалось" >&2
else
	echo "  PostgreSQL: не запущено"
fi
