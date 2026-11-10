/*
 * sppq - render a Sigma dp Quattro X3F through SIGMA Photo Pro 6's own
 * Quattro engine (lib95_QuattroDLLForMac.dylib) and write the 16-bit result.
 *
 * usage: sppq in.X3F out.rgb16 [preview.png]
 *
 * Environment:
 *   SPPQ_PARAMS   path to a 1008-byte tagAdjustmentParameters template
 *                 (default: ./010_params.bin)
 *   SPPQ_DYLIB    path to the Quattro dylib (default: SPP6 bundle path)
 *   SPPQ_VERBOSE  print progress
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <math.h>
#include <zlib.h>

#include "x3f_io.h"
#include "x3f_meta.h"
#include "x3f_printf.h"
#include "x3f_print_meta.h"
#include "dng.h"

#define PARAMS_SIZE 1008

/* ---- engine API (recovered from SPP's managed metadata) ---- */
typedef struct { int32_t left, top, right, bottom; } stRECT;
typedef int (*fnGetSurface)(uint32_t sizeMB, void **addr, uint32_t *index);
typedef int (*fnReturnSurface)(void *addr, uint32_t index);
typedef int (*fnPercentage)(int pct, void *obj);
typedef long (*fnInitialize)(const char *cert, void *capData, const char *tmpPath);
typedef long (*fnRequestProcess)(void *params, stRECT loupe, uint32_t designation,
                                 const void *input, fnGetSurface gs, fnReturnSurface rs,
                                 fnPercentage cb, void *obj, uint16_t outBufSizeMB,
                                 void *output);
typedef long (*fnFinalize)(void);
#include "engine_call.h"
typedef long (*fnQueryAllocationSize)(void *params /*by value, 1008 bytes*/, ...);

/* field offsets inside tagAdjustmentParameters (natural alignment, 1008 bytes) */
enum {
  P_NUMFIELDS = 0, P_FP0 = 4, P_FP1 = 8, P_FP2 = 12, P_FP3 = 16, P_FP4 = 20, P_FP5 = 24,
  P_WIDTH = 28, P_HEIGHT = 30, P_ROTATE = 32, P_SENSOR = 34, P_PROCVER = 40,
  P_CAMF = 48, P_ISO = 56, P_FLEN = 60, P_FNUM = 68, P_SHUTTER = 76, P_OBJDIST = 84,
  P_EXPCAM = 92, P_FLASH = 100, P_LENSPROF = 104, P_PROCMODE = 112,
  P_EXP = 116, P_CON = 124, P_SHA = 132, P_HIL = 140, P_SAT = 148, P_SHP = 156, P_FILL = 164,
  P_WB = 234, P_CM = 236, P_IMGSIZE = 400, P_CSPACE = 404, P_UNIQID = 416, P_IMGDATA = 424,
  P_WBTEMP = 432, P_TRIM_L = 440, P_TRIM_T = 442, P_TRIM_R = 444, P_TRIM_B = 446,
  P_EWB_DESC = 476, P_ECM_DESC = 478, P_GPU = 548, P_HPC_SW = 448, P_HPC_LVL = 452, P_MHPC_SW = 460, P_MHPC_LVL = 464, P_GC = 536,
  P_CHROMA = 240, P_LUMA = 248, P_BANDING = 256, P_MLUMA = 264, P_MBANDING = 272, P_CA_SW = 280, P_CA_PROF = 284, P_CA_R = 292, P_CA_B = 300,
  P_DEF_SW = 308, P_DEF_GH = 310, P_DEF_GR = 312, P_DEF_GF = 320, P_DEF_MH = 328, P_DEF_MR = 332, P_DEF_MF = 340, P_MIX_R = 348, P_MIX_G = 350, P_MIX_B = 352,
  P_GRAIN_SW = 354, P_GRAIN_SZ = 356, P_GRAIN_RG = 364, P_VIG_SW = 372, P_VIG_MID = 376, P_VIG_AMT = 384, P_MTONE_R = 392, P_MTONE_G = 394, P_MTONE_B = 396,
  P_HILCOR = 220, P_CADJ_R = 228, P_CADJ_G = 230, P_CADJ_B = 232, P_MEXP = 172, P_MCON = 180, P_MSHA = 188, P_MHIL = 196, P_MSHP = 204, P_MFILL = 212,
  P_RES_C = 504, P_RES_M = 512, P_AUTO = 634, P_GPUCARD = 552, P_TCHIST = 568,
  P_TCPTS_C = 808, P_TCPTS_M = 824, P_MAKERNOTE = 848, P_RAWIFD = 864, P_TCHIST_M = 880
};

static int verbose = 0;
static int debug_engine = 0;

/* SPP's engine formats its debug log with vsprintf into a buffer it then throws
   away. Interposing vsprintf lets us read that log (SPPQ_DEBUG=1). */
