#!/usr/bin/env bash
# Дымовой тест API через curl. Нужны: запущенный n8n с активными воркфлоу, токены из db/002_seed_demo.sql
# (или выпущенные fn_issue_token) и два фото одного человека.
#   N8N_URL=http://localhost:5678 HR_TOKEN=... DEVICE_TOKEN=... EMPLOYEE_TOKEN=... \
#   ENROLL_PHOTO=./photos/ivanov-1.jpg CLOCK_PHOTO=./photos/ivanov-2.jpg scripts/smoke-test.sh
set -euo pipefail
: "${N8N_URL:=http://localhost:5678}"
: "${HR_TOKEN:?}" "${DEVICE_TOKEN:?}" "${EMPLOYEE_TOKEN:?}" "${ENROLL_PHOTO:?}" "${CLOCK_PHOTO:?}"
EMP="${EMPLOYEE_ID:-EMP-001}"
W="$N8N_URL/webhook"
j() { python3 -m json.tool 2>/dev/null || cat; }

echo "== 1. Регистрация сотрудника и лица (HR)"
curl -sS -X POST "$W/timetrack/employees/enroll" -H "X-Api-Token: $HR_TOKEN" \
  -F "employee_id=$EMP" -F "full_name=Иванов Иван Иванович" -F "email=ivanov@example.com" \
  -F "department=Склад" -F "timezone=Europe/Moscow" -F "consent_granted=true" \
  -F "consent_document_ref=Согласие №2026-001" -F "image=@$ENROLL_PHOTO" | j

echo "== 2. Отметка по лицу с терминала (auto → приход)"
curl -sS -X POST "$W/timetrack/clock" -H "X-Api-Token: $DEVICE_TOKEN" \
  -F "device_id=kiosk-1" -F "location=Проходная" -F "request_id=smoke-$(date +%s)" -F "image=@$CLOCK_PHOTO" | j

echo "== 3. Повтор через секунду → debounced (антидребезг)"
curl -sS -X POST "$W/timetrack/clock" -H "X-Api-Token: $DEVICE_TOKEN" -F "image=@$CLOCK_PHOTO" | j

echo "== 4. Ручная отметка личным токеном (уход)"
curl -sS -X POST "$W/timetrack/clock/manual" -H "X-Api-Token: $EMPLOYEE_TOKEN" \
  -H 'Content-Type: application/json' -d '{"event_type":"check_out","request_id":"smoke-manual-'"$(date +%s)"'"}' | j

echo "== 5. Мои записи (сотрудник)"
curl -sS "$W/timetrack/me/records" -H "X-Api-Token: $EMPLOYEE_TOKEN" | j | head -40

echo "== 6. Запрос корректировки (добавить пропущенный уход вчера)"
curl -sS -X POST "$W/timetrack/me/corrections" -H "X-Api-Token: $EMPLOYEE_TOKEN" -H 'Content-Type: application/json' \
  -d '{"action":"add","requested_type":"check_out","requested_time":"'"$(date -u -d 'yesterday 18:00' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"'","reason":"Забыл отметиться на выходе"}' | j

echo "== 7. Очередь корректировок (HR)"
curl -sS "$W/timetrack/hr/corrections?status=pending" -H "X-Api-Token: $HR_TOKEN" | j | head -30

echo "== 8. Отчёт standard за текущий месяц (HR, HTML → файл report.html)"
curl -sS "$W/timetrack/reports?type=standard&format=html&employee_id=$EMP" -H "X-Api-Token: $HR_TOKEN" -o report.html && echo "saved report.html ($(wc -c < report.html) bytes)"

echo "== 9. Сводный отчёт summary (JSON)"
curl -sS "$W/timetrack/reports?type=summary&format=json" -H "X-Api-Token: $HR_TOKEN" | j | head -40

echo "== 10. CSV по дням → timesheet.csv"
curl -sS "$W/timetrack/reports?type=standard&format=csv" -H "X-Api-Token: $HR_TOKEN" -o timesheet.csv && head -3 timesheet.csv

echo "== 11. Неверный токен → 401"
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' "$W/timetrack/reports" -H "X-Api-Token: wrong"
