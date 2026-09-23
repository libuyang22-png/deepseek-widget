#!/usr/bin/env bash
# 给已生成的工程补上小米要求的小部件预览图
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

mkdir -p app/src/main/res/drawable-nodpi

python3 - <<'PY'
import struct, zlib

W, H = 300, 150
OUT    = (0x12, 0x16, 0x1E)
BODY   = (0x1A, 0x1F, 0x2A)
BORDER = (0x3A, 0x42, 0x52)
BAR1   = (0xB9, 0xC2, 0xD0)
BAR2   = (0xE8, 0xEC, 0xF3)
BAR3   = (0x8B, 0x95, 0xA7)
DOT    = (0x3D, 0xDC, 0x97)


def inside_round(x, y, x0, y0, x1, y1, r):
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    if x < x0 + r and y < y0 + r:
        return (x - x0 - r) ** 2 + (y - y0 - r) ** 2 <= r * r
    if x > x1 - r and y < y0 + r:
        return (x - x1 + r) ** 2 + (y - y0 - r) ** 2 <= r * r
    if x < x0 + r and y > y1 - r:
        return (x - x0 - r) ** 2 + (y - y1 + r) ** 2 <= r * r
    if x > x1 - r and y > y1 - r:
        return (x - x1 + r) ** 2 + (y - y1 + r) ** 2 <= r * r
    return True


def inside_rect(x, y, x0, y0, x1, y1):
    return x0 <= x <= x1 and y0 <= y <= y1


bars = [
    (42, 24, 138, 33, BAR1),
    (24, 50, 176, 80, BAR2),
    (24, 90, 210, 100, BAR3),
    (24, 108, 168, 118, BAR3),
]

rows = []
for y in range(H):
    row = bytearray()
    for x in range(W):
        if not inside_round(x, y, 4, 4, W - 5, H - 5, 20):
            c = OUT
        elif not inside_round(x, y, 5, 5, W - 6, H - 6, 19):
            c = BORDER
        else:
            c = BODY
            for x0, y0, x1, y1, color in bars:
                if inside_rect(x, y, x0, y0, x1, y1):
                    c = color
                    break
            if (x - 30) ** 2 + (y - 29) ** 2 <= 22:
                c = DOT
        row += bytes((c[0], c[1], c[2], 255))
    rows.append(row)

raw = b"".join(b"\x00" + bytes(r) for r in rows)


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data +
            struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))

path = "app/src/main/res/drawable-nodpi/widget_preview.png"
with open(path, "wb") as f:
    f.write(png)
print("preview written:", path, len(png), "bytes")
PY

# 让 widget_info.xml 引用这张预览图（小米没有它就藏起小部件）
cat > app/src/main/res/xml/widget_info.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:description="@string/widget_description"
    android:initialLayout="@layout/widget_balance"
    android:minHeight="100dp"
    android:minWidth="180dp"
    android:previewImage="@drawable/widget_preview"
    android:previewLayout="@layout/widget_balance"
    android:resizeMode="horizontal|vertical"
    android:targetCellHeight="2"
    android:targetCellWidth="3"
    android:updatePeriodMillis="0"
    android:widgetCategory="home_screen" />
EOF

echo "小部件预览图已补上"
