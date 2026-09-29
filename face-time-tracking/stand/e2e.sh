#!/usr/bin/env bash
# Сквозной прогон через настоящий n8n: регистрация, отметка, отчёты, корректировка.
# Каждый шаг проверяется: код выхода ненулевой, если хоть одна проверка не прошла.
# Раньше скрипт только печатал ответы и завершался успешно даже на стенде, где
# все вебхуки отвечали 404.
#
# Токены читаются из файлов в каталоге стенда (см. tokens.sh) и уходят в curl
# заголовком из файла, чтобы их значения не попадали в список процессов.
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

# Токен уходит в curl заголовком из файла (-H @файл), а не аргументом: аргументы
# любой процесс видит в ps. printf — встроенная команда, отдельного процесса нет.
# В отчёте CSV имена и время прихода, поэтому всё создаётся с правами владельца.
umask 077
HDR_DIR=$(mktemp -d)
trap 'rm -rf "$HDR_DIR"' EXIT
printf 'X-Api-Token: %s\n' "$HR_TOKEN" > "$HDR_DIR/hr"
printf 'X-Api-Token: %s\n' "$DEVICE_TOKEN" > "$HDR_DIR/device"
printf 'X-Api-Token: %s\n' "$EMPLOYEE_TOKEN" > "$HDR_DIR/employee"
unset HR_TOKEN DEVICE_TOKEN EMPLOYEE_TOKEN
cd "$STAND_HOME"   # снимки и отчёт лежат рядом с данными стенда

FAILS=0
BODY="$HDR_DIR/body"
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# call МЕТОД ПУТЬ [аргументы curl…] — тело ответа в $BODY, код в $STATUS
call() {
	local method=$1 path=$2
	shift 2
	STATUS=$(curl -sS -o "$BODY" -w '%{http_code}' -X "$method" "$W/$path" "$@")
}

# Печать без конвейера с head: под pipefail head обрывает json.tool по SIGPIPE,
# конвейер «падает», и тело печаталось второй раз сырым.
show() {
	if python3 -m json.tool < "$BODY" > "$HDR_DIR/pretty" 2>/dev/null; then
		head -n "${1:-20}" "$HDR_DIR/pretty"
	else
		head -c 600 "$BODY"; echo
	fi
}

# expect ОПИСАНИЕ УСЛОВИЕ — условие на Python над d (JSON ответа), s (HTTP-код)
# и raw (тело как текст). Условия — литералы этого файла, а не внешний ввод.
expect() {
	local what=$1 cond=$2
	if python3 - "$BODY" "$STATUS" "$cond" <<'PY'
import json
import sys
path, s, cond = sys.argv[1], int(sys.argv[2] or 0), sys.argv[3]
raw = open(path, encoding="utf-8", errors="replace").read()
try:
    d = json.loads(raw)
except ValueError:
    d = None
sys.exit(0 if eval(cond, {}, {"d": d, "s": s, "raw": raw}) else 1)
PY
	then
		echo "  ✓ $what"
	else
		echo "  ✗ $what (HTTP $STATUS)"
		FAILS=$((FAILS + 1))
	fi
}

step "1. Регистрация сотрудника и лица (HR-токен)"
call POST timetrack/employees/enroll -H @"$HDR_DIR/hr" \
	-F "employee_id=EMP-001" -F "full_name=Иванов Иван Иванович" -F "email=ivanov@example.com" \
	-F "department=Склад" -F "timezone=Europe/Moscow" -F "consent_granted=true" \
	-F "consent_document_ref=Согласие №2026-001" -F "image=@face-emp001.png"
show 10
# 201 Created — по docs/api.md
expect "сотрудник и лицо зарегистрированы" 's == 201 and d and d.get("ok") is True and d.get("code") == "enrolled"'

step "2. Отметка по лицу (тот же снимок, токен терминала)"
REQ="e2e-$(date +%s)"
call POST timetrack/clock -H @"$HDR_DIR/device" \
	-F "device_id=kiosk-1" -F "location=Проходная" -F "request_id=$REQ" -F "image=@face-emp001.png"
show 12
# debounced — законный ответ, если прошлая отметка была меньше двух минут назад
expect "лицо узнано, отметка принята" 'd and d.get("ok") is True and d.get("code") in ("recorded", "debounced") and d.get("employee_id") == "EMP-001" and (d.get("similarity") or 0) > 0'

step "3. Повтор того же request_id (обрыв связи у терминала)"
call POST timetrack/clock -H @"$HDR_DIR/device" \
	-F "device_id=kiosk-1" -F "request_id=$REQ" -F "image=@face-emp001.png"
show 6
expect "повтор не создаёт второе событие" 'd and d.get("ok") is True and d.get("code") in ("duplicate_request", "debounced")'

step "4. Незнакомое лицо"
call POST timetrack/clock -H @"$HDR_DIR/device" -F "device_id=kiosk-1" -F "image=@face-stranger.png"
show 8
expect "незнакомое лицо отклонено" 's == 404 and d and d.get("code") == "unknown_face"'

step "5. Неверный токен терминала"
call POST timetrack/clock -H "X-Api-Token: wrong-token-0000000000000000" -F "image=@face-emp001.png"
expect "неверный токен отклонён" 's == 401'

step "6. Отчёт summary (HR)"
call GET "timetrack/reports?type=summary&format=json" -H @"$HDR_DIR/hr"
show 12
expect "сводный отчёт получен" 's == 200 and d and d.get("ok") is True and isinstance(d.get("data"), list)'

step "7. Мои записи (сотрудник)"
call GET timetrack/me/records -H @"$HDR_DIR/employee"
show 12
expect "сотрудник видит свои записи" 's == 200 and d and (d.get("employee") or {}).get("employee_id") == "EMP-001"'

step "8. Запрос корректировки (сотрудник)"
call POST timetrack/me/corrections -H @"$HDR_DIR/employee" -H 'Content-Type: application/json' \
	-d "{\"action\":\"add\",\"requested_type\":\"check_out\",\"requested_time\":\"$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)\",\"reason\":\"Забыл отметиться на выходе\"}"
show 10
expect "заявка создана" 's == 201 and d and d.get("ok") is True and d.get("code") == "created"'

step "9. Очередь корректировок (HR)"
call GET "timetrack/hr/corrections?status=pending" -H @"$HDR_DIR/hr"
show 8
expect "кадровик видит очередь" 's == 200 and isinstance(d, list) and len(d) > 0'

step "10. Отчёт CSV (HR)"
call GET "timetrack/reports?type=standard&format=csv" -H @"$HDR_DIR/hr"
cp "$BODY" e2e-report.csv
echo "сохранено: $(wc -l < e2e-report.csv) строк"
head -2 e2e-report.csv
expect "табель в CSV с заголовком и строками" 's == 200 and "employee_id" in raw.splitlines()[0] and len(raw.splitlines()) > 1'

step "11. Снимки лиц не остались ни на диске, ни в памяти"
# Возврат в каталог скриптов: выше мы работали из каталога данных стенда.
if (cd "$REPO_STAND" && ./check-no-images.sh --wait); then
	echo "  ✓ снимков нет"
else
	echo "  ✗ снимки остались"
	FAILS=$((FAILS + 1))
fi

echo
if [ "$FAILS" -eq 0 ]; then
	echo "Итог: все проверки прошли"
else
	echo "Итог: не прошло проверок — $FAILS" >&2
	exit 1
fi
