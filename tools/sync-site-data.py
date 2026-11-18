"""Копирует список настроек Nova в конструктор на сайте (docs/app.html).

Запуск:
    python tools/sync-site-data.py          # обновить данные на сайте
    python tools/sync-site-data.py --check  # только проверить, что сайт не отстал (для CI)

Источник правды — src/tweaks.json, config.json, voice.json и версия в src/Nova.psm1. Сайт берёт
из них названия, описания и значения по умолчанию, чтобы конструктор всегда совпадал
с программой, а на главной — число настроек и приложений и номер версии.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGES = [ROOT / "docs" / "app.html", ROOT / "docs" / "mockup.html"]
PATTERN = re.compile(r"/\*DATA-START\*/.*?/\*DATA-END\*/", re.S)


def nova_version() -> str:
    text = (ROOT / "src" / "Nova.psm1").read_text(encoding="utf-8-sig")
    found = re.search(r"\$script:NovaVersion = '(\d+\.\d+\.\d+)'", text)
    if not found:
        raise SystemExit("Не нашёл $script:NovaVersion в src/Nova.psm1")
    return found.group(1)


def numbers() -> list:
    """Числа и версия на главной и в макете: (страница, шаблон, на что заменить)."""
    tweaks = json.loads((ROOT / "src" / "tweaks.json").read_text(encoding="utf-8"))["tweaks"]
    config = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
    per_cat = {}
    for tweak in tweaks:
        per_cat[tweak["category"]] = per_cat.get(tweak["category"], 0) + 1

    def settings(n: int) -> str:
        if n % 100 in (11, 12, 13, 14):
            return f"{n} настроек"
        return f"{n} " + {1: "настройка", 2: "настройки", 3: "настройки", 4: "настройки"}.get(n % 10, "настроек")

    full = nova_version()
    short = ".".join(full.split(".")[:2])
    index = ROOT / "docs" / "index.html"
    return [
        (index, r'(<b id="stat-tweaks">)\d+(</b>)', rf"\g<1>{len(tweaks)}\g<2>"),
        (index, r'(<b id="stat-apps">)\d+(</b>)', rf"\g<1>{len(config['removeApps'])}\g<2>"),
        (index, r'(<span id="cnt-apps">)\d+( в списке</span>)', rf"\g<1>{len(config['removeApps'])}\g<2>"),
        *[(index, rf'(<span id="cnt-{cat}">)[^<]*(</span>)', rf"\g<1>{settings(per_cat.get(cat, 0))}\g<2>")
          for cat in ("privacy", "interface", "performance")],
        (index, r'(<small id="site-version">v)[\d.]+(</small>)', rf"\g<1>{short}\g<2>"),
        (index, r"(  Nova )\d+\.\d+\.\d+( — твоя Windows)", rf"\g<1>{full}\g<2>"),
        (ROOT / "docs" / "mockup.html", r"(Nova )\d+\.\d+\.\d+( · у тебя последняя версия)", rf"\g<1>{full}\g<2>"),
    ]


def build_data() -> str:
    tweaks_doc = json.loads((ROOT / "src" / "tweaks.json").read_text(encoding="utf-8"))
    tweaks = tweaks_doc["tweaks"]
    config = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
    voice = json.loads((ROOT / "voice.json").read_text(encoding="utf-8"))
    data = {
        "presets": [
            {key: preset.get(key) for key in ("id", "name", "text", "tweaksOn", "removeApps", "keepApps", "installApps")}
            for preset in tweaks_doc.get("presets", [])
        ],
        "tweaks": [
            {key: tweak.get(key) for key in ("id", "category", "title", "description")}
            for tweak in tweaks
        ],
        "config": config,
        "voice": voice,
    }
    blob = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    # «<» внутри <script> мог бы закрыть тег («</script>») или переключить разбор («<!--»): пишем его как \u003c.
    return blob.replace("<", "\\u003c")


def main() -> int:
    # Консоль Windows по умолчанию не в UTF-8 — без этого русские сообщения роняют скрипт.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    data = build_data()
    check = "--check" in sys.argv
    stale = []
    pages = {path: path.read_text(encoding="utf-8") for path in PAGES}
    updated = dict(pages)
    for path in PAGES:
        if not PATTERN.search(updated[path]):
            print(f"Не нашёл метки DATA-START/DATA-END в {path.relative_to(ROOT).as_posix()}")
            return 2
        updated[path] = PATTERN.sub(lambda _: "/*DATA-START*/" + data + "/*DATA-END*/", updated[path], count=1)
    for path, pattern, value in numbers():
        if path not in updated:
            pages[path] = updated[path] = path.read_text(encoding="utf-8")
        new, count = re.subn(pattern, value, updated[path], count=1)
        if count != 1:
            print(f"Не нашёл в {path.relative_to(ROOT).as_posix()}: {pattern}")
            return 2
        updated[path] = new
    for path, page in updated.items():
        if page == pages[path]:
            continue
        name = path.relative_to(ROOT).as_posix()
        stale.append(name)
        if not check:
            path.write_text(page, encoding="utf-8", newline="\n")
            print(f"{name} обновлён.")
    if check:
        if stale:
            print("Отстали от src/tweaks.json, config.json, voice.json или версии Nova: " + ", ".join(stale) + ". Запусти: python tools/sync-site-data.py")
            return 1
        print("Данные сайта совпадают с программой.")
        return 0
    if not stale:
        print("Уже актуально.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
