#!/usr/bin/env python3
"""Render assets/logo.svg to PNG at standard sizes.

Run from the repo root:
    python3 assets/render-png.py
"""
import os, sys
import cairosvg

HERE = os.path.dirname(os.path.abspath(__file__))
SVG  = os.path.join(HERE, "logo.svg")

SIZES = {
    "logo.png":      256,
    "logo-128.png":  128,
    "logo-512.png":  512,
}

def main() -> int:
    if not os.path.exists(SVG):
        print(f"missing: {SVG}", file=sys.stderr)
        return 1
    with open(SVG, "rb") as f:
        svg = f.read()
    for name, size in SIZES.items():
        out = os.path.join(HERE, name)
        cairosvg.svg2png(bytestring=svg, write_to=out,
                         output_width=size, output_height=size)
        print(f"wrote {out} ({size}x{size})")
    return 0

if __name__ == "__main__":
    sys.exit(main())
