#!/usr/bin/env python3
"""For each render of the SDIM0431 window region (1000x1000 sensor pixels, trim 1908,1490,2907,2489):
save an upright 3x crop and count isolated specks (pixels that differ from their 3x3 median by more
than a threshold), the signature of the engine's edge dots.

  venv/bin/python dots_report.py <dir> name.tif|name.rgb ...   (rgb = 1000x1000x3 8-bit)
"""
import sys, os
import numpy as np
from PIL import Image

def load(path):
    if path.endswith('.tif'):
        import tifffile
        a = tifffile.imread(path)
        if a.dtype == np.uint16: a = (a >> 8).astype(np.uint8)
        return a[..., :3]
    a = np.fromfile(path, dtype=np.uint8)
    n = int(round((a.size / 3) ** 0.5))
    return a.reshape(n, n, 3)

def specks(img, thr=40):
    g = img.astype(int)
    # 3x3 median per channel via sorting the 9 shifted copies
    pads = np.pad(g, ((1, 1), (1, 1), (0, 0)), mode='edge')
    stack = np.stack([pads[dy:dy + g.shape[0], dx:dx + g.shape[1]] for dy in range(3) for dx in range(3)], axis=0)
    med = np.median(stack, axis=0)
    d = np.abs(g - med).max(axis=2)
    return int((d > thr).sum()), float(d.mean())

d = sys.argv[1]
for name in sys.argv[2:]:
    p = os.path.join(d, name)
    if not os.path.exists(p): print(f"{name:14s} missing"); continue
    img = load(p)
    up = np.rot90(img, 1)
    base = name.rsplit('.', 1)[0]
    Image.fromarray(up[300:600, 250:550]).resize((900, 900), Image.NEAREST).save(os.path.join(d, base + '_3x.png'))
    n, m = specks(up)
    print(f"{name:14s} shape {img.shape}  specks(>40) {n:6d}   mean |px - median3x3| {m:.2f}")
