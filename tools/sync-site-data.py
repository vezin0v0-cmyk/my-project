"""Копирует список настроек Nova в конструктор на сайте (docs/app.html).

Запуск:
    python tools/sync-site-data.py          # обновить данные на сайте
    python tools/sync-site-data.py --check  # только проверить, что сайт не отстал (для CI)

Источник правды — src/tweaks.json и config.json. Сайт берёт из них названия,
описания и значения по умолчанию, чтобы конструктор всегда совпадал с программой.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGE = ROOT / "docs" / "app.html"
PATTERN = re.compile(r"/\*DATA-START\*/.*?/\*DATA-END\*/", re.S)


def build_data() -> str:
    tweaks = json.loads((ROOT / "src" / "tweaks.json").read_text(encoding="utf-8"))["tweaks"]
    config = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
    data = {
        "tweaks": [
            {key: tweak.get(key) for key in ("id", "category", "title", "description")}
            for tweak in tweaks
        ],
        "config": config,
    }
    blob = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    # "</" внутри <script> мог бы закрыть тег раньше времени.
    return blob.replace("</", "<\\/")


def main() -> int:
    page = PAGE.read_text(encoding="utf-8")
    if not PATTERN.search(page):
        print(f"Не нашёл метки DATA-START/DATA-END в {PAGE}")
        return 2
    updated = PATTERN.sub(lambda _: "/*DATA-START*/" + build_data() + "/*DATA-END*/", page, count=1)
    if "--check" in sys.argv:
        if updated != page:
            print("docs/app.html отстал от src/tweaks.json или config.json. Запусти: python tools/sync-site-data.py")
            return 1
        print("Данные сайта совпадают с программой.")
        return 0
    if updated != page:
        PAGE.write_text(updated, encoding="utf-8", newline="\n")
        print("docs/app.html обновлён.")
    else:
        print("Уже актуально.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
