#!/usr/bin/env bash
# Импорт воркфлоу в n8n.
#   1) через CLI внутри контейнера docker compose:   scripts/import-workflows.sh compose
#   2) через REST API n8n (нужен API-ключ):           N8N_URL=http://localhost:5678 N8N_API_KEY=... scripts/import-workflows.sh api
# Перед импортом создайте credentials с именами из docs/README (Timetrack Postgres, CompreFace Recognition API Key,
# Timetrack SMTP, HR System API) — n8n подставит их по имени; иначе выберите вручную в каждой ноде.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-compose}"

case "$MODE" in
  compose)
    docker compose exec n8n n8n import:credentials --input=/workflows/../credentials.json 2>/dev/null || true
    docker compose exec n8n n8n import:workflow --separate --input=/workflows
    # В n8n 2.x активация делается по одному воркфлоу: update:workflow --all больше не поддерживается
    docker compose exec n8n sh -lc 'n8n list:workflow | cut -d"|" -f1 | while read -r id; do [ -n "$id" ] && n8n publish:workflow --id="$id"; done'
    docker compose restart n8n
    echo "Импортировано и опубликовано. Назначьте Error Workflow (Timetrack 00) в настройках каждого воркфлоу и проверьте ноды Config."
    ;;
  api)
    : "${N8N_URL:?N8N_URL required}" "${N8N_API_KEY:?N8N_API_KEY required}"
    for f in workflows/*.json; do
      # публичный API принимает только name/nodes/connections/settings
      payload=$(node -e 'const w=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write(JSON.stringify({name:w.name,nodes:w.nodes,connections:w.connections,settings:w.settings}))' "$f")
      code=$(curl -sS -o /tmp/import-result.json -w '%{http_code}' -X POST "$N8N_URL/api/v1/workflows" \
        -H "X-N8N-API-KEY: $N8N_API_KEY" -H 'Content-Type: application/json' --data-binary "$payload")
      echo "$f → HTTP $code $(node -e 'try{const r=JSON.parse(require("fs").readFileSync("/tmp/import-result.json","utf8"));console.log(r.id||r.message||"")}catch(e){}')"
    done
    ;;
  *)
    echo "usage: $0 [compose|api]"; exit 1 ;;
esac