#include <stdarg.h>
static int my_vsprintf(char *buf, const char *fmt, va_list ap) {
  int n = vsprintf(buf, fmt, ap);
  if (debug_engine) { fputs("[spp] ", stderr); fputs(buf, stderr); if (n > 0 && buf[n - 1] != '\n') fputc('\n', stderr); }
  return n;
}
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <sys/mman.h>
/* point the dylib's GOT slot for vsprintf at our logger */
static void hook_engine_log(void *anysym) {
  Dl_info di; if (!dladdr(anysym, &di)) return;
  const struct mach_header_64 *mh = di.dli_fbase;
  void *real = dlsym(RTLD_DEFAULT, "vsprintf");
  const char *segs[][2] = { {"__DATA_CONST", "__got"}, {"__DATA", "__got"}, {"__DATA", "__la_symbol_ptr"} };
  for (int i = 0; i < 3; i++) {
    unsigned long size = 0;
    void **slots = (void **)getsectiondata(mh, segs[i][0], segs[i][1], &size);
    if (!slots) continue;
    for (unsigned long k = 0; k < size / sizeof(void *); k++) {
      if (slots[k] == real) {
        uintptr_t pg = (uintptr_t)&slots[k] & ~(uintptr_t)0x3fff;
        mprotect((void *)pg, 0x4000 * 2, PROT_READ | PROT_WRITE);
        slots[k] = (void *)my_vsprintf;
        if (verbose) fprintf(stderr, "engine log hooked (%s,%s slot %lu)\n", segs[i][0], segs[i][1], k);
      }
    }
  }
}
static void put16(uint8_t *p, int off, uint16_t v) { memcpy(p + off, &v, 2); }
static void put32(uint8_t *p, int off, uint32_t v) { memcpy(p + off, &v, 4); }
static void put64(uint8_t *p, int off, uint64_t v) { memcpy(p + off, &v, 8); }
static void putptr(uint8_t *p, int off, const void *v) { memcpy(p + off, &v, 8); }
static void putsr(uint8_t *p, int off, int32_t num, int32_t den) { put32(p, off, (uint32_t)num); put32(p, off + 4, (uint32_t)den); }
static void putur(uint8_t *p, int off, uint32_t num, uint32_t den) { put32(p, off, num); put32(p, off + 4, den); }
static uint32_t get32(const uint8_t *p, int off) { uint32_t v; memcpy(&v, p + off, 4); return v; }

static int my_get_surface(uint32_t sizeMB, void **addr, uint32_t *index) {
  *addr = calloc((size_t)sizeMB << 20, 1);
  if (index) *index = 0;
  if (verbose) fprintf(stderr, "  getSurface %u MB -> %p\n", sizeMB, *addr);
  return *addr ? 0 : -1;
}
static int my_return_surface(void *addr, uint32_t index) {
  (void)index; free(addr); return 0;
}
static int my_percentage(int pct, void *obj) {
  (void)obj;
  if (verbose) fprintf(stderr, "  progress %d\n", pct);
  return 0; /* 1 = cancel */
}

static int wb_preset_from_name(const char *wb) {
  if (!wb) return 1;
  static const struct { const char *n; int v; } tab[] = {
    {"Auto", 1}, {"Sunlight", 2}, {"Daylight", 2}, {"Shade", 3}, {"Overcast", 4},
    {"Incandescent", 5}, {"Fluorescent", 6}, {"Flash", 7}, {"Custom", 8},
    {"Monochrome", 9}, {"AutoLSP", 10}, {"ColorTemp", 11}, {0, 0} };
  for (int i = 0; tab[i].n; i++) if (!strcmp(wb, tab[i].n)) return tab[i].v;
  return 1;
}

