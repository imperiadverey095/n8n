#!/usr/bin/env bash
# Импортирует учётные данные и воркфлоу в n8n стенда и публикует каждый.
# Повторный запуск обновляет воркфлоу на месте: у них постоянные id, а
# import:workflow делает upsert по этому полю.
set -euo pipefail
cd "$(dirname "$0")"
. ./env.sh

CREDS="$STAND_HOME/credentials.json"
# Значения подставляются из окружения — в репозитории лежит только шаблон.
# Своя подстановка вместо envsubst: gettext-base стоит не везде, а python3
# скриптам стенда нужен и так.
umask 077
python3 render-credentials.py credentials.json.template "$CREDS"
chmod 600 "$CREDS"

n8n import:credentials --input="$CREDS"
n8n import:workflow --separate --input="$STAND_HOME/workflows"
# В n8n 2.x update:workflow --all --active=true больше не поддерживается.
n8n list:workflow | cut -d'|' -f1 | while read -r id; do
	[ -n "$id" ] && n8n publish:workflow --id="$id" >/dev/null
done
echo "--- импортировано ---"
n8n list:workflow
echo
echo "Перезапустите n8n, чтобы вебхуки перерегистрировались: ./down.sh && ./up.sh"
