#!/usr/bin/env python3
"""Подставляет значения из окружения в шаблон учётных данных n8n.

Подстановка идёт по структуре, а не по тексту: шаблон разбирается как JSON,
значения вставляются в уже разобранные строки, результат сериализуется заново.
Поэтому кавычка, обратная косая или «", "ключ": "…» в пароле не ломают файл и
не подмешивают в него ключи — при текстовой подстановке было и то и другое.

Плейсхолдеры:
  "${NAME}"      — строка из переменной NAME (может стоять внутри строки:
                   "Bearer ${HR_API_TOKEN}");
  "${NAME:int}"  — вся строка заменяется целым числом из NAME (порты).

Если переменной нет или число не число — завершается с ошибкой, а не пишет
пустое значение: пустой пароль SMTP уже однажды привёл к тому, что письма
молча не уходили.
"""

import json
import os
import re
import sys

PLACEHOLDER = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")
INT_PLACEHOLDER = re.compile(r"^\$\{([A-Z_][A-Z0-9_]*):int\}$")


class RenderError(Exception):
    pass


def env(name):
    value = os.environ.get(name)
    if value is None:
        raise RenderError(f"нет переменной окружения {name}")
    return value


def render_string(text):
    whole_int = INT_PLACEHOLDER.match(text)
    if whole_int:
        name = whole_int.group(1)
        raw = env(name)
        if not re.fullmatch(r"\d+", raw):
            raise RenderError(f"{name} должно быть целым числом, а не {raw!r}")
        return int(raw)
    return PLACEHOLDER.sub(lambda m: env(m.group(1)), text)


def render(node):
    if isinstance(node, dict):
        return {key: render(value) for key, value in node.items()}
    if isinstance(node, list):
        return [render(item) for item in node]
    if isinstance(node, str):
        return render_string(node)
    return node


def main() -> int:
    if len(sys.argv) != 3:
        sys.exit(f"использование: {sys.argv[0]} <шаблон> <файл-результат>")
    template_path, out_path = sys.argv[1], sys.argv[2]

    with open(template_path, encoding="utf-8") as fh:
        try:
            template = json.load(fh)
        except json.JSONDecodeError as err:
            sys.exit(f"шаблон не разбирается как JSON: {err}")

    try:
        rendered = render(template)
    except RenderError as err:
        sys.exit(str(err))

    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(rendered, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
