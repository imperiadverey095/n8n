#!/usr/bin/env bash
# Проверяет обещание «снимки лиц не попадают на постоянный носитель» на деле.
#
#   ./check-no-images.sh          — моментальный снимок состояния
#   ./check-no-images.sh --wait   — дополнительно ждёт очистку n8n и требует,
#                                   чтобы снимки исчезли и из памяти
#
# Падает (код 1), если:
#   * в постоянном хранилище n8n нашлось хоть одно изображение;
#   * хранилище бинарных данных n8n лежит не в tmpfs — тогда снимки пишутся на диск;
#   * с --wait: снимки не исчезли из tmpfs за отведённое время.
#
# Тип определяется по сигнатуре, а не по расширению: n8n хранит бинарные данные
# без расширения, а имя исходного файла кладёт в соседний .metadata.
set -uo pipefail
cd "$(dirname "$0")"
. ./env.sh || exit 1

WAIT=0
[ "${1:-}" = "--wait" ] && WAIT=1

PERSISTENT="$N8N_USER_FOLDER/.n8n/storage"
BINARY="${N8N_BINARY_DATA_STORAGE_PATH:-$PERSISTENT}"
# Сколько ждать очистку: интервал очистки плюс запас на сам проход.
WAIT_SECONDS=$(( (${EXECUTIONS_DATA_PRUNE_HARD_DELETE_INTERVAL:-15} + 1) * 60 ))

python3 - "$PERSISTENT" "$BINARY" "$WAIT" "$WAIT_SECONDS" <<'PY'
import os
import sys
import time

persistent, binary, wait, wait_seconds = sys.argv[1], sys.argv[2], sys.argv[3] == "1", int(sys.argv[4])

SIGNATURES = {
    b"\x89PNG\r\n\x1a\n": "PNG",
    b"\xff\xd8\xff": "JPEG",
    b"GIF87a": "GIF",
    b"GIF89a": "GIF",
    b"BM": "BMP",
}


def kind(path):
    try:
        with open(path, "rb") as fh:
            head = fh.read(16)
    except OSError:
        return None
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "WebP"
    if head[4:12] in (b"ftypheic", b"ftypheix", b"ftypmif1"):
        return "HEIC"
    for sig, name in SIGNATURES.items():
        if head.startswith(sig):
            return name
    return None


def images_under(root):
    found = []
    if not os.path.isdir(root):
        return found
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if name.endswith(".metadata"):
                continue
            path = os.path.join(dirpath, name)
            k = kind(path)
            if k:
                found.append((k, os.path.relpath(path, root)))
    return found


def fstype(path):
    """Тип файловой системы, на которой лежит path (по самой длинной точке монтирования)."""
    path = os.path.realpath(path if os.path.exists(path) else os.path.dirname(path))
    best, best_type = "", "?"
    with open("/proc/mounts") as fh:
        for line in fh:
            _dev, mnt, typ = line.split()[:3]
            if (path == mnt or path.startswith(mnt.rstrip("/") + "/")) and len(mnt) > len(best):
                best, best_type = mnt, typ
    return best_type


def show(items, limit=10):
    for k, rel in items[:limit]:
        print(f"    {k}: {rel}")
    if len(items) > limit:
        print(f"    … и ещё {len(items) - limit}")


failed = False
print("== Снимки лиц и n8n")

on_disk = images_under(persistent)
if on_disk:
    failed = True
    print(f"  НАРУШЕНО: в постоянном хранилище {len(on_disk)} изображений ({persistent})")
    show(on_disk)
else:
    print("  постоянное хранилище: изображений нет")

bin_fs = fstype(binary)
if bin_fs != "tmpfs":
    failed = True
    print(f"  НАРУШЕНО: хранилище бинарных данных на «{bin_fs}», а не в tmpfs — снимки пишутся на диск")
    print(f"    путь: {binary}")
else:
    transient = images_under(binary)
    print(f"  хранилище бинарных данных в памяти (tmpfs), сейчас изображений: {len(transient)}")
    if wait and transient:
        print(f"  жду очистку n8n, до {wait_seconds} с…")
        deadline = time.time() + wait_seconds
        while transient and time.time() < deadline:
            time.sleep(10)
            transient = images_under(binary)
        if transient:
            failed = True
            print(f"  НАРУШЕНО: за {wait_seconds} с в памяти осталось {len(transient)} изображений")
            show(transient)
        else:
            print("  после очистки изображений в памяти нет")

sys.exit(1 if failed else 0)
PY
