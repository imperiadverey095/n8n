#!/usr/bin/env bash
# Переносит воркфлоу из репозитория в каталог стенда, подменяя адреса внешних
# сервисов на локальные заглушки. Сами файлы в репозитории не меняются.
set -euo pipefail
cd "$(dirname "$0")"
. ./env.sh

SRC="$PROJECT_ROOT/workflows"
DST="$STAND_HOME/workflows"
rm -rf "$DST" && mkdir -p "$DST"
for f in "$SRC"/*.json; do
	sed -e "s|http://compreface-api:8080|http://localhost:${CF_PORT}|g" \
	    -e "s|https://hr.example.com/api/timetrack/events|http://localhost:${HR_SINK_PORT}/events|g" \
	    "$f" > "$DST/$(basename "$f")"
done
echo "перенесено в $DST: $(ls "$DST" | wc -l) файлов"
