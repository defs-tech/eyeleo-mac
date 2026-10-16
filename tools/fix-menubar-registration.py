#!/usr/bin/env python3
"""Снимает ложную привязку значка EyeLeo к чужому адресу в базе ControlCenter.

Что происходит
--------------
В macOS 26 элемент строки меню регистрируется за тем, кто владеет запуском.
Приложение, запущенное напрямую бинарником из терминала, считается
принадлежащим терминалу: его идентификатор попадает в список значков хозяина,
а право показывать значок берётся у хозяина, а не у приложения. Если у хозяина
в «Разрешить в строке меню» всё выключено, значок не появляется, хотя
собственная запись приложения содержит ``isAllowed: True`` и окно рисуется верно.

Ущерб не ограничивается одним запуском: он переживает выход, перезагрузку и
перезапуск ControlCenter. Он также возвращается после переустановки бандла —
новая подпись даёт новый cdhash, система регистрирует экземпляр заново.

Где лежит
---------
``~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/
group.com.apple.controlcenter.plist``, ключ ``trackedApplications``. Список
хранится не как обычный массив, а как вложенный бинарный plist внутри поля
``<data>``. Файл закрыт TCC: ``sudo`` его не открывает, нужен «Полный доступ к
диску» для терминала, который его читает.

Что делает
----------
Убирает из ``menuItemLocations`` записей ЧУЖИХ хозяев все идентификаторы
``local.eyeleo.*``. Собственные записи EyeLeo не трогает, флаги ``isAllowed`` ни
у кого не меняет, настройки чужих приложений не восстанавливает. Способ упаковки
данных сохраняется. Перед записью делается резервная копия.

Запуск
------
::

    python3 tools/fix-menubar-registration.py            # показать, что изменится
    killall ControlCenter && python3 tools/fix-menubar-registration.py --apply \
        && killall cfprefsd

Порядок применения обязателен: работающий ControlCenter перезапишет файл при
выходе, а ``cfprefsd`` вернёт прежнее значение из кэша.
"""

import base64
import json
import pathlib
import plistlib
import shutil
import sys
import time

TARGET = pathlib.Path(
    "~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/"
    "group.com.apple.controlcenter.plist"
).expanduser()

FAMILY = "local.eyeleo."


def decode_container(value):
    """Распаковывает вложенные данные. Возвращает (объект, способ упаковки)."""
    if isinstance(value, (bytes, bytearray)):
        raw = bytes(value)
        if raw[:8] == b"bplist00":
            try:
                return plistlib.loads(raw), "bplist"
            except Exception:
                return None, None
        try:
            decoded = base64.b64decode(b"".join(raw.split()), validate=True)
        except Exception:
            decoded = None
        if decoded and decoded[:8] == b"bplist00":
            try:
                return plistlib.loads(decoded), "base64-bplist"
            except Exception:
                return None, None
        text = raw.decode("utf-8", "replace").lstrip()
        if text[:1] in ("[", "{"):
            try:
                return json.loads(text), "json"
            except Exception:
                return None, None
        return None, None

    if isinstance(value, str):
        text = value.lstrip()
        if text[:1] in ("[", "{"):
            try:
                return json.loads(text), "json"
            except Exception:
                return None, None
        try:
            decoded = base64.b64decode("".join(text.split()), validate=True)
        except Exception:
            return None, None
        if decoded[:8] == b"bplist00":
            try:
                return plistlib.loads(decoded), "base64-bplist"
            except Exception:
                return None, None
        return None, None

    return None, None


def encode_container(value, kind):
    if kind == "bplist":
        return plistlib.dumps(value, fmt=plistlib.FMT_BINARY)
    if kind == "base64-bplist":
        return base64.b64encode(plistlib.dumps(value, fmt=plistlib.FMT_BINARY))
    if kind == "json":
        return json.dumps(value).encode("utf-8")
    return value


def owner_of(record):
    """Идентификатор хозяина записи."""
    loc = record.get("location")
    if not isinstance(loc, dict):
        return None
    if isinstance(loc.get("bundle"), dict):
        return loc["bundle"].get("_0")
    if isinstance(loc.get("adhocBinary"), dict):
        return loc["adhocBinary"].get("_0", {}).get("relative")
    return None