/* small PNG writer for the preview (8-bit RGB) */
static void png_write(const char *path, const uint8_t *rgb, int w, int h) {
  FILE *f = fopen(path, "wb"); if (!f) return;
  size_t rawlen = (size_t)h * (w * 3 + 1);
  uint8_t *raw = malloc(rawlen);
  for (int y = 0; y < h; y++) { raw[y * (w * 3 + 1)] = 0; memcpy(raw + y * (w * 3 + 1) + 1, rgb + (size_t)y * w * 3, w * 3); }
  uLongf clen = compressBound(rawlen); uint8_t *c = malloc(clen);
  compress2(c, &clen, raw, rawlen, 6);
  uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10}; fwrite(sig, 1, 8, f);
  #define CHUNK(type, data, len) do { uint8_t hdr[8]; uint32_t L = (len); hdr[0]=L>>24;hdr[1]=L>>16;hdr[2]=L>>8;hdr[3]=L; memcpy(hdr+4,type,4); fwrite(hdr,1,8,f); if (L) fwrite(data,1,L,f); uint32_t crc = crc32(0, hdr+4, 4); if (L) crc = crc32(crc, data, L); uint8_t cb[4]={crc>>24,crc>>16,crc>>8,crc}; fwrite(cb,1,4,f);} while(0)
  uint8_t ihdr[13] = { w>>24, w>>16, w>>8, w, h>>24, h>>16, h>>8, h, 8, 2, 0, 0, 0 };
  CHUNK("IHDR", ihdr, 13); CHUNK("IDAT", c, (uint32_t)clen); CHUNK("IEND", NULL, 0);
  fclose(f); free(raw); free(c);
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: sppq in.X3F out.rgb16 [preview.png]\n"); return 2; }
  verbose = getenv("SPPQ_VERBOSE") != NULL;
  debug_engine = getenv("SPPQ_DEBUG") != NULL;
  x3f_printf_level = verbose ? INFO : ERR;

  /* ---------- 1. read the X3F ---------- */
  FILE *in = fopen(argv[1], "rb");
  if (!in) { perror(argv[1]); return 1; }
  x3f_t *x3f = x3f_new_from_file(in);
  if (!x3f) { fprintf(stderr, "not an X3F file\n"); return 1; }
  x3f_directory_entry_t *DEcamf = x3f_get_camf(x3f);
  x3f_directory_entry_t *DEraw = x3f_get_raw(x3f);
  x3f_directory_entry_t *DEprop = x3f_get_prop(x3f);
  if (!DEcamf || !DEraw) { fprintf(stderr, "missing CAMF or RAW section\n"); return 1; }
  if (x3f_load_data(x3f, DEcamf) != X3F_OK || x3f_load_data(x3f, DEraw) != X3F_OK) { fprintf(stderr, "cannot load X3F\n"); return 1; }
  if (DEprop) x3f_load_data(x3f, DEprop);

  if (getenv("SPPQ_DUMPMETA")) { x3f_printf_level = INFO; x3f_print_meta(x3f); return 0; }
  x3f_image_data_t *ID = &DEraw->header.data_subsection.image_data;
  if (!ID->tru || !ID->quattro || !ID->quattro->quattro_layout) {
    fprintf(stderr, "this tool expects a dp Quattro file with the full-size Quattro layout (type_format %#x)\n", ID->type_format);
    return 1;
  }
  x3f_quattro_t *Q = ID->quattro;
  uint32_t W = ID->columns, H = ID->rows;                 /* full-res frame, e.g. 5424x3616 */
  uint32_t qc = Q->plane[0].columns, qr = Q->plane[0].rows; /* quarter-res planes */
  x3f_area16_t *rg = &ID->tru->x3rgb16;                   /* channels 0,1 valid */
  x3f_area16_t *top = &Q->top16;                          /* full-res top layer */
  if (verbose) fprintf(stderr, "frame %ux%u, quarter planes %ux%u, top %ux%u\n", W, H, qc, qr, top->columns, top->rows);
  if (top->columns < 2 * qc || top->rows < 2 * qr) { fprintf(stderr, "unexpected layer sizes\n"); return 1; }

  /* ---------- 2. input image: float sextets {R,G,Btl,Btr,Bbl,Bbr} per 2x2 block ---------- */
  float *inbuf = malloc((size_t)qr * qc * 6 * sizeof(float));
  if (!inbuf) { fprintf(stderr, "out of memory\n"); return 1; }
  for (uint32_t y = 0; y < qr; y++) {
    const uint16_t *srg = rg->data + (size_t)y * rg->row_stride;
    const uint16_t *t0 = top->data + (size_t)(2 * y) * top->row_stride;
    const uint16_t *t1 = t0 + top->row_stride;
    float *d = inbuf + (size_t)y * qc * 6;
    for (uint32_t x = 0; x < qc; x++, d += 6) {
      d[0] = srg[x * rg->channels + 0];
      d[1] = srg[x * rg->channels + 1];
      d[2] = t0[2 * x]; d[3] = t0[2 * x + 1];
      d[4] = t1[2 * x]; d[5] = t1[2 * x + 1];
    }
  }

  if (verbose) {
    double mn[3] = {1e9, 1e9, 1e9}, mx[3] = {0, 0, 0}, sum[3] = {0, 0, 0};
    for (uint32_t y = 0; y < qr; y += 7) for (uint32_t x = 0; x < qc; x += 7) {
      const float *d = inbuf + ((size_t)y * qc + x) * 6;
      double v[3] = { d[0], d[1], (d[2] + d[3] + d[4] + d[5]) / 4 };
      for (int c = 0; c < 3; c++) { if (v[c] < mn[c]) mn[c] = v[c]; if (v[c] > mx[c]) mx[c] = v[c]; sum[c] += v[c]; }
    }
    double n = (double)((qr + 6) / 7) * ((qc + 6) / 7);
    fprintf(stderr, "input stats R %.0f..%.0f avg %.0f | G %.0f..%.0f avg %.0f | B %.0f..%.0f avg %.0f\n",
            mn[0], mx[0], sum[0] / n, mn[1], mx[1], sum[1] / n, mn[2], mx[2], sum[2] / n);
  }

  /* ---------- 3. parameter block ---------- */
  uint8_t *P = calloc(PARAMS_SIZE, 1);
  const char *ppath = getenv("SPPQ_PARAMS") ? getenv("SPPQ_PARAMS") : "010_params.bin";
  FILE *pf = fopen(ppath, "rb");
  if (!pf || fread(P, 1, PARAMS_SIZE, pf) != PARAMS_SIZE) { fprintf(stderr, "cannot read params template %s\n", ppath); return 1; }
  fclose(pf);

  /* field-present bits the Quattro engine insists on (AllFieldsSet) */
  put32(P, P_FP2, get32(P, P_FP2) | 0x1ff);
  /* SPP passes the developed (active-area) size, not the raw frame */
  uint32_t OW = W, OH = H, act[4];
  if (x3f_get_camf_matrix(x3f, "ActiveImageArea", 4, 0, 0, M_UINT, act)) {
    OW = act[2] - act[0] + 1; OH = act[3] - act[1] + 1;   /* full-res coordinates */
    OW &= ~1u; OH &= ~1u;
    if (verbose) fprintf(stderr, "ActiveImageArea %u,%u,%u,%u -> output %ux%u\n", act[0], act[1], act[2], act[3], OW, OH);
  }
  if (getenv("SPPQ_OUTW")) OW = atoi(getenv("SPPQ_OUTW"));
  if (getenv("SPPQ_OUTH")) OH = atoi(getenv("SPPQ_OUTH"));
  put16(P, P_WIDTH, (uint16_t)OW);
  put16(P, P_HEIGHT, (uint16_t)OH);
  /* the Quattro engine crops to the trimming rect; no trimming = whole frame */
  put16(P, P_TRIM_L, 0); put16(P, P_TRIM_T, 0);
  put16(P, P_TRIM_R, (uint16_t)(OW - 1)); put16(P, P_TRIM_B, (uint16_t)(OH - 1));
  if (getenv("SPPQ_TRIM")) { unsigned l, t, r, b; if (sscanf(getenv("SPPQ_TRIM"), "%u,%u,%u,%u", &l, &t, &r, &b) == 4) { put16(P, P_TRIM_L, l); put16(P, P_TRIM_T, t); put16(P, P_TRIM_R, r); put16(P, P_TRIM_B, b); } }
  put16(P, P_ROTATE, 1);
  put16(P, P_SENSOR, getenv("SPPQ_SENSOR") ? (uint16_t)strtol(getenv("SPPQ_SENSOR"), 0, 0) : 0x16); /* E_SENSOR_DP23 */
  if (getenv("SPPQ_PROCVER")) put64(P, P_PROCVER, strtoull(getenv("SPPQ_PROCVER"), 0, 0));

  /* CAMF block as stored in the file (engine decodes it), with slack like SPP */
  /* the engine wants the decoded CAMF ('CMb*' blocks), with slack like SPP's host */
  x3f_camf_t *CAMF = &DEcamf->header.data_subsection.camf;
  if (!CAMF->decoded_data || !CAMF->decoded_data_size) { fprintf(stderr, "CAMF could not be decoded\n"); return 1; }
  uint8_t *camf = calloc(CAMF->decoded_data_size + (1 << 20), 1);
  memcpy(camf, CAMF->decoded_data, CAMF->decoded_data_size);
  if (verbose) fprintf(stderr, "CAMF decoded %u bytes, magic %.4s\n", CAMF->decoded_data_size, (char *)camf);
  putptr(P, P_CAMF, camf);
  putptr(P, P_LENSPROF, NULL);

  /* exposure metadata from PROP */
  char *v;
  if (DEprop) {
    if (x3f_get_prop_entry(x3f, "ISO", &v)) put32(P, P_ISO, (uint32_t)atoi(v));
    if (x3f_get_prop_entry(x3f, "FLENGTH", &v)) putur(P, P_FLEN, (uint32_t)lround(atof(v) * 10), 10);
    if (x3f_get_prop_entry(x3f, "APERTURE", &v)) putur(P, P_FNUM, (uint32_t)lround(atof(v) * 10), 10);
    if (x3f_get_prop_entry(x3f, "EXPTIME", &v)) { double t = atof(v); putur(P, P_SHUTTER, (uint32_t)lround(t * 1000000), 1000000); }
    if (x3f_get_prop_entry(x3f, "EXPCOMP", &v)) putsr(P, P_EXPCAM, (int32_t)lround(atof(v) * 10), 10);
  }
  /* ---- camera settings block: the TIFF-style IFD in the v4 header (tags = SPP's TAG_V4HEAD_*) ---- */
  uint32_t cam_crop[4] = {0, 0, 0, 0}; int have_cam_crop = 0; uint32_t hdr_rotation = 0;
  {
    uint8_t hdr[1536]; fseek(in, 0, SEEK_SET);
    size_t hn = fread(hdr, 1, sizeof hdr, in);
    uint32_t ver = hn > 8 ? get32(hdr, 4) : 0;
    if (hn >= 64 && (ver >> 16) >= 4) {
      hdr_rotation = get32(hdr, 48);
      uint32_t n = get32(hdr, 52);
      if (n > 200) n = 0;
      struct { int tag; int off; char kind; } map[] = {   /* kind: s=SRATIONAL copy, h=SHORT->u16, b=BYTE->u16, B=BYTE->u8 */
        {1, P_WB, 'h'}, {2, P_CM, 'h'}, {3, P_EXP, 's'}, {4, P_CON, 's'}, {5, P_SHA, 's'}, {6, P_HIL, 's'}, {7, P_SAT, 's'}, {8, P_SHP, 's'}, {9, P_FILL, 's'},
        {10, P_HILCOR, 's'}, {11, P_CADJ_R, 'h'}, {12, P_CADJ_G, 'h'}, {13, P_CADJ_B, 'h'}, {14, P_CHROMA, 's'}, {15, P_LUMA, 's'}, {16, P_BANDING, 's'},
        {17, P_MEXP, 's'}, {18, P_MCON, 's'}, {19, P_MSHA, 's'}, {20, P_MHIL, 's'}, {21, P_MSHP, 's'}, {22, P_MFILL, 's'}, {23, P_MLUMA, 's'}, {24, P_MBANDING, 's'},
        {25, P_MIX_R, 'h'}, {26, P_MIX_G, 'h'}, {27, P_MIX_B, 'h'}, {28, P_MTONE_R, 'h'}, {29, P_MTONE_G, 'h'}, {30, P_MTONE_B, 'h'},
        {40, P_HPC_SW, 'h'}, {41, P_HPC_LVL, 's'}, {42, P_MHPC_SW, 'h'}, {43, P_MHPC_LVL, 's'},
        {44, P_CA_SW, 'h'}, {45, P_CA_PROF, 's'}, {46, P_CA_R, 's'}, {47, P_CA_B, 's'}, {48, P_DEF_SW, 'h'}, {49, P_DEF_GH, 'h'}, {50, P_DEF_GR, 's'}, {51, P_DEF_GF, 's'},
        {52, P_DEF_MH, 'h'}, {53, P_DEF_MR, 's'}, {54, P_DEF_MF, 's'}, {55, P_GRAIN_SW, 'h'}, {56, P_GRAIN_SZ, 's'}, {57, P_GRAIN_RG, 's'},
        {58, P_VIG_SW, 'h'}, {59, P_VIG_AMT, 's'}, {60, P_VIG_MID, 's'}, {63, P_RES_C, 's'}, {64, P_RES_M, 's'}, {66, P_GC, 'h'}, {0, 0, 0} };
      for (uint32_t i = 0; i < n && 56 + i * 12 + 12 <= hn; i++) {
        const uint8_t *e = hdr + 56 + i * 12;
        int tag = e[0] | e[1] << 8, typ = e[2] | e[3] << 8; uint32_t cnt = get32(e, 4), val = get32(e, 8);
        if (tag >= 31 && tag <= 34 && typ == 3) { cam_crop[tag - 31] = val & 0xffff; have_cam_crop = 1; continue; }
        if (tag == 36 && typ == 3) { putsr(P, P_WBTEMP, (int32_t)(val & 0xffff), 1); continue; }
        for (int k = 0; map[k].tag; k++) if (map[k].tag == tag) {
          if (map[k].kind == 's' && typ == 10 && cnt == 1 && val + 8 <= hn) memcpy(P + map[k].off, hdr + val, 8);
          else if (map[k].kind == 'h' && (typ == 3 || typ == 1 || typ == 8)) put16(P, map[k].off, (uint16_t)(val & 0xffff));
        }
      }
      if (verbose) fprintf(stderr, "camera settings: %u tags, crop %u,%u-%u,%u, rotation %u, WB %u, CM %u, HPC %u, GC %u\n",
                           n, cam_crop[0], cam_crop[1], cam_crop[2], cam_crop[3], hdr_rotation, get32(P, P_WB) & 0xffff, get32(P, P_CM) & 0xffff, get32(P, P_HPC_SW) & 0xffff, get32(P, P_GC) & 0xffff);
    }
  }
  put16(P, P_EWB_DESC, (uint16_t)(get32(P, P_WB) & 0xffff));
  put16(P, P_ECM_DESC, (uint16_t)(get32(P, P_CM) & 0xffff));
  P[P_AUTO] = 0;   /* camera/SPP default: no auto adjustment */
  if (getenv("SPPQ_CAMERA_CROP") && have_cam_crop) {
    put16(P, P_TRIM_L, cam_crop[0]); put16(P, P_TRIM_T, cam_crop[1]); put16(P, P_TRIM_R, cam_crop[2] - 1); put16(P, P_TRIM_B, cam_crop[3] - 1);
  }

  /* exposure metadata for v4 files lives in the CAMF */
  double cam_fnum = 0, cam_tv = 0, cam_iso = 0, cam_focal = 0; int cam_focal35 = 0;
  { double v; uint32_t u; char *cs = NULL;
    if (x3f_get_camf_float(x3f, "CaptureAperture", &v) && v > 0) { cam_fnum = v; putur(P, P_FNUM, (uint32_t)lround(v * 10), 10); }
    if (x3f_get_camf_float(x3f, "CaptureShutter", &v) && v > 0) { cam_tv = v / 1000.0; putur(P, P_SHUTTER, 1, (uint32_t)lround(pow(2.0, cam_tv))); }
    if ((x3f_get_camf_float(x3f, "CaptureISO", &v) && v > 0) || (x3f_get_camf_unsigned(x3f, "CaptureISO", &u) && (v = u) > 0)) { cam_iso = v; put32(P, P_ISO, (uint32_t)lround(v)); }
    if (x3f_get_camf_text(x3f, "CamsettingsInfo", &cs) && cs) {
      if (strstr(cs, "DP0")) { cam_focal = 14; cam_focal35 = 21; } else if (strstr(cs, "DP1")) { cam_focal = 19; cam_focal35 = 28; }
      else if (strstr(cs, "DP2")) { cam_focal = 30; cam_focal35 = 45; } else if (strstr(cs, "DP3")) { cam_focal = 50; cam_focal35 = 75; }
      if (cam_focal > 0) putur(P, P_FLEN, (uint32_t)lround(cam_focal * 10), 10);
    }
    if (verbose) fprintf(stderr, "exposure: f/%.1f, Tv %.3f (1/%.0f s), ISO %.0f, %.0f mm\n", cam_fnum, cam_tv, pow(2.0, cam_tv), cam_iso, cam_focal);
  }

  /* white balance as shot */
  int wbp = get32(P, P_WB) & 0xffff;
  if (!wbp) { char *wb = x3f_get_wb(x3f); wbp = wb_preset_from_name(wb); }
  if (getenv("SPPQ_WB")) wbp = atoi(getenv("SPPQ_WB"));
  put16(P, P_WB, (uint16_t)wbp); put16(P, P_EWB_DESC, (uint16_t)wbp);
  if (verbose) fprintf(stderr, "white balance preset %d\n", wbp);
  if (getenv("SPPQ_NEUTRAL")) {   /* ignore the camera's slider values */
    putsr(P, P_EXP, 0, 10); putsr(P, P_CON, 0, 10); putsr(P, P_SHA, 0, 10); putsr(P, P_HIL, 0, 10);
    putsr(P, P_SAT, 0, 10); putsr(P, P_SHP, 0, 10); putsr(P, P_FILL, 0, 10);
  }
  if (getenv("SPPQ_EV")) putsr(P, P_EXP, (int32_t)lround(atof(getenv("SPPQ_EV")) * 10), 10);
  if (getenv("SPPQ_CM")) { put16(P, P_CM, atoi(getenv("SPPQ_CM"))); put16(P, P_ECM_DESC, atoi(getenv("SPPQ_CM"))); }
  size_t olen = strlen(argv[2]); int want_dng = olen > 4 && !strcasecmp(argv[2] + olen - 4, ".dng");
  int want_tif = (olen > 4 && !strcasecmp(argv[2] + olen - 4, ".tif")) || (olen > 5 && !strcasecmp(argv[2] + olen - 5, ".tiff"));
  if (want_tif) put16(P, P_CSPACE, 1);   /* sRGB for a TIFF nobody will colour-manage */
  if (getenv("SPPQ_CSPACE")) put16(P, P_CSPACE, atoi(getenv("SPPQ_CSPACE")));
  if (want_dng) put16(P, P_CSPACE, 5);   /* the DNG stage expects SPP's ProPhoto output */
  if (getenv("SPPQ_IMGSIZE")) put16(P, P_IMGSIZE, atoi(getenv("SPPQ_IMGSIZE")));
  put16(P, P_GPU, getenv("SPPQ_GPU") ? atoi(getenv("SPPQ_GPU")) : 0);

  /* generic experiment hook: SPPQ_SET="off:u8|u16|u32|sr:value[/den];..." */
  if (getenv("SPPQ_SET")) {
    char *spec = strdup(getenv("SPPQ_SET")), *tok, *save = NULL;
    for (tok = strtok_r(spec, ";", &save); tok; tok = strtok_r(NULL, ";", &save)) {
      unsigned off; char ty[8]; long a = 0, b = 1;
      if (sscanf(tok, "%u:%7[^:]:%ld/%ld", &off, ty, &a, &b) >= 3 && off < PARAMS_SIZE) {
        if (!strcmp(ty, "u8")) P[off] = (uint8_t)a;
        else if (!strcmp(ty, "u16")) put16(P, off, (uint16_t)a);
        else if (!strcmp(ty, "u32")) put32(P, off, (uint32_t)a);
        else if (!strcmp(ty, "sr")) putsr(P, off, (int32_t)a, (int32_t)b);
        if (verbose) fprintf(stderr, "set %u (%s) = %ld/%ld\n", off, ty, a, b);
      }
    }
    free(spec);
  }

  /* pointers the host normally supplies */
  static char uniq[64];
  const char *base = strrchr(argv[1], '/'); base = base ? base + 1 : argv[1];
  snprintf(uniq, sizeof uniq, "sppq-%s", base);
  putptr(P, P_UNIQID, uniq);
  putptr(P, P_GPUCARD, calloc(256, 1));
  putptr(P, P_TCHIST, calloc(1 << 16, 1));
  putptr(P, P_TCHIST_M, calloc(1 << 16, 1));
  putptr(P, P_TCPTS_C, calloc(1 << 16, 1));
  putptr(P, P_TCPTS_M, calloc(1 << 16, 1));
  putptr(P, P_MAKERNOTE, NULL); putptr(P, P_RAWIFD, NULL);

  /* ---------- 4. engine ---------- */
  const char *dy = getenv("SPPQ_DYLIB") ? getenv("SPPQ_DYLIB")
    : "/Applications/SIGMA_PhotoPro6.app/Contents/MonoBundle/Sensor/lib95_QuattroDLLForMac.dylib";
  void *h = dlopen(dy, RTLD_NOW | RTLD_LOCAL);
  if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
  fnInitialize f_init = dlsym(h, "initialize");
  fnRequestProcess f_req = dlsym(h, "requestProcess");
  fnFinalize f_fin = dlsym(h, "finalize");
  if (!f_init || !f_req) { fprintf(stderr, "missing entry points\n"); return 1; }
  if (debug_engine) hook_engine_log((void *)f_init);

  char tmp[1024];
  snprintf(tmp, sizeof tmp, "%s/sppq-tmp", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
  mkdir(tmp, 0755);
  static uint8_t capdata[1 << 16];
  long r = f_init("SFiogvmeaon", capdata, tmp);
  fprintf(stderr, "initialize -> %ld\n", r);
  if (r) return 1;

  uint32_t desig = getenv("SPPQ_DESIG") ? (uint32_t)atoi(getenv("SPPQ_DESIG")) : 5;
  int bpp = ((desig & ~2u) == 5) ? 6 : 3;          /* from queryAllocationSize */
  size_t outlen = (size_t)OW * OH * bpp;
  uint8_t *out = calloc(outlen + (64u << 20), 1);
  stRECT loupe = { -1, -1, -1, -1 };
  r = engine_request((void *)f_req, P, loupe, desig, inbuf, (void *)my_get_surface, (void *)my_return_surface, (void *)my_percentage, (void *)0x7016, 250, out);
  if (bpp == 3) { /* widen 8-bit output to 16-bit so the rest of the tool is unchanged */
    uint8_t *o8 = out; uint16_t *o16 = calloc((size_t)OW * OH * 3, 2);
    for (size_t i = 0; i < (size_t)OW * OH * 3; i++) o16[i] = o8[i] * 257;
    out = (uint8_t *)o16; outlen = (size_t)OW * OH * 6;
  }
  fprintf(stderr, "requestProcess -> %ld\n", r);
  if (r) return 1;

  if (verbose) {
    const uint16_t *o16 = (const uint16_t *)out; uint32_t mn[3] = {65535, 65535, 65535}, mx[3] = {0, 0, 0}; double sum[3] = {0, 0, 0};
    size_t n = 0;
    for (size_t i = 0; i < (size_t)OW * OH; i += 97, n++) for (int c = 0; c < 3; c++) { uint16_t v = o16[i * 3 + c]; if (v < mn[c]) mn[c] = v; if (v > mx[c]) mx[c] = v; sum[c] += v; }
    fprintf(stderr, "output stats R %u..%u avg %.0f | G %u..%u avg %.0f | B %u..%u avg %.0f\n", mn[0], mx[0], sum[0] / n, mn[1], mx[1], sum[1] / n, mn[2], mx[2], sum[2] / n);
  }
  if (want_dng || want_tif) {
    dng_meta_t dm; memset(&dm, 0, sizeof dm);
    char model[64] = "SIGMA dp Quattro", uniq_model[64]; char *cs = NULL; uint32_t camu; double camf;
    if (x3f_get_camf_text(x3f, "CamsettingsInfo", &cs) && cs) {
      if (strstr(cs, "DP0")) strcpy(model, "SIGMA dp0 Quattro");
      else if (strstr(cs, "DP1")) strcpy(model, "SIGMA dp1 Quattro");
      else if (strstr(cs, "DP2")) strcpy(model, "SIGMA dp2 Quattro");
      else if (strstr(cs, "DP3")) strcpy(model, "SIGMA dp3 Quattro");
    }
    snprintf(uniq_model, sizeof uniq_model, "%s", model);
    dm.make = "SIGMA"; dm.model = model; dm.unique_model = uniq_model; dm.software = "sppq 0.1 (SIGMA Photo Pro engine)";
    dm.original_name = base;
    dm.fnumber = cam_fnum; dm.exposure_time = cam_tv > 0 ? pow(2.0, -cam_tv) : 0; dm.iso = (int)lround(cam_iso);
    if (cam_focal > 0) { dm.focal_length = cam_focal; dm.focal_length_35 = cam_focal35; }
    (void)camf; (void)camu;
    dm.rotation = hdr_rotation;
    if (have_cam_crop && cam_crop[2] > cam_crop[0] && cam_crop[3] > cam_crop[1]) {
      dm.crop_x = cam_crop[0]; dm.crop_y = cam_crop[1]; dm.crop_w = cam_crop[2] - cam_crop[0]; dm.crop_h = cam_crop[3] - cam_crop[1];
    }
    { struct stat st; if (stat(argv[1], &st) == 0) dm.capture_time = st.st_mtime; }
    memcpy(dm.unique_id, x3f->header.unique_identifier, 16); dm.have_unique_id = 1;
    if (verbose) fprintf(stderr, "DNG: %s f/%.1f %.5fs ISO %d crop %u,%u %ux%u\n", model, dm.fnumber, dm.exposure_time, dm.iso, dm.crop_x, dm.crop_y, dm.crop_w, dm.crop_h);
    int wr = want_dng ? write_dng(argv[2], &dm, (const uint16_t *)out, OW, OH) : write_tiff16(argv[2], &dm, (const uint16_t *)out, OW, OH);
    if (wr != 0) { fprintf(stderr, "cannot write %s\n", argv[2]); return 1; }
    printf("{\"w\":%u,\"h\":%u,\"out\":\"%s\"}\n", OW, OH, argv[2]);
    if (f_fin) f_fin();
    return 0;
  }
  FILE *of = fopen(argv[2], "wb");
  if (!of) { perror(argv[2]); return 1; }
  fwrite(out, 1, outlen, of); fclose(of);
  printf("{\"w\":%u,\"h\":%u,\"wb\":%d}\n", OW, OH, wbp);

  if (argc > 3) {
    /* quarter-size 8-bit preview with a display gamma; input treated as linear 16-bit */
    int pw = OW / 4, ph = OH / 4;
    uint8_t *prev = malloc((size_t)pw * ph * 3);
    const uint16_t *o16 = (const uint16_t *)out;
    for (int y = 0; y < ph; y++) for (int x = 0; x < pw; x++) for (int c = 0; c < 3; c++) {
      double acc = 0;
      for (int dy = 0; dy < 4; dy++) for (int dx = 0; dx < 4; dx++) acc += o16[((size_t)(y * 4 + dy) * OW + (x * 4 + dx)) * 3 + c];
      double lin = acc / 16.0 / 65535.0;
      double g = getenv("SPPQ_PREVIEW_LINEAR") ? lin : pow(lin, 1 / 2.2);
      int val = (int)lround(g * 255); if (val < 0) val = 0; if (val > 255) val = 255;
      prev[((size_t)y * pw + x) * 3 + c] = (uint8_t)val;
    }
    png_write(argv[3], prev, pw, ph);
  }
  if (getenv("SPPQ_PPM16")) {
    /* quarter-size box-filtered 16-bit PPM of the raw engine output, for analysis */
    int pw = OW / 4, ph = OH / 4;
    FILE *pf2 = fopen(getenv("SPPQ_PPM16"), "wb");
    if (pf2) {
      fprintf(pf2, "P6\n%d %d\n65535\n", pw, ph);
      const uint16_t *o16 = (const uint16_t *)out;
      for (int y = 0; y < ph; y++) for (int x = 0; x < pw; x++) for (int c = 0; c < 3; c++) {
        double acc = 0;
        for (int dy = 0; dy < 4; dy++) for (int dx = 0; dx < 4; dx++) acc += o16[((size_t)(y * 4 + dy) * OW + (x * 4 + dx)) * 3 + c];
        unsigned v = (unsigned)lround(acc / 16.0); uint8_t be[2] = { v >> 8, v & 255 }; fwrite(be, 1, 2, pf2);
      }
      fclose(pf2);
    }
  }
  if (f_fin) f_fin();
  return 0;
}
