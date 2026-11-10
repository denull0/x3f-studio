#!/usr/bin/env python3
"""Sample the SDIM0433 reference patches in 16-bit TIFF masters (sensor orientation, EXIF 8) and
optionally in raw rgb8 renders / upright JPEGs, printing 8-bit values. Needs numpy + tifffile + Pillow.

  python tiff_patches.py file.tif [more.tif ...] [--rgb WxH file.rgb ...] [--jpg upright.jpg ...]
"""
import sys
import numpy as np
import tifffile
from PIL import Image

PATCHES = {'cheek': (0.60, 0.52), 'forehead': (0.52, 0.36), 'wall': (0.12, 0.40), 'jacket': (0.45, 0.90), 'hair': (0.80, 0.45)}

def upright(a):
    """Sensor-orientation array (landscape) → upright portrait for EXIF orientation 8."""
    return np.rot90(a, 1) if a.shape[1] > a.shape[0] else a

def load(spec):
    kind, path = spec
    if kind == 'tif':
        a = tifffile.imread(path)
        if a.dtype == np.uint16: a = (a >> 8).astype(np.uint8)
        return upright(a[..., :3])
    if kind == 'rgb':
        w, h, p = path
        return upright(np.fromfile(p, dtype=np.uint8).reshape(h, w, 3))
    return np.asarray(Image.open(path).convert('RGB'))

def sample(img, fx, fy, r=6):
    h, w = img.shape[:2]
    x, y = int(fx * w), int(fy * h)
    blk = img[max(0, y - r):y + r + 1, max(0, x - r):x + r + 1].reshape(-1, 3)
    return tuple(int(v) for v in np.median(blk, axis=0))

specs, args, i = [], sys.argv[1:], 0
while i < len(args):
    if args[i] == '--rgb':
        w, h = (int(v) for v in args[i + 1].split('x')); specs.append(('rgb', (w, h, args[i + 2]))); i += 3
    elif args[i] == '--jpg':
        specs.append(('jpg', args[i + 1])); i += 2
    else:
        specs.append(('tif', args[i])); i += 1
imgs = [(str(s[1] if s[0] != 'rgb' else s[1][2]).split('/')[-1][:16], load(s)) for s in specs]
print(f"{'patch':9}" + "".join(f"{n:>18}" for n, _ in imgs))
for name, (fx, fy) in PATCHES.items():
    print(f"{name:9}" + "".join(f"{str(sample(im, fx, fy)):>18}" for _, im in imgs))
print("mean     " + "".join(f"{str(tuple(int(v) for v in im.reshape(-1, 3).mean(axis=0))):>18}" for _, im in imgs))
print("shape    " + "".join(f"{str(im.shape[:2]):>18}" for _, im in imgs))
