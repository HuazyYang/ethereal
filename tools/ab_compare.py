#!/usr/bin/env python3
# Copyright (c) 2026, ethereal contributors. All rights reserved.
# SPDX-License-Identifier: MIT
"""Compare two screenshots pixel by pixel (render graph plan, step P2.0).

    python tools/ab_compare.py A.png B.png [--tolerance N] [--diff diff.png] [--alpha]

Reports whether the images are identical and, if not, how many pixels differ, the largest channel
difference, and the bounding box of the differences. With --diff, writes an image that is black where
the pixels match and shows the absolute difference, amplified, where they do not.

Exit codes: 0 when every channel differs by at most --tolerance (default 0, identical), 1 when the
images differ beyond it, 2 when they cannot be compared (missing file, other size).
Alpha is ignored unless --alpha is given: the samples' back buffers carry no meaningful alpha.
"""

import argparse
import sys

try:
    from PIL import Image, ImageChops
except ImportError:  # pragma: no cover
    sys.stderr.write("ab_compare.py needs Pillow (pip install pillow)\n")
    sys.exit(2)


def load(path, alpha):
    try:
        image = Image.open(path)
        image.load()
    except OSError as error:
        sys.stderr.write(f"cannot read {path}: {error}\n")
        sys.exit(2)
    return image.convert("RGBA" if alpha else "RGB")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("a")
    parser.add_argument("b")
    parser.add_argument("--tolerance", type=int, default=0, help="largest channel difference still counted as equal")
    parser.add_argument("--diff", help="write a difference image here")
    parser.add_argument("--alpha", action="store_true", help="compare the alpha channel too")
    args = parser.parse_args()

    a = load(args.a, args.alpha)
    b = load(args.b, args.alpha)
    if a.size != b.size:
        print(f"different sizes: {args.a} is {a.size[0]}x{a.size[1]}, {args.b} is {b.size[0]}x{b.size[1]}")
        return 2

    diff = ImageChops.difference(a, b)
    width, height = a.size
    channels = len(diff.getbands())
    data = diff.tobytes()
    largest = max(data) if data else 0
    differing = 0
    beyond = 0
    box = None
    for index in range(width * height):
        pixel = data[index * channels:(index + 1) * channels]
        worst = max(pixel)
        if worst == 0:
            continue
        differing += 1
        if worst > args.tolerance:
            beyond += 1
        x, y = index % width, index // width
        box = (x, y, x, y) if box is None else (min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y))

    if args.diff:
        scale = 255 // max(largest, 1)
        diff.point(lambda value: min(255, value * scale)).convert("RGB").save(args.diff)

    total = width * height
    if differing == 0:
        print(f"identical: {width}x{height}")
        return 0
    print(f"differ: {differing} of {total} pixels ({100.0 * differing / total:.4f} %), largest channel difference "
          f"{largest}, {beyond} beyond tolerance {args.tolerance}, box ({box[0]}, {box[1]})-({box[2]}, {box[3]})")
    return 1 if beyond else 0


if __name__ == "__main__":
    sys.exit(main())
