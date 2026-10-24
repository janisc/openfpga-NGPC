#!/usr/bin/env python3
"""Convert a picture into the Pocket's core author icon (Cores/<core>/icon.bin), and back.

The icon is 36 x 36 pixels, one 16-bit little-endian word per pixel, stored
rotated a quarter turn counter-clockwise. The first byte of each word is the
pixel's darkness, 0 (white) to 255 (black); the second byte is zero. The
Pocket's core list and boot screen and the openFPGA library website all show
it that way, so the drawing is what both show. (Analogue's packaging docs
describe the value as brightness in the upper byte; published cores' icons,
and what the device shows, follow the layout above.)

Usage:
  python scripts/make_icon.py encode <drawing.png> <icon.bin>   # drawing as it should look
  python scripts/make_icon.py decode <icon.bin> <preview.png>    # back to a picture

A drawing smaller than 36 x 36 is centred on a black canvas. Anything with
colour or transparency is flattened to grey on black first. Needs Pillow.

The core's icon, pkg/pocket/Cores/janisc.NGPC/icon.bin, was made with encode.
"""

import sys
from PIL import Image

SIZE = 36


def encode(src, dst):
    img = Image.open(src)
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        bg = Image.new("RGBA", img.size, (0, 0, 0, 255))
        img = Image.alpha_composite(bg, img)
    img = img.convert("L")
    if img.width > SIZE or img.height > SIZE:
        sys.exit(f"{src} is {img.width}x{img.height}; the icon is at most {SIZE}x{SIZE}")
    canvas = Image.new("L", (SIZE, SIZE), 0)
    canvas.paste(img, ((SIZE - img.width) // 2, (SIZE - img.height) // 2))
    stored = canvas.transpose(Image.Transpose.ROTATE_90)          # a quarter turn counter-clockwise
    data = bytearray()
    for v in stored.tobytes():
        data += bytes((255 - v, 0))                               # darkness: 255 is black
    with open(dst, "wb") as f:
        f.write(data)
    print(f"{dst}: {len(data)} bytes")


def decode(src, dst):
    with open(src, "rb") as f:
        data = f.read()
    if len(data) != SIZE * SIZE * 2:
        sys.exit(f"{src} is {len(data)} bytes, not {SIZE * SIZE * 2}")
    stored = Image.new("L", (SIZE, SIZE))
    stored.putdata([255 - data[2 * i] for i in range(SIZE * SIZE)])
    stored.transpose(Image.Transpose.ROTATE_270).save(dst)       # back a quarter turn clockwise
    print(f"{dst}: written")


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("encode", "decode"):
        sys.exit(__doc__)
    (encode if sys.argv[1] == "encode" else decode)(sys.argv[2], sys.argv[3])