def item_id(item):
    """Идентификатор элемента в menuItemLocations."""
    if isinstance(item, dict) and isinstance(item.get("bundle"), dict):
        return item["bundle"].get("_0")
    if isinstance(item, dict) and isinstance(item.get("adhocBinary"), dict):
        return item["adhocBinary"].get("_0", {}).get("relative")
    return None


def scan(records):
    """Записи чужих хозяев, у которых в menuItemLocations есть наши идентификаторы."""
    plan = []
    for i, rec in enumerate(records):
        if not isinstance(rec, dict):
            continue
        owner = owner_of(rec)
        locations = rec.get("menuItemLocations")
        if not isinstance(locations, list):
            continue
        if isinstance(owner, str) and owner.startswith(FAMILY):
            continue  # собственные записи EyeLeo не трогаем
        remove = [item for item in locations
                  if isinstance(item_id(item), str) and item_id(item).startswith(FAMILY)]
        if remove:
            plan.append((i, owner, rec, locations, remove))
    return plan


def main():
    apply = "--apply" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    target = pathlib.Path(args[0]).expanduser() if args else TARGET

    if not target.exists():
        print("файл не найден:", target)
        return 1

    try:
        raw = target.read_bytes()
    except Exception as exc:
        print("НЕТ ДОСТУПА:", exc)
        print("Выдайте «Полный доступ к диску» этому Терминалу и откройте его заново.")
        return 1

    root = plistlib.loads(raw)
    print("файл:", target)
    print("размер:", target.stat().st_size, "байт")

    stored = root.get("trackedApplications")
    records, kind = decode_container(stored)
    if records is None and isinstance(stored, list):
        records, kind = stored, "plain"
    if not isinstance(records, list):
        print("не удалось распаковать trackedApplications:", type(stored).__name__)
        return 1

    print("упаковка trackedApplications:", kind)
    print("записей:", len(records))
    print()

    plan = scan(records)
    total = sum(len(entry[4]) for entry in plan)
    for i, owner, rec, locations, remove in plan:
        print(f"[{i}] хозяин: {owner}   isAllowed={rec.get('isAllowed')}")
        print("     убрать из menuItemLocations:", ", ".join(item_id(x) for x in remove))
        if apply:
            rec["menuItemLocations"] = [x for x in locations if x not in remove]

    print()
    print("всего снято привязок:", total)

    if not apply:
        if total == 0:
            print("\nНичего менять не нужно: привязок EyeLeo к чужим хозяевам нет.")
        else:
            print("\nПробный прогон. Для применения:")
            print("    killall ControlCenter && python3 tools/fix-menubar-registration.py --apply \\")
            print("        && killall cfprefsd")
        return 0

    if total == 0:
        print("\nнечего применять, файл не тронут")
        return 0

    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = target.with_suffix(f".plist.bak-{stamp}")
    shutil.copy2(target, backup)
    print("резервная копия:", backup)

    if kind != "plain":
        root["trackedApplications"] = encode_container(records, kind)

    try:
        target.write_bytes(plistlib.dumps(root, fmt=plistlib.FMT_BINARY))
    except Exception as exc:
        print("НЕ УДАЛОСЬ ЗАПИСАТЬ:", exc)
        print("резервная копия осталась на месте:", backup)
        return 1

    print("записано, размер:", target.stat().st_size, "байт")

    check_raw = plistlib.loads(target.read_bytes()).get("trackedApplications")
    check, _ = decode_container(check_raw)
    if check is None and isinstance(check_raw, list):
        check = check_raw
    left = []
    for rec in check or []:
        if not isinstance(rec, dict):
            continue
        owner = owner_of(rec)
        if isinstance(owner, str) and owner.startswith(FAMILY):
            continue
        for item in rec.get("menuItemLocations") or []:
            ident = item_id(item)
            if isinstance(ident, str) and ident.startswith(FAMILY):
                left.append((owner, ident))
    print("остаточных привязок:", len(left), left or "")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)