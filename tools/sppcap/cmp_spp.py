#!/usr/bin/env python3
"""Compare an engine output captured from SIGMA Photo Pro (BMP-framed 8-bit BGR, as the shim dumps
it) with one of our sppqd rgb8 renders of the same size, in the SAME orientation (no numpy).

  python3 cmp_spp.py <NNN_output.bin> <ours.rgb> [--transpose]

Prints the BMP geometry, per-channel mean |diff| / median |diff| / 99th percentile on a pixel grid,
and the five SDIM0433 patches (relative positions on the frame as stored) for both.
"""
import struct, sys

def bmp(path):
    d = open(path, 'rb').read()
    if d[:2] != b'BM':
        raise SystemExit(f"{path}: not BMP-framed (starts {d[:4]!r})")
    off = struct.unpack_from('<I', d, 10)[0]
    w, h, planes, bpp = struct.unpack_from('<iihH', d, 18)
    stride = (w * (bpp // 8) + 3) & ~3
    topdown = h < 0; h = abs(h)
    px = bytearray(w * h * 3)
    for y in range(h):
        src = off + (y if topdown else h - 1 - y) * stride
        row = d[src:src + w * (bpp // 8)]
        o = y * w * 3
        if bpp == 24:
            for x in range(w):
                px[o + 3 * x] = row[3 * x + 2]; px[o + 3 * x + 1] = row[3 * x + 1]; px[o + 3 * x + 2] = row[3 * x]
        elif bpp == 32:
            for x in range(w):
                px[o + 3 * x] = row[4 * x + 2]; px[o + 3 * x + 1] = row[4 * x + 1]; px[o + 3 * x + 2] = row[4 * x]
        else:
            raise SystemExit(f"bpp {bpp} unsupported")
    return w, h, bpp, off, bytes(px)

spp_path, our_path = sys.argv[1], sys.argv[2]
w, h, bpp, off, spp = bmp(spp_path)
print(f"SPP output: {w}x{h} {bpp} bpp, pixel data at {off}")
ours = open(our_path, 'rb').read()
if len(ours) != w * h * 3:
    raise SystemExit(f"ours: {len(ours)} bytes, expected {w*h*3} for {w}x{h} — render ours at that size")

diffs = [[], [], []]
step = max(1, (w * h) // 200000)
for i in range(0, w * h, step):
    for c in range(3):
        diffs[c].append(abs(spp[3 * i + c] - ours[3 * i + c]))
for c, name in enumerate("RGB"):
    d = sorted(diffs[c]); n = len(d)
    print(f"  {name}: mean |diff| {sum(d)/n:5.2f}  median {d[n//2]:3d}  p99 {d[int(n*0.99)]:3d}  max {d[-1]:3d}")

PATCHES = {'cheek': (0.60, 0.52), 'forehead': (0.52, 0.36), 'wall': (0.12, 0.40), 'jacket': (0.45, 0.90), 'hair': (0.80, 0.45)}
def sample(buf, fx, fy, r=4):
    # positions are given on the upright portrait frame; the buffers are as stored
    # (landscape, EXIF 8): upright (ux, uy) <- stored (sx, sy) = ((w-1) - uy*, ux*) scaled
    uw, uh = (h, w) if w > h else (w, h)
    ux, uy = int(fx * uw), int(fy * uh)
    vals = [[], [], []]
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            x, y = min(max(ux + dx, 0), uw - 1), min(max(uy + dy, 0), uh - 1)
            sx, sy = ((w - 1) - y, x) if w > h else (x, y)
            o = (sy * w + sx) * 3
            for c in range(3): vals[c].append(buf[o + c])
    return tuple(sorted(v)[len(v) // 2] for v in vals)
print(f"{'patch':9}{'SPP':>18}{'ours':>18}")
for name, (fx, fy) in PATCHES.items():
    print(f"{name:9}{str(sample(spp, fx, fy)):>18}{str(sample(ours, fx, fy)):>18}")
