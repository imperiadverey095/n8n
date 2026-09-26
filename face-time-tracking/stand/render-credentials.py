#!/usr/bin/env python3
"""Подставляет значения из окружения в шаблон учётных данных n8n.

Заменяет envsubst: пакет gettext-base стоит не на всех системах, а python3
скриптам стенда нужен и так. Если в окружении не хватает переменной —
завершается с ошибкой, а не пишет пустое значение: пустой пароль SMTP уже
однажды привёл к тому, что письма молча не уходили.
"""

import json
import os
import re
import sys

PLACEHOLDER = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")


def main() -> int:
    if len(sys.argv) != 3:
        sys.exit(f"использование: {sys.argv[0]} <шаблон> <файл-результат>")
    template_path, out_path = sys.argv[1], sys.argv[2]

    with open(template_path, encoding="utf-8") as fh:
        template = fh.read()

    missing = []

    def replace(match: "re.Match[str]") -> str:
        name = match.group(1)
        value = os.environ.get(name)
        if value is None:
            missing.append(name)
            return ""
        return value

    rendered = PLACEHOLDER.sub(replace, template)
    if missing:
        sys.exit("нет переменных окружения: " + ", ".join(sorted(set(missing))))

    # Ошибку в шаблоне лучше поймать здесь, чем получить невнятный отказ импорта.
    try:
        json.loads(rendered)
    except json.JSONDecodeError as err:
        sys.exit(f"результат не разбирается как JSON: {err}")

    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
