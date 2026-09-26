#!/usr/bin/env bash
# Сквозной прогон через настоящий n8n: регистрация, отметка, отчёты, корректировка.
# Токены читаются из файлов в каталоге стенда (см. tokens.sh), чтобы их значения
# не попадали в список процессов и в журналы.
set -uo pipefail
cd "$(dirname "$0")"
. ./env.sh || exit 1
W="${N8N_URL:-http://localhost:$N8N_PORT}/webhook"
HR_TOKEN="${HR_TOKEN:-$(cat "$STAND_HOME/tok.hr" 2>/dev/null)}"
DEVICE_TOKEN="${DEVICE_TOKEN:-$(cat "$STAND_HOME/tok.device" 2>/dev/null)}"
EMPLOYEE_TOKEN="${EMPLOYEE_TOKEN:-$(cat "$STAND_HOME/tok.employee" 2>/dev/null)}"
for v in HR_TOKEN DEVICE_TOKEN EMPLOYEE_TOKEN; do
	[ -n "${!v}" ] || { echo "e2e.sh: нет $v — сначала запустите ./tokens.sh" >&2; exit 1; }
done
cd "$STAND_HOME"   # снимки и отчёт лежат рядом с данными стенда
j() { python3 -m json.tool 2>/dev/null || cat; }
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

step "1. Регистрация сотрудника и лица (HR-токен)"
curl -sS -X POST "$W/timetrack/employees/enroll" -H "X-Api-Token: $HR_TOKEN" \
  -F "employee_id=EMP-001" -F "full_name=Иванов Иван Иванович" -F "email=ivanov@example.com" \
  -F "department=Склад" -F "timezone=Europe/Moscow" -F "consent_granted=true" \
  -F "consent_document_ref=Согласие №2026-001" -F "image=@face-emp001.png" | j

step "2. Отметка по лицу (тот же снимок, токен терминала)"
REQ="e2e-$(date +%s)"
curl -sS -X POST "$W/timetrack/clock" -H "X-Api-Token: $DEVICE_TOKEN" \
  -F "device_id=kiosk-1" -F "location=Проходная" -F "request_id=$REQ" -F "image=@face-emp001.png" | j

step "3. Повтор того же request_id (обрыв связи у терминала)"
curl -sS -X POST "$W/timetrack/clock" -H "X-Api-Token: $DEVICE_TOKEN" \
  -F "device_id=kiosk-1" -F "request_id=$REQ" -F "image=@face-emp001.png" | j

step "4. Незнакомое лицо"
curl -sS -o /tmp/e2e-unknown.json -w 'HTTP %{http_code}\n' -X POST "$W/timetrack/clock" \
  -H "X-Api-Token: $DEVICE_TOKEN" -F "device_id=kiosk-1" -F "image=@face-stranger.png"
cat /tmp/e2e-unknown.json | j

step "5. Неверный токен терминала"
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -X POST "$W/timetrack/clock" \
  -H "X-Api-Token: wrong-token-0000000000000000" -F "image=@face-emp001.png"

step "6. Отчёт summary (HR)"
curl -sS "$W/timetrack/reports?type=summary&format=json" -H "X-Api-Token: $HR_TOKEN" | j | head -30

step "7. Мои записи (сотрудник)"
curl -sS "$W/timetrack/me/records" -H "X-Api-Token: $EMPLOYEE_TOKEN" | j | head -20

step "8. Запрос корректировки (сотрудник)"
curl -sS -X POST "$W/timetrack/me/corrections" -H "X-Api-Token: $EMPLOYEE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"action\":\"add\",\"requested_type\":\"check_out\",\"requested_time\":\"$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)\",\"reason\":\"Забыл отметиться на выходе\"}" | j

step "9. Очередь корректировок (HR)"
curl -sS "$W/timetrack/hr/corrections?status=pending" -H "X-Api-Token: $HR_TOKEN" | j | head -25

step "10. Отчёт CSV (HR)"
curl -sS "$W/timetrack/reports?type=standard&format=csv" -H "X-Api-Token: $HR_TOKEN" -o e2e-report.csv \
  && echo "сохранено: $(wc -l < e2e-report.csv) строк" && head -2 e2e-report.csv
