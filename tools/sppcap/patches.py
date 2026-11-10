#!/usr/bin/env python3
"""Sample the SDIM0433 reference patches (relative positions on the upright 4:3 frame) in raw
rgb8 renders from sppqd (sensor orientation, EXIF rotation 8 → shown rotated), no numpy needed.

  python3 patches.py <w>x<h> file.rgb [file2.rgb ...]
"""
import sys

PATCHES = {'cheek': (0.60, 0.52), 'forehead': (0.52, 0.36), 'wall': (0.12, 0.40), 'jacket': (0.45, 0.90), 'hair': (0.80, 0.45)}
CAMERA_JPEG = {'cheek': (172, 146, 117), 'forehead': (158, 143, 103), 'wall': (214, 225, 239), 'jacket': (13, 17, 16), 'hair': (82, 116, 28)}
SPP_SCREEN = {'cheek': (177, 151, 139), 'forehead': (152, 142, 118), 'wall': (204, 217, 239), 'jacket': (8, 19, 15), 'hair': (87, 118, 32)}

def sample(buf, w, h, fx, fy, r=6):
    """Upright pixel (ux, uy) ← stored (sx, sy) with sx = (w-1) - uy, sy = ux (orientation 8)."""
    uw, uh = h, w
    ux, uy = int(fx * uw), int(fy * uh)
    vals = [[], [], []]
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            x, y = min(max(ux + dx, 0), uw - 1), min(max(uy + dy, 0), uh - 1)
            sx, sy = (w - 1) - y, x
            o = (sy * w + sx) * 3
            for c in range(3): vals[c].append(buf[o + c])
    return tuple(sorted(v)[len(v) // 2] for v in vals)

w, h = (int(v) for v in sys.argv[1].split('x'))
files = sys.argv[2:]
bufs = [(p.split('/')[-1], open(p, 'rb').read()) for p in files]
for n, b in bufs:
    if len(b) != w * h * 3: raise SystemExit(f"{n}: {len(b)} bytes, expected {w*h*3}")
cols = [n[:14] for n, _ in bufs] + ['camera JPEG', 'SPP screen']
print(f"{'patch':9}" + "".join(f"{c:>17}" for c in cols))
for name, (fx, fy) in PATCHES.items():
    row = [sample(b, w, h, fx, fy) for _, b in bufs] + [CAMERA_JPEG[name], SPP_SCREEN[name]]
    print(f"{name:9}" + "".join(f"{str(v):>17}" for v in row))
