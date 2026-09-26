#!/usr/bin/env bash
# Готовит стенд к прогону: схема базы, тестовые снимки, токены.
# Токены выпускает сама база (fn_issue_token), наружу они попадают только в
# файлы с правами 600 — значения не уходят ни в argv, ни в журналы.
set -euo pipefail
cd "$(dirname "$0")"
. ./env.sh

RESET=${1:-}

echo "== Схема"
if [ "$RESET" = "--reset" ]; then
	echo "  сброс схемы timetrack"
	psql "$TT_DB_URL" -X -q -c "DROP SCHEMA IF EXISTS timetrack CASCADE;" >/dev/null
fi
psql "$TT_DB_URL" -X -q -v ON_ERROR_STOP=1 -f "$PROJECT_ROOT/db/001_schema.sql"
psql "$TT_DB_URL" -X -q -v ON_ERROR_STOP=1 -f "$PROJECT_ROOT/db/003_calendar_absences.sql"
echo "  функций в схеме: $(psql "$TT_DB_URL" -X -t -A -c "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'timetrack'")"

echo "== Тестовые снимки"
# Заглушка распознавания сравнивает снимки по sha256, поэтому годятся любые два
# разных PNG: один «свой», второй «незнакомец».
python3 - "$STAND_HOME" <<'PY'
import struct, sys, zlib
from pathlib import Path

def png(path, rgb):
    w = h = 64
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))
    def chunk(tag, data):
        c = tag + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c))
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
                     + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
png(out / 'face-emp001.png', (40, 120, 200))
png(out / 'face-stranger.png', (200, 90, 40))
print('  записано: face-emp001.png, face-stranger.png')
PY

echo "== Токены"
# Выпуск вынесен в tokens.sh, чтобы правило «значение токена только в файл с
# правами 600» жило в одном месте.
./tokens.sh hr     'HR portal' >/dev/null && echo "  tok.hr (hr)"
./tokens.sh device 'Kiosk 1' 'Проходная' >/dev/null && echo "  tok.device (device)"
./tokens.sh system 'Scheduler' >/dev/null && echo "  tok.system (system)"

echo
echo "Токен сотрудника выпускается после регистрации — запустите ./tokens.sh employee EMP-001"
echo "Дальше: ./e2e.sh"
