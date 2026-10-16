#!/usr/bin/env python3
"""Считает значки в строке меню macOS, чтобы проверить наличие своего.

Зачем. Сравнение снимков строки меню здесь не работает: полоса полупрозрачная,
фон под ней меняется, и два кадра с ничего не изменившимся экраном расходятся
на десятки тысяч пикселей. Кроме того, появление значка сдвигает соседние
элементы вправо, так что фиксированная координата тоже не годится — на месте
нового значка оказывается чужой.

Что устойчиво. Значки — тёмная графика поверх светлой полосы, полупрозрачность
подложки их не затрагивает. При появлении своего значка их становится ровно на
один больше. Поэтому считаются связные участки тёмных колонок в статусной
области и сравнивается их количество, а не положение.

Проверено на этой машине:

    снимок без EyeLeo:  18 значков, самый левый 1031..1045
    снимок с EyeLeo:    19 значков, самый левый  991..1010

Использование::

    # снимок строки: точки, поэтому -R, и на выходе получается 2940x44
    screencapture -x -R0,0,1470,22 /tmp/бар.png
    python3 tools/menubar-icon-count.py /tmp/бар.png

Полоса на этой macOS уснувает через две минуты (``pmset``: displaysleep 2), а
``screencapture`` на уснувшем дисплее отдаёт чёрный кадр. Такой кадр не
интерпретируется, а отвергается: без этой проверки чёрный кадр выглядел бы как
полоса без значков, а это ложный вывод.
"""

import struct
import sys
import zlib
import pathlib

DARK = 120           # порог яркости, ниже которого пиксель считается тёмным
AREA = (900, 1470)   # точки: статусная область, без меню активного приложения
MIN_RUN = 6          # колонок; короче — не значок, а артефакт сжатия


def decode(path):
    """Распаковывает PNG построчно. Своя реализация, потому что sips нужен."""
    d = pathlib.Path(path).read_bytes()
    if d[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: это не PNG")

    pos, idat, w, h, ct = 8, b"", 0, 0, 0
    while pos < len(d):
        ln = struct.unpack(">I", d[pos : pos + 4])[0]
        kind = d[pos + 4 : pos + 8]
        chunk = d[pos + 8 : pos + 8 + ln]
        if kind == b"IHDR":
            w, h, _, ct = struct.unpack(">IIBB", chunk[:10])
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + ln

    if ct not in (2, 6):
        raise SystemExit(f"{path}: неожиданный тип цвета PNG {ct}")
    ch = 3 if ct == 2 else 4

    raw = zlib.decompress(idat)
    stride = w * ch
    prev = bytearray(stride)
    dark = [0] * w
    lum_sum = 0
    i = 0
    for _ in range(h):
        ft = raw[i]
        i += 1
        line = bytearray(raw[i : i + stride])
        i += stride
        if ft == 1:
            for x in range(ch, stride):
                line[x] = (line[x] + line[x - ch]) & 255
        elif ft == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif ft == 3:
            for x in range(stride):
                a = line[x - ch] if x >= ch else 0
                line[x] = (line[x] + (a + prev[x]) // 2) & 255
        elif ft == 4:
            for x in range(stride):
                a = line[x - ch] if x >= ch else 0
                b = prev[x]
                c = prev[x - ch] if x >= ch else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        for x in range(w):
            o = x * ch
            lum = (line[o] * 299 + line[o + 1] * 587 + line[o + 2]) // 1000
            if lum < DARK:
                dark[x] += 1
            lum_sum += lum
        prev = line

    return w, dark, lum_sum // max(1, len(dark))


def analyse(path):
    w, dark, mean = decode(path)
    if mean < 120:
        return mean, None

    lo, hi = AREA[0] * 2, min(AREA[1] * 2, w)
    runs, start = [], None
    for x in range(lo, hi):
        if dark[x] > 0 and start is None:
            start = x
        elif dark[x] == 0 and start is not None:
            if x - start >= MIN_RUN:
                runs.append((start // 2, x // 2))
            start = None
    if start is not None and hi - start >= MIN_RUN:
        runs.append((start // 2, hi // 2))
    return mean, runs


def main(argv):
    if len(argv) < 2:
        print(__doc__.split("Использование::")[-1].split("Полоса")[0].strip())
        return 1

    print(f"зона поиска: {AREA[0]}..{AREA[1]} точек")
    for path in argv[1:]:
        mean, runs = analyse(path)
        if runs is None:
            print(f"  {path:28s} яркость {mean:4d}  КАДР ПОГАС — ответ недействителен")
            continue
        first = f"{runs[0][0]}..{runs[0][1]}" if runs else "-"
        print(f"  {path:28s} яркость {mean:4d}  значков: {len(runs):2d}  самый левый: {first}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))