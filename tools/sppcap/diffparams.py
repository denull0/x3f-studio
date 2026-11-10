#!/usr/bin/env python3
"""Field-by-field diff of two 1008-byte tagAdjustmentParameters blocks.

  python3 diffparams.py spp_params.bin ours_params.bin

Prints every differing 2-byte cell with u16 / i32 / float / srational readings, grouped into
runs, plus the known field names from sppq.c so the interesting ones stand out.
"""
import struct, sys

NAMES = {0: "NUMFIELDS", 4: "FP0", 8: "FP1", 12: "FP2", 16: "FP3", 20: "FP4", 24: "FP5", 28: "WIDTH", 30: "HEIGHT", 32: "ROTATE", 34: "SENSOR",
         40: "PROCVER", 48: "CAMF*", 56: "ISO", 60: "FLEN", 68: "FNUM", 76: "SHUTTER", 84: "OBJDIST", 92: "EXPCAM", 100: "FLASH", 104: "LENSPROF*",
         112: "PROCMODE", 116: "EXP", 124: "CON", 132: "SHA", 140: "HIL", 148: "SAT", 156: "SHP", 164: "FILL", 172: "MEXP", 180: "MCON", 188: "MSHA",
         196: "MHIL", 204: "MSHP", 212: "MFILL", 220: "HILCOR", 228: "CADJ_R", 230: "CADJ_G", 232: "CADJ_B", 234: "WB", 236: "CM", 240: "CHROMA",
         248: "LUMA", 256: "BANDING", 264: "MLUMA", 272: "MBANDING", 280: "CA_SW", 284: "CA_PROF", 292: "CA_R", 300: "CA_B", 308: "DEF_SW",
         310: "DEF_GH", 312: "DEF_GR", 320: "DEF_GF", 328: "DEF_MH", 332: "DEF_MR", 340: "DEF_MF", 348: "MIX_R", 350: "MIX_G", 352: "MIX_B",
         354: "GRAIN_SW", 356: "GRAIN_SZ", 364: "GRAIN_RG", 372: "VIG_SW", 376: "VIG_MID", 384: "VIG_AMT", 392: "MTONE_R", 394: "MTONE_G",
         396: "MTONE_B", 400: "IMGSIZE", 404: "CSPACE", 416: "UNIQID*", 424: "IMGDATA*", 432: "WBTEMP", 440: "TRIM_L", 442: "TRIM_T", 444: "TRIM_R",
         446: "TRIM_B", 448: "HPC_SW", 452: "HPC_LVL", 460: "MHPC_SW", 464: "MHPC_LVL", 476: "EWB_DESC", 478: "ECM_DESC", 504: "RES_C", 512: "RES_M",
         536: "GC", 548: "GPU", 552: "GPUCARD*", 568: "TCHIST*", 634: "AUTO", 808: "TCPTS_C*", 824: "TCPTS_M*", 848: "MAKERNOTE*", 864: "RAWIFD*", 880: "TCHIST_M*"}

a = open(sys.argv[1], "rb").read()
b = open(sys.argv[2], "rb").read()
assert len(a) == 1008 and len(b) == 1008

def name(off):
    best = max((k for k in NAMES if k <= off), default=None)
    if best is None: return ""
    return NAMES[best] + ("" if best == off else "+%d" % (off - best))

def readings(d, off):
    u16 = struct.unpack_from("<H", d, off)[0]
    out = ["u16=%d" % u16]
    if off + 4 <= 1008: out.append("i32=%d" % struct.unpack_from("<i", d, off)[0])
    if off + 8 <= 1008:
        n, den = struct.unpack_from("<ii", d, off)
        if den: out.append("sr=%d/%d=%.3f" % (n, den, n / den))
        out.append("ptr=0x%x" % struct.unpack_from("<Q", d, off)[0])
    return " ".join(out)

diffs = [o for o in range(0, 1008, 2) if a[o:o+2] != b[o:o+2]]
print("%d differing 2-byte cells" % len(diffs))
run_start = None
prev = None
for o in diffs + [None]:
    if o is not None and prev is not None and o == prev + 2:
        prev = o; continue
    if run_start is not None:
        end = prev + 2
        print("\n[%4d..%4d) %s" % (run_start, end, name(run_start)))
        print("   SPP : " + readings(a, run_start) + "  bytes " + a[run_start:min(end, run_start + 16)].hex())
        print("   ours: " + readings(b, run_start) + "  bytes " + b[run_start:min(end, run_start + 16)].hex())
    run_start = o; prev = o
