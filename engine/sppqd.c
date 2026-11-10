/*
 * sppqd - persistent render server around SIGMA Photo Pro 6's X3F engines.
 *
 * dp Quattro files (X3F 4.x) are developed by lib95_QuattroDLLForMac.dylib, Merrill
 * files (X3F 3.0: DP1/DP2/DP3 Merrill, SD1) by lib99_MerillDLLForMac.dylib. The two
 * dylibs export the same entry points and take the same 1008-byte tagAdjustmentParameters;
 * only the pixel input differs (Quattro: float sextets per 2x2 block, Merrill: one float
 * {R,G,B} triplet per pixel). The engine is picked from the file, clients never choose.
 *
 * Reads one request per line on stdin (tab-separated key=value fields),
 * answers one line per request on stdout. Each engine is initialised once and
 * the most recently used X3F stays decoded in memory, so re-rendering the same
 * file with new slider values skips the file decode.
 *
 *   info    id=N  in=PATH
 *   render  id=N  in=PATH  out=PATH  fmt=tif|rgb16|rgb8
 *           [exp= con= sha= hil= sat= shp= fill=]   (SPP slider values, floats)
 *           [wb=n] [cm=n] [crop=0|1] [cspace=n] [desig=n] [loupe=l,t,r,b] [w= h=] [dedot=n]
 *           [set=off:ty:a/b;...]                    (raw parameter pokes)
 *   quit
 *
 * replies:   ok\tid=N\tw=\th=\trot=\t...      or      err\tid=N\tmsg=...
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <math.h>
#include <time.h>
#include <stdarg.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

#include "x3f_io.h"
#include "x3f_meta.h"
#include "x3f_printf.h"
#include "dng.h"

#define PARAMS_SIZE 1008
#define LENSPROF_SIZE 0x244000   /* the buffer SPP hands the Merrill engine for the lens profile text */

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

enum {
  P_FP2 = 12, P_WIDTH = 28, P_HEIGHT = 30, P_ROTATE = 32, P_SENSOR = 34, P_CAMF = 48,
  P_ISO = 56, P_FLEN = 60, P_FNUM = 68, P_SHUTTER = 76, P_EXPCAM = 92, P_LENSPROF = 104,
  P_EXP = 116, P_CON = 124, P_SHA = 132, P_HIL = 140, P_SAT = 148, P_SHP = 156, P_FILL = 164,
  P_WB = 234, P_CM = 236, P_IMGSIZE = 400, P_CSPACE = 404, P_UNIQID = 416,
  P_WBTEMP = 432, P_TRIM_L = 440, P_TRIM_T = 442, P_TRIM_R = 444, P_TRIM_B = 446,
  P_EWB_DESC = 476, P_ECM_DESC = 478, P_EXPNET = 480, P_EXPUS = 488,
  P_GPU = 548, P_HPC_SW = 448, P_HPC_LVL = 452, P_MHPC_SW = 460, P_MHPC_LVL = 464, P_GC = 536,
  P_CHROMA = 240, P_LUMA = 248, P_BANDING = 256, P_MLUMA = 264, P_MBANDING = 272, P_CA_SW = 280, P_CA_PROF = 284, P_CA_R = 292, P_CA_B = 300,
  P_DEF_SW = 308, P_DEF_GH = 310, P_DEF_GR = 312, P_DEF_GF = 320, P_DEF_MH = 328, P_DEF_MR = 332, P_DEF_MF = 340, P_MIX_R = 348, P_MIX_G = 350, P_MIX_B = 352,
  P_GRAIN_SW = 354, P_GRAIN_SZ = 356, P_GRAIN_RG = 364, P_VIG_SW = 372, P_VIG_MID = 376, P_VIG_AMT = 384, P_MTONE_R = 392, P_MTONE_G = 394, P_MTONE_B = 396,
  P_HILCOR = 220, P_CADJ_R = 228, P_CADJ_G = 230, P_CADJ_B = 232, P_MEXP = 172, P_MCON = 180, P_MSHA = 188, P_MHIL = 196, P_MSHP = 204, P_MFILL = 212,
  P_RES_C = 504, P_RES_M = 512, P_AUTO = 634, P_GPUCARD = 552, P_TCHIST = 568,
  P_SW736 = 736, P_SW776 = 776, P_SW800 = 800,   /* switches SPP's Merrill driver clears; meaning unknown */
  P_TCPTS_C = 808, P_TCPTS_M = 824, P_MAKERNOTE = 848, P_RAWIFD = 864, P_TCHIST_M = 880
};

static int verbose = 0, debug_engine = 0;
static char line_buf[1 << 16];

static double now(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec * 1e-9; }
static void logv(const char *fmt, ...) { if (!verbose) return; va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap); fputc('\n', stderr); }

/* The engine decides the real output size itself on the quick-display path; the only
   place it tells us is its log, so the log hook is always installed and watches for it. */
static int eng_rows = 0, eng_cols = 0;
static int my_vsprintf(char *buf, const char *fmt, va_list ap) {
  int n = vsprintf(buf, fmt, ap);
  int r, c;
  if (sscanf(buf, "Output Size: [Rows Cols]: [%d %d]", &r, &c) == 2) { eng_rows = r; eng_cols = c; }
  if (debug_engine) { fputs("[spp] ", stderr); fputs(buf, stderr); if (n > 0 && buf[n - 1] != '\n') fputc('\n', stderr); }
  return n;
}
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <sys/mman.h>
static void hook_engine_log(void *anysym) {
  Dl_info di; if (!dladdr(anysym, &di)) return;
  const struct mach_header_64 *mh = di.dli_fbase;
  void *real = dlsym(RTLD_DEFAULT, "vsprintf");
  const char *segs[][2] = { {"__DATA_CONST", "__got"}, {"__DATA", "__got"}, {"__DATA", "__la_symbol_ptr"} };
  for (int i = 0; i < 3; i++) {
    unsigned long size = 0;
    void **slots = (void **)getsectiondata(mh, segs[i][0], segs[i][1], &size);
    if (!slots) continue;
    for (unsigned long k = 0; k < size / sizeof(void *); k++) if (slots[k] == real) {
      uintptr_t pg = (uintptr_t)&slots[k] & ~(uintptr_t)0x3fff;
      mprotect((void *)pg, 0x4000 * 2, PROT_READ | PROT_WRITE);
      slots[k] = (void *)my_vsprintf;
    }
  }
}

static void put16(uint8_t *p, int off, uint16_t v) { memcpy(p + off, &v, 2); }
static void put32(uint8_t *p, int off, uint32_t v) { memcpy(p + off, &v, 4); }
static void putptr(uint8_t *p, int off, const void *v) { memcpy(p + off, &v, 8); }
static void putsr(uint8_t *p, int off, int32_t num, int32_t den) { put32(p, off, (uint32_t)num); put32(p, off + 4, (uint32_t)den); }
static void putur(uint8_t *p, int off, uint32_t num, uint32_t den) { put32(p, off, num); put32(p, off + 4, den); }
static uint32_t get32(const uint8_t *p, int off) { uint32_t v; memcpy(&v, p + off, 4); return v; }
static uint16_t get16(const uint8_t *p, int off) { uint16_t v; memcpy(&v, p + off, 2); return v; }
static double getsr(const uint8_t *p, int off) { int32_t n = (int32_t)get32(p, off), d = (int32_t)get32(p, off + 4); return d ? (double)n / d : 0; }

static int my_get_surface(uint32_t sizeMB, void **addr, uint32_t *index) {
  *addr = calloc((size_t)sizeMB << 20, 1); if (index) *index = 0; return *addr ? 0 : -1;
}
static int my_return_surface(void *addr, uint32_t index) { (void)index; free(addr); return 0; }
static int my_percentage(int pct, void *obj) { (void)pct; (void)obj; return 0; }

static int wb_preset_from_name(const char *wb) {
  if (!wb) return 1;
  static const struct { const char *n; int v; } tab[] = {
    {"Auto", 1}, {"Sunlight", 2}, {"Daylight", 2}, {"Shade", 3}, {"Overcast", 4},
    {"Incandescent", 5}, {"Fluorescent", 6}, {"Flash", 7}, {"Custom", 8},
    {"Monochrome", 9}, {"AutoLSP", 10}, {"ColorTemp", 11}, {0, 0} };
  for (int i = 0; tab[i].n; i++) if (!strcmp(wb, tab[i].n)) return tab[i].v;
  return 1;
}

/* Colour mode names as the Merrill cameras write them into the X3F header (SPP's own codes). */
static int cm_code_from_name(const char *cm) {
  if (!cm || !*cm) return 3;
  static const struct { const char *n; int v; } tab[] = {
    {"Standard", 3}, {"Vivid", 4}, {"Neutral", 5}, {"Portrait", 6}, {"Landscape", 7},
    {"FOV Classic Blue", 8}, {"FOVClassicBlue", 8}, {"FCBlue", 8}, {0, 0} };
  for (int i = 0; tab[i].n; i++) if (!strcasecmp(cm, tab[i].n)) return tab[i].v;
  return 3;
}

/* ------------------------------------------------------------------ engines */
enum { K_QUATTRO = 0, K_MERRILL = 1, K_COUNT };
typedef struct {
  const char *name, *dylib, *env, *tmpsub;
  void *h; fnInitialize init; fnRequestProcess req; fnFinalize fin;
  int ready;                /* initialised and usable */
  int used;                 /* has processed an image since it was (re)initialised */
  uint8_t capdata[1 << 16];
} engine_t;
static engine_t engines[K_COUNT] = {
  { "quattro", "/Applications/SIGMA_PhotoPro6.app/Contents/MonoBundle/Sensor/lib95_QuattroDLLForMac.dylib", "SPPQ_DYLIB", "" },
  { "merrill", "/Applications/SIGMA_PhotoPro6.app/Contents/MonoBundle/Sensor/lib99_MerillDLLForMac.dylib", "SPPM_DYLIB", "/merrill" },
};

static const char *engine_tmp(const engine_t *E, char *buf, size_t n) {
  snprintf(buf, n, "%s/sppqd-tmp", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
  mkdir(buf, 0755);
  if (E->tmpsub[0]) { size_t l = strlen(buf); snprintf(buf + l, n - l, "%s", E->tmpsub); mkdir(buf, 0755); }
  return buf;
}

static int ensure_engine(int k, char *err, size_t errlen) {
  engine_t *E = &engines[k];
  if (E->ready) return 0;
  if (!E->h) {
    const char *dy = getenv(E->env) ? getenv(E->env) : E->dylib;
    /* The engines open some tables relative to the process working directory
       (getcwd()+"/Contents/Resources/GData/QT…" for the Quattro GPU kernels, getcwd()+"/BData/…").
       SPP itself runs with the app bundle root as its working directory (measured inside SPP),
       so mirror that; the app's launcher sets the same directory. Our own paths are absolute. */
    static int entered = 0;
    if (!entered) {
      entered = 1;
      const char *res = getenv("SPPQ_RESOURCES");
      char buf[2048];
      if (!res) {
        const char *p = strstr(dy, "/Contents/");
        if (p && (size_t)(p - dy) < sizeof buf - 1) { memcpy(buf, dy, (size_t)(p - dy)); buf[p - dy] = 0; res = buf; }
      }
      if (res && chdir(res) == 0) logv("working directory %s", res);
      else logv("warning: could not enter the SIGMA Photo Pro bundle (%s)", res ? res : "unknown");
    }
    void *h = dlopen(dy, RTLD_NOW | RTLD_LOCAL);
    if (!h) { snprintf(err, errlen, "cannot load SIGMA Photo Pro engine (%s): %s", E->name, dlerror()); return -1; }
    E->init = dlsym(h, "initialize"); E->req = dlsym(h, "requestProcess"); E->fin = dlsym(h, "finalize");
    if (!E->init || !E->req) { snprintf(err, errlen, "engine entry points missing (%s)", E->name); return -1; }
    hook_engine_log((void *)E->init);
    E->h = h;
  }
  char tmp[1024]; engine_tmp(E, tmp, sizeof tmp);
  double t0 = now();
  long r = E->init("SFiogvmeaon", E->capdata, tmp);
  if (r) { snprintf(err, errlen, "engine initialize failed (%s: %ld)", E->name, r); return -1; }
  logv("%s engine initialised in %.2fs", E->name, now() - t0);
  E->ready = 1; E->used = 0;
  return 0;
}

static void engine_reset(int k) {
  engine_t *E = &engines[k];
  if (!E->ready) return;
  if (E->fin) E->fin();
  char tmp[1024]; engine_tmp(E, tmp, sizeof tmp);
  long r = E->init("SFiogvmeaon", E->capdata, tmp);
  logv("%s engine reset -> %ld", E->name, r);
  E->used = 0;
  if (r) E->ready = 0;   /* next request re-initialises from scratch */
}

/* ------------------------------------------------------------------ loaded image */
typedef struct {
  char path[2048]; time_t mtime; off_t size;
  int kind;                                 /* K_QUATTRO / K_MERRILL */
  float *inbuf; uint8_t *camf;
  uint8_t P0[PARAMS_SIZE];                  /* parameters as shot, pointers filled in */
  uint32_t OW, OH;                          /* active-area (developed) size */
  uint32_t cam_crop[4]; int have_cam_crop; uint32_t rotation;
  double fnum, tv, iso, focal; int focal35; char model[64];
  char uniq[64]; uint8_t uid[16];
  /* the engine's last request on this image, for the change mask of the next one */
  int processed; uint8_t lastP[PARAMS_SIZE]; uint32_t lastDesig; stRECT lastLoupe;
} loaded_t;

static loaded_t *cur = NULL;
static uint8_t template_params[PARAMS_SIZE];
static uint8_t *lensprof = NULL;          /* Merrill lens profile text in the engine's padded buffer */
static void *host_gpucard, *host_tchist, *host_tchist_m, *host_tcpts_c, *host_tcpts_m;

static void unload(void) {
  if (!cur) return;
  free(cur->inbuf); free(cur->camf); free(cur); cur = NULL;
}

/* SPP's host hands the Merrill engine a lens profile as text in a 0x244000-byte buffer.
   The one captured from SPP (DP1 Merrill) lives next to the parameter template. */
static void load_lensprof(const char *params_path) {
  char dir[2048]; snprintf(dir, sizeof dir, "%s", params_path);
  char *s = strrchr(dir, '/'); if (s) *s = 0; else strcpy(dir, ".");
  char p[2300]; snprintf(p, sizeof p, "%s/009_lensprofile.bin", dir);
  FILE *f = fopen(p, "rb");
  if (!f) { logv("no lens profile at %s", p); return; }
  uint8_t *buf = calloc(LENSPROF_SIZE, 1);
  size_t n = buf ? fread(buf, 1, LENSPROF_SIZE - 1, f) : 0;
  fclose(f);
  if (!n) { free(buf); return; }
  lensprof = buf;
}

/* Merrill (TRUE II) files: one full-resolution {R,G,B} plane. Everything here mirrors what
   SPP's own host does before calling lib99, as recovered from the X3FM Converter's driver. */
static int fill_merrill(loaded_t *L, x3f_t *x3f, x3f_image_data_t *ID, x3f_directory_entry_t *DEcamf,
                        x3f_directory_entry_t *DEprop, const char *path, char *err, size_t errlen) {
  x3f_area16_t *rg = &ID->tru->x3rgb16;
  if (rg->channels != 3 || !rg->data || rg->columns < 16 || rg->rows < 16 || rg->columns > 65535 || rg->rows > 65535) {
    snprintf(err, errlen, "unexpected Merrill layer layout (%ux%u, %u channels)", rg->columns, rg->rows, rg->channels); return -1;
  }
  uint32_t W = rg->columns, H = rg->rows;

  /* engine input: one float {R,G,B} triplet per pixel, the decoded raw values as they are */
  L->inbuf = malloc((size_t)W * H * 3 * sizeof(float));
  if (!L->inbuf) { snprintf(err, errlen, "out of memory"); return -1; }
  for (uint32_t y = 0; y < H; y++) {
    const uint16_t *s = rg->data + (size_t)y * rg->row_stride;
    float *d = L->inbuf + (size_t)y * W * 3;
    for (size_t i = 0; i < (size_t)W * 3; i++) d[i] = s[i];
  }

  uint8_t *P = L->P0;
  memcpy(P, template_params, PARAMS_SIZE);   /* captured from SPP developing a DP1 Merrill file */
  /* SPP's output is the active area (4704x3136 of the 4928x3264 frame): the engine locates it
     itself from the CAMF and crops to P_WIDTH/P_HEIGHT; the raw frame size would include the borders */
  { uint32_t act[4], OW = W, OH = H;
    if (x3f_get_camf_matrix(x3f, "ActiveImageArea", 4, 0, 0, M_UINT, act) && act[2] > act[0] && act[3] > act[1] && act[2] < W && act[3] < H) {
      OW = (act[2] - act[0] + 1) & ~1u; OH = (act[3] - act[1] + 1) & ~1u;
    } else if (W == 4928 && H == 3264) { OW = 4704; OH = 3136; }
    L->OW = OW; L->OH = OH;
    put16(P, P_WIDTH, (uint16_t)OW); put16(P, P_HEIGHT, (uint16_t)OH); }
  /* P_ROTATE (1 = upright) and P_SENSOR (0x14, the F20 sensor) stay as captured */

  x3f_camf_t *CAMF = &DEcamf->header.data_subsection.camf;
  if (!CAMF->decoded_data || !CAMF->decoded_data_size) { snprintf(err, errlen, "CAMF could not be decoded"); return -1; }
  L->camf = calloc(CAMF->decoded_data_size + (1 << 20), 1);
  if (!L->camf) { snprintf(err, errlen, "out of memory"); return -1; }
  memcpy(L->camf, CAMF->decoded_data, CAMF->decoded_data_size);
  putptr(P, P_CAMF, L->camf);
  putptr(P, P_LENSPROF, getenv("SPPM_NOLENS") ? NULL : lensprof);

  /* the captured session's slider values are not this file's: neutral first, then what the
     camera (or SPP, when the file was saved from it) wrote into the header's extended data */
  { const int sl[] = { P_EXP, P_CON, P_SHA, P_HIL, P_SAT, P_SHP, P_FILL };
    for (unsigned i = 0; i < sizeof sl / sizeof *sl; i++) putsr(P, sl[i], 0, 10); }
  x3f_header_t *HD = &x3f->header;
  for (int i = 0; i < NUM_EXT_DATA; i++) {
    int t = HD->extended_types[i]; double v = HD->extended_data[i];
    switch (t) {
    case X3F_EXT_TYPE_EXPOSURE_ADJUST:   putsr(P, P_EXP, (int32_t)lround(v * 100), 100); break;
    case X3F_EXT_TYPE_CONTRAST_ADJUST:   putsr(P, P_CON, (int32_t)lround(v * 100), 100); break;
    case X3F_EXT_TYPE_SHADOW_ADJUST:     putsr(P, P_SHA, (int32_t)lround(v * 100), 100); break;
    case X3F_EXT_TYPE_HIGHLIGHT_ADJUST:  putsr(P, P_HIL, (int32_t)lround(v * 100), 100); break;
    case X3F_EXT_TYPE_SATURATION_ADJUST: putsr(P, P_SAT, (int32_t)lround(v * 100), 100); break;
    case X3F_EXT_TYPE_SHARPNESS_ADJUST:  putsr(P, P_SHP, (int32_t)lround(v * 100), 100); break;
    case X3F_EXT_TYPE_FILL_LIGHT_ADJUST: putsr(P, P_FILL, (int32_t)lround(v * 100), 100); break;
    case X3F_EXT_TYPE_RED_ADJUST:   put16(P, P_CADJ_R, (uint16_t)lround(v * 32768)); break;
    case X3F_EXT_TYPE_GREEN_ADJUST: put16(P, P_CADJ_G, (uint16_t)lround(v * 32768)); break;
    case X3F_EXT_TYPE_BLUE_ADJUST:  put16(P, P_CADJ_B, (uint16_t)lround(v * 32768)); break;
    case 12: putsr(P, P_CHROMA, (int32_t)lround(v * 100), 100); break;                                   /* chroma NR, 0.5 default */
    case 13: putsr(P, P_LUMA, (int32_t)lround(v * 100), 100); putsr(P, P_MLUMA, (int32_t)lround(v * 100), 100); break;  /* luma NR */
    default: break;
    }
  }
  L->rotation = HD->rotation;

  char *v;
  if (DEprop) {
    if (x3f_get_prop_entry(x3f, "ISO", &v)) { L->iso = atof(v); put32(P, P_ISO, (uint32_t)atoi(v)); }
    if (x3f_get_prop_entry(x3f, "FLENGTH", &v)) { L->focal = atof(v); putur(P, P_FLEN, (uint32_t)lround(L->focal * 10), 10); }
    if (x3f_get_prop_entry(x3f, "FLEQ35MM", &v)) L->focal35 = (int)lround(atof(v));
    if (x3f_get_prop_entry(x3f, "APERTURE", &v)) { L->fnum = atof(v); putur(P, P_FNUM, (uint32_t)lround(L->fnum * 1000), 1000); }
    if (x3f_get_prop_entry(x3f, "EXPTIME", &v)) {   /* microseconds */
      long us = atol(v);
      if (us > 0) { putur(P, P_SHUTTER, (uint32_t)us, 1000000); putur(P, P_EXPUS, (uint32_t)us, 1); L->tv = -log2(us / 1e6); }
    }
    if (x3f_get_prop_entry(x3f, "EXPCOMP", &v)) putsr(P, P_EXPCAM, (int32_t)lround(atof(v) * 10), 10);
    if (x3f_get_prop_entry(x3f, "EXPNET", &v)) putsr(P, P_EXPNET, (int32_t)lround(atof(v) * 100), 100);
    if (x3f_get_prop_entry(x3f, "CAMMODEL", &v) && v && *v) snprintf(L->model, sizeof L->model, "%s%s", strncmp(v, "SIGMA", 5) ? "SIGMA " : "", v);
  }
  if (!L->model[0]) strcpy(L->model, "SIGMA DP Merrill");
  if (L->focal35 == 0 && L->focal > 0) L->focal35 = (int)lround(L->focal * 1.5);

  int wbp = wb_preset_from_name(HD->white_balance);
  put16(P, P_WB, (uint16_t)wbp); put16(P, P_EWB_DESC, (uint16_t)wbp);
  int cm = cm_code_from_name(HD->color_mode);
  put16(P, P_CM, (uint16_t)cm); put16(P, P_ECM_DESC, (uint16_t)cm);

  /* what SPP's Merrill driver clears before every request */
  put16(P, P_GPU, 0); P[P_AUTO] = 0; put16(P, P_CA_SW, 0); put16(P, P_GC, 0);
  put16(P, P_SW736, 0); put16(P, P_SW776, 0); P[P_SW800] = 0;

  { const char *bn = strrchr(path, '/'); bn = bn ? bn + 1 : path;
    snprintf(L->uniq, sizeof L->uniq, "x3f-%.40s-%lld", bn, (long long)L->size); }
  putptr(P, P_UNIQID, L->uniq);
  putptr(P, P_GPUCARD, host_gpucard); putptr(P, P_TCHIST, host_tchist); putptr(P, P_TCHIST_M, host_tchist_m);
  putptr(P, P_TCPTS_C, host_tcpts_c); putptr(P, P_TCPTS_M, host_tcpts_m);
  putptr(P, P_MAKERNOTE, NULL); putptr(P, P_RAWIFD, NULL);
  return 0;
}

static loaded_t *load_x3f(const char *path, char *err, size_t errlen) {
  FILE *in = fopen(path, "rb");
  if (!in) { snprintf(err, errlen, "cannot open %s", path); return NULL; }
  x3f_t *x3f = x3f_new_from_file(in);
  if (!x3f) { fclose(in); snprintf(err, errlen, "not an X3F file"); return NULL; }
  loaded_t *L = calloc(1, sizeof *L);
  snprintf(L->path, sizeof L->path, "%s", path);
  { struct stat st; if (stat(path, &st) == 0) { L->mtime = st.st_mtime; L->size = st.st_size; } }
  memcpy(L->uid, x3f->header.unique_identifier, 16);

  x3f_directory_entry_t *DEcamf = x3f_get_camf(x3f);
  x3f_directory_entry_t *DEraw = x3f_get_raw(x3f);
  x3f_directory_entry_t *DEprop = x3f_get_prop(x3f);
  if (!DEcamf || !DEraw) { snprintf(err, errlen, "missing CAMF or RAW section"); goto fail; }
  if (x3f_load_data(x3f, DEcamf) != X3F_OK || x3f_load_data(x3f, DEraw) != X3F_OK) { snprintf(err, errlen, "cannot decode X3F"); goto fail; }
  if (DEprop) x3f_load_data(x3f, DEprop);

  x3f_image_data_t *ID = &DEraw->header.data_subsection.image_data;
  if (ID->tru && ID->quattro && ID->quattro->quattro_layout) L->kind = K_QUATTRO;
  else if (ID->tru && (ID->type_format == X3F_IMAGE_RAW_MERRILL || ID->type_format == X3F_IMAGE_RAW_TRUE) && (x3f->header.version >> 16) == 3) L->kind = K_MERRILL;
  else { snprintf(err, errlen, "not a dp Quattro or Merrill file (type %#x, X3F %u.%u)", ID->type_format, x3f->header.version >> 16, x3f->header.version & 0xffff); goto fail; }

  if (L->kind == K_MERRILL) {
    if (fill_merrill(L, x3f, ID, DEcamf, DEprop, path, err, errlen)) goto fail;
    x3f_delete(x3f); fclose(in);
    return L;
  }

  x3f_quattro_t *Q = ID->quattro;
  uint32_t W = ID->columns, H = ID->rows;
  uint32_t qc = Q->plane[0].columns, qr = Q->plane[0].rows;
  x3f_area16_t *rg = &ID->tru->x3rgb16;
  x3f_area16_t *top = &Q->top16;
  if (top->columns < 2 * qc || top->rows < 2 * qr) { snprintf(err, errlen, "unexpected layer sizes"); goto fail; }

  /* engine input: float sextets {R,G,Btl,Btr,Bbl,Bbr} per 2x2 block */
  L->inbuf = malloc((size_t)qr * qc * 6 * sizeof(float));
  if (!L->inbuf) { snprintf(err, errlen, "out of memory"); goto fail; }
  for (uint32_t y = 0; y < qr; y++) {
    const uint16_t *srg = rg->data + (size_t)y * rg->row_stride;
    const uint16_t *t0 = top->data + (size_t)(2 * y) * top->row_stride;
    const uint16_t *t1 = t0 + top->row_stride;
    float *d = L->inbuf + (size_t)y * qc * 6;
    for (uint32_t x = 0; x < qc; x++, d += 6) {
      d[0] = srg[x * rg->channels + 0]; d[1] = srg[x * rg->channels + 1];
      d[2] = t0[2 * x]; d[3] = t0[2 * x + 1]; d[4] = t1[2 * x]; d[5] = t1[2 * x + 1];
    }
  }

  /* Highlight pixels. Every 16th 2x2 block of every 4th block row (CAMF HighlightPixelsInfo =
     origin x,y and period x,y in block units) is a low-sensitivity "highlight" pixel whose real
     readings the camera stores in the top plane's extra columns (plane 2 is 6272 wide for the
     5888-wide frame: block i of a lattice row sits at columns 5888+2i, 5888+2i+1 of its two pixel
     rows); the plane itself holds an interpolated fill there. SIGMA Photo Pro hands the engine the
     real readings (captured 9 Nov 2026, identical values); with the fill, the engine's highlight
     gain turns every lattice block into a bright speck. */
  {
    uint32_t hp[4] = { 0, 0, 16, 4 };
    x3f_get_camf_matrix(x3f, "HighlightPixelsInfo", 2, 2, 0, M_UINT, hp);
    uint32_t x0 = hp[0], y0 = hp[1], px = hp[2], py = hp[3], extra = 2 * qc;
    if (px && py && top->columns > extra + 1) {
      for (uint32_t y = y0; y < qr; y += py) {
        const uint16_t *t0 = top->data + (size_t)(2 * y) * top->row_stride, *t1 = t0 + top->row_stride;
        for (uint32_t x = x0, i = 0; x < qc && extra + 2 * i + 1 < top->columns; x += px, i++) {
          float *d = L->inbuf + ((size_t)y * qc + x) * 6;
          d[2] = t0[extra + 2 * i]; d[3] = t0[extra + 2 * i + 1]; d[4] = t1[extra + 2 * i]; d[5] = t1[extra + 2 * i + 1];
        }
      }
    }
  }

  uint8_t *P = L->P0;
  memcpy(P, template_params, PARAMS_SIZE);
  put32(P, P_FP2, get32(P, P_FP2) | 0x1ff);
  uint32_t OW = W, OH = H, act[4];
  if (x3f_get_camf_matrix(x3f, "ActiveImageArea", 4, 0, 0, M_UINT, act)) {
    OW = (act[2] - act[0] + 1) & ~1u; OH = (act[3] - act[1] + 1) & ~1u;
  }
  L->OW = OW; L->OH = OH;
  put16(P, P_ROTATE, 1);
  put16(P, P_SENSOR, 0x16);

  x3f_camf_t *CAMF = &DEcamf->header.data_subsection.camf;
  if (!CAMF->decoded_data || !CAMF->decoded_data_size) { snprintf(err, errlen, "CAMF could not be decoded"); goto fail; }
  L->camf = calloc(CAMF->decoded_data_size + (1 << 20), 1);
  memcpy(L->camf, CAMF->decoded_data, CAMF->decoded_data_size);
  putptr(P, P_CAMF, L->camf);
  putptr(P, P_LENSPROF, NULL);

  char *v;
  if (DEprop) {
    if (x3f_get_prop_entry(x3f, "ISO", &v)) put32(P, P_ISO, (uint32_t)atoi(v));
    if (x3f_get_prop_entry(x3f, "FLENGTH", &v)) putur(P, P_FLEN, (uint32_t)lround(atof(v) * 10), 10);
    if (x3f_get_prop_entry(x3f, "APERTURE", &v)) putur(P, P_FNUM, (uint32_t)lround(atof(v) * 10), 10);
    if (x3f_get_prop_entry(x3f, "EXPTIME", &v)) { double t = atof(v); putur(P, P_SHUTTER, (uint32_t)lround(t * 1000000), 1000000); }
    if (x3f_get_prop_entry(x3f, "EXPCOMP", &v)) putsr(P, P_EXPCAM, (int32_t)lround(atof(v) * 10), 10);
  }
  /* camera settings IFD in the v4 header (tags 14/15, 40-43 and 66 are read by SPP but not
     passed on; see the defaults below) */
  {
    uint8_t hdr[1536]; fseek(in, 0, SEEK_SET);
    size_t hn = fread(hdr, 1, sizeof hdr, in);
    uint32_t ver = hn > 8 ? get32(hdr, 4) : 0;
    if (hn >= 64 && (ver >> 16) >= 4) {
      L->rotation = get32(hdr, 48);
      uint32_t n = get32(hdr, 52); if (n > 200) n = 0;
      struct { int tag; int off; char kind; } map[] = {
        {1, P_WB, 'h'}, {2, P_CM, 'h'}, {3, P_EXP, 's'}, {4, P_CON, 's'}, {5, P_SHA, 's'}, {6, P_HIL, 's'}, {7, P_SAT, 's'}, {8, P_SHP, 's'}, {9, P_FILL, 's'},
        {10, P_HILCOR, 's'}, {11, P_CADJ_R, 'h'}, {12, P_CADJ_G, 'h'}, {13, P_CADJ_B, 'h'}, {16, P_BANDING, 's'},
        {17, P_MEXP, 's'}, {18, P_MCON, 's'}, {19, P_MSHA, 's'}, {20, P_MHIL, 's'}, {21, P_MSHP, 's'}, {22, P_MFILL, 's'}, {23, P_MLUMA, 's'}, {24, P_MBANDING, 's'},
        {25, P_MIX_R, 'h'}, {26, P_MIX_G, 'h'}, {27, P_MIX_B, 'h'}, {28, P_MTONE_R, 'h'}, {29, P_MTONE_G, 'h'}, {30, P_MTONE_B, 'h'},
        {44, P_CA_SW, 'h'}, {45, P_CA_PROF, 's'}, {46, P_CA_R, 's'}, {47, P_CA_B, 's'}, {48, P_DEF_SW, 'h'}, {49, P_DEF_GH, 'h'}, {50, P_DEF_GR, 's'}, {51, P_DEF_GF, 's'},
        {52, P_DEF_MH, 'h'}, {53, P_DEF_MR, 's'}, {54, P_DEF_MF, 's'}, {55, P_GRAIN_SW, 'h'}, {56, P_GRAIN_SZ, 's'}, {57, P_GRAIN_RG, 's'},
        {58, P_VIG_SW, 'h'}, {59, P_VIG_AMT, 's'}, {60, P_VIG_MID, 's'}, {63, P_RES_C, 's'}, {64, P_RES_M, 's'}, {0, 0, 0} };
      for (uint32_t i = 0; i < n && 56 + i * 12 + 12 <= hn; i++) {
        const uint8_t *e = hdr + 56 + i * 12;
        int tag = e[0] | e[1] << 8, typ = e[2] | e[3] << 8; uint32_t cnt = get32(e, 4), val = get32(e, 8);
        if (tag >= 31 && tag <= 34 && typ == 3) { L->cam_crop[tag - 31] = val & 0xffff; L->have_cam_crop = 1; continue; }
        if (tag == 36 && typ == 3) { putsr(P, P_WBTEMP, (int32_t)(val & 0xffff), 1); continue; }
        for (int k = 0; map[k].tag; k++) if (map[k].tag == tag) {
          if (map[k].kind == 's' && typ == 10 && cnt == 1 && val + 8 <= hn) memcpy(P + map[k].off, hdr + val, 8);
          else if (map[k].kind == 'h' && (typ == 3 || typ == 1 || typ == 8)) put16(P, map[k].off, (uint16_t)(val & 0xffff));
        }
      }
    }
  }
  if (L->have_cam_crop && !(L->cam_crop[2] > L->cam_crop[0] && L->cam_crop[3] > L->cam_crop[1])) L->have_cam_crop = 0;
  P[P_AUTO] = 0;
  /* Values measured in SPP 6.9's own requestProcess blocks (Nov 2026) that differ from the header:
     - SPP's own behaviour: 536 (GC) stays 0 although header tag 66 is 1 in every dp Quattro file
       (GC=1 renders flat and cool), and the two processing-version cells 42/46 are 2/3 (the
       template was captured as 1/2): greener greens, warmer skin.
     - This user's saved default set (~/Library/Application Support/SIGMA_PhotoPro6/X3F_Setting.xml,
       which SPP applies in "Custom" mode): HighlightPixelCollection 0 -> 448/460 = 0 with the levels
       452/464 left at 5/10 (header tags 40-43 say 1 and 0/10, which darkens highlights), and
       NoiseReductionChroma/Luma 0 -> 240/248 = 0/4 (header tags 14/15 say 2/4). The same set's
       ColorAdjust R/G/B 0.8122/0.7169/1.0 (cells 228/230/232 = 28329/27746/32768) is not applied
       here; the app can send it as a set= poke. With all of it SPP's review render is matched. */
  put16(P, P_GC, 0);
  put16(P, P_HPC_SW, 0); putsr(P, P_HPC_LVL, 5, 10); put16(P, P_MHPC_SW, 0); putsr(P, P_MHPC_LVL, 5, 10);
  putsr(P, P_CHROMA, 0, 4); putsr(P, P_LUMA, 0, 4);
  put16(P, 42, 2); put16(P, 46, 3);

  { double d; uint32_t u; char *cs = NULL;
    if (x3f_get_camf_float(x3f, "CaptureAperture", &d) && d > 0) { L->fnum = d; putur(P, P_FNUM, (uint32_t)lround(d * 10), 10); }
    if (x3f_get_camf_float(x3f, "CaptureShutter", &d) && d > 0) { L->tv = d / 1000.0; putur(P, P_SHUTTER, 1, (uint32_t)lround(pow(2.0, L->tv))); }
    if ((x3f_get_camf_float(x3f, "CaptureISO", &d) && d > 0) || (x3f_get_camf_unsigned(x3f, "CaptureISO", &u) && (d = u) > 0)) { L->iso = d; put32(P, P_ISO, (uint32_t)lround(d)); }
    strcpy(L->model, "SIGMA dp Quattro");
    if (x3f_get_camf_text(x3f, "CamsettingsInfo", &cs) && cs) {
      if (strstr(cs, "DP0")) { L->focal = 14; L->focal35 = 21; strcpy(L->model, "SIGMA dp0 Quattro"); }
      else if (strstr(cs, "DP1")) { L->focal = 19; L->focal35 = 28; strcpy(L->model, "SIGMA dp1 Quattro"); }
      else if (strstr(cs, "DP2")) { L->focal = 30; L->focal35 = 45; strcpy(L->model, "SIGMA dp2 Quattro"); }
      else if (strstr(cs, "DP3")) { L->focal = 50; L->focal35 = 75; strcpy(L->model, "SIGMA dp3 Quattro"); }
      if (L->focal > 0) putur(P, P_FLEN, (uint32_t)lround(L->focal * 10), 10);
    }
  }
  int wbp = get16(P, P_WB);
  if (!wbp) { char *wb = x3f_get_wb(x3f); wbp = wb_preset_from_name(wb); }
  put16(P, P_WB, (uint16_t)wbp); put16(P, P_EWB_DESC, (uint16_t)wbp);
  put16(P, P_ECM_DESC, get16(P, P_CM));
  put16(P, P_GPU, 0);

  /* the header's "unique identifier" is per camera, not per file; name the request after the file */
  { const char *bn = strrchr(path, '/'); bn = bn ? bn + 1 : path;
    snprintf(L->uniq, sizeof L->uniq, "x3f-%.40s-%lld", bn, (long long)L->size); }
  putptr(P, P_UNIQID, L->uniq);
  putptr(P, P_GPUCARD, host_gpucard); putptr(P, P_TCHIST, host_tchist); putptr(P, P_TCHIST_M, host_tchist_m);
  putptr(P, P_TCPTS_C, host_tcpts_c); putptr(P, P_TCPTS_M, host_tcpts_m);
  putptr(P, P_MAKERNOTE, NULL); putptr(P, P_RAWIFD, NULL);

  x3f_delete(x3f); fclose(in);
  return L;
fail:
  x3f_delete(x3f); fclose(in);
  free(L->inbuf); free(L->camf); free(L);
  return NULL;
}

static int ensure_loaded(const char *path, char *err, size_t errlen) {
  struct stat st;
  if (cur && !strcmp(cur->path, path) && stat(path, &st) == 0 && st.st_mtime == cur->mtime && st.st_size == cur->size) return 0;
  double t0 = now();
  loaded_t *L = load_x3f(path, err, errlen);
  if (!L) return -1;
  /* The engines keep per-window stage caches that are not keyed on the image, so a
     different file must start from a fresh engine (initialize is instantaneous). */
  if (engines[L->kind].used) engine_reset(L->kind);
  unload(); cur = L;
  logv("loaded %s (%s) in %.2fs (%ux%u, crop %d, rot %u)", path, engines[L->kind].name, now() - t0, L->OW, L->OH, L->have_cam_crop, L->rotation);
  return 0;
}

/* ------------------------------------------------------------------ requests */
#define MAXF 48
typedef struct { int n; char *k[MAXF], *v[MAXF]; } fields_t;
static const char *fget(const fields_t *f, const char *k) { for (int i = 0; i < f->n; i++) if (!strcmp(f->k[i], k)) return f->v[i]; return NULL; }
static int fhas(const fields_t *f, const char *k) { return fget(f, k) != NULL; }

static void reply_err(const char *id, const char *msg) { printf("err\tid=%s\tmsg=%s\n", id ? id : "", msg); fflush(stdout); }

static void print_settings(const uint8_t *P) {
  printf("\texp=%.1f\tcon=%.1f\tsha=%.1f\thil=%.1f\tsat=%.1f\tshp=%.1f\tfill=%.1f\twb=%u\tcm=%u",
         getsr(P, P_EXP), getsr(P, P_CON), getsr(P, P_SHA), getsr(P, P_HIL), getsr(P, P_SAT), getsr(P, P_SHP), getsr(P, P_FILL),
         get16(P, P_WB), get16(P, P_CM));
}

static void do_info(const fields_t *f) {
  const char *id = fget(f, "id"), *in = fget(f, "in"); char err[512];
  if (!in) { reply_err(id, "missing in="); return; }
  if (ensure_loaded(in, err, sizeof err)) { reply_err(id, err); return; }
  loaded_t *L = cur;
  uint32_t w = L->OW, h = L->OH;
  if (L->have_cam_crop) { w = L->cam_crop[2] - L->cam_crop[0]; h = L->cam_crop[3] - L->cam_crop[1]; }
  printf("ok\tid=%s\tw=%u\th=%u\tfullw=%u\tfullh=%u\trot=%u", id ? id : "", w, h, L->OW, L->OH, L->rotation);
  if (L->have_cam_crop) printf("\tcrop=%u,%u,%u,%u", L->cam_crop[0], L->cam_crop[1], L->cam_crop[2], L->cam_crop[3]);
  print_settings(L->P0);
  printf("\tmodel=%s\tiso=%.0f\tfnum=%.1f\tshutter=%.6f\tfocal=%.0f\tfocal35=%d\tuid=%s\tengine=%s\n",
         L->model, L->iso, L->fnum, L->tv > 0 ? pow(2.0, -L->tv) : 0, L->focal, L->focal35, L->uniq + 4, engines[L->kind].name);
  fflush(stdout);
}

/* Cell 4 of the parameter block tells the engine what changed since its last request on this
   image, one bit per control, and the engine reruns only the stages those controls feed; -1 means
   everything (the first request on an image, or a change we have no bit for, such as white balance
   or colour mode, which invalidate the denoised stage anyway). Learned from SIGMA Photo Pro 6.9's
   own blocks (recorded 10 Nov 2026 on a DP2 Merrill file). Measured here (10 Nov 2026): the Quattro
   engine needs the bits — a slider move on a quick render drops from ~120 ms to ~3 ms and a 16-bit
   save following another save of the same image from ~3 s to ~50 ms, with identical output — while
   the Merrill engine works out the change by itself (~20 ms either way) and, given the bits across a
   change of designation, reuses the quick path's reduced stages for a save and returns a different
   image. So the bits go to the Quattro engine only, and only within one designation. */
enum { CH_EXP = 1u << 15, CH_CON = 1u << 16, CH_SHA = 1u << 17, CH_HIL = 1u << 18, CH_SAT = 1u << 19, CH_SHP = 1u << 20, CH_FILL = 1u << 21,
       CH_COLOR = 0xE0000000u, CH_VIEW = 0x3u };
static uint32_t change_mask(const uint8_t *prev, const uint8_t *cur, int view_changed) {
  static const struct { int off, len; uint32_t bit; } map[] = {
    { P_EXP, 8, CH_EXP }, { P_CON, 8, CH_CON }, { P_SHA, 8, CH_SHA }, { P_HIL, 8, CH_HIL }, { P_SAT, 8, CH_SAT }, { P_SHP, 8, CH_SHP }, { P_FILL, 8, CH_FILL },
    { P_CADJ_R, 6, CH_COLOR }, { P_WIDTH, 4, CH_VIEW }, { P_TRIM_L, 8, CH_VIEW } };
  uint8_t a[PARAMS_SIZE], b[PARAMS_SIZE]; memcpy(a, prev, PARAMS_SIZE); memcpy(b, cur, PARAMS_SIZE);
  uint32_t m = view_changed ? CH_VIEW : 0;
  for (unsigned i = 0; i < sizeof map / sizeof *map; i++) {
    if (memcmp(a + map[i].off, b + map[i].off, map[i].len)) m |= map[i].bit;
    memset(a + map[i].off, 0, map[i].len); memset(b + map[i].off, 0, map[i].len);
  }
  memset(a + 4, 0, 24); memset(b + 4, 0, 24);          /* the mask cells themselves */
  if (memcmp(a, b, PARAMS_SIZE)) return 0xffffffffu;   /* something without a bit changed */
  return m ? m : CH_VIEW;
}

static void do_render(const fields_t *f) {
  const char *id = fget(f, "id"), *in = fget(f, "in"), *out = fget(f, "out"); char err[512];
  if (!in || !out) { reply_err(id, "missing in= or out="); return; }
  double t0 = now();
  if (ensure_loaded(in, err, sizeof err)) { reply_err(id, err); return; }
  loaded_t *L = cur;
  engine_t *E = &engines[L->kind];
  if (ensure_engine(L->kind, err, sizeof err)) { reply_err(id, err); return; }
  uint8_t P[PARAMS_SIZE]; memcpy(P, L->P0, PARAMS_SIZE);

  /* sliders: SPP units (exposure in EV, the rest -2..2), stored as n/10 */
  struct { const char *k; int off; } sl[] = { {"exp", P_EXP}, {"con", P_CON}, {"sha", P_SHA}, {"hil", P_HIL}, {"sat", P_SAT}, {"shp", P_SHP}, {"fill", P_FILL}, {0, 0} };
  for (int i = 0; sl[i].k; i++) { const char *v = fget(f, sl[i].k); if (v) putsr(P, sl[i].off, (int32_t)lround(atof(v) * 10), 10); }
  if (fhas(f, "wb")) { int wb = atoi(fget(f, "wb")); if (wb > 0) { put16(P, P_WB, (uint16_t)wb); put16(P, P_EWB_DESC, (uint16_t)wb); } }
  if (fhas(f, "cm")) { int cm = atoi(fget(f, "cm")); if (cm > 0) { put16(P, P_CM, (uint16_t)cm); put16(P, P_ECM_DESC, (uint16_t)cm); } }
  if (fhas(f, "cspace")) put16(P, P_CSPACE, (uint16_t)atoi(fget(f, "cspace")));
  if (fhas(f, "imgsize")) put16(P, P_IMGSIZE, (uint16_t)atoi(fget(f, "imgsize")));
  if (fhas(f, "gpu")) put16(P, P_GPU, (uint16_t)atoi(fget(f, "gpu")));

  const char *fmt = fget(f, "fmt"); if (!fmt) fmt = "tif";
  int want_tif = !strcmp(fmt, "tif");
  if (want_tif && !fhas(f, "cspace")) put16(P, P_CSPACE, 1);   /* sRGB */
  if (!want_tif && !fhas(f, "cspace")) put16(P, P_CSPACE, 1);

  /* geometry: whole developed frame, or the camera's aspect-ratio crop */
  uint32_t OW = L->OW, OH = L->OH;
  int crop = fhas(f, "crop") ? atoi(fget(f, "crop")) : 1;
  if (L->kind == K_QUATTRO) {
    put16(P, P_TRIM_L, 0); put16(P, P_TRIM_T, 0); put16(P, P_TRIM_R, (uint16_t)(OW - 1)); put16(P, P_TRIM_B, (uint16_t)(OH - 1));
    if (crop && L->have_cam_crop) {
      OW = L->cam_crop[2] - L->cam_crop[0]; OH = L->cam_crop[3] - L->cam_crop[1];
      put16(P, P_TRIM_L, (uint16_t)L->cam_crop[0]); put16(P, P_TRIM_T, (uint16_t)L->cam_crop[1]);
      put16(P, P_TRIM_R, (uint16_t)(L->cam_crop[2] - 1)); put16(P, P_TRIM_B, (uint16_t)(L->cam_crop[3] - 1));
    }
  }
  /* Merrill: SPP's driver leaves the trim rect at zero (whole frame); an explicit trim= still applies */
  if (fhas(f, "trim")) { unsigned l, t, r, b; if (sscanf(fget(f, "trim"), "%u,%u,%u,%u", &l, &t, &r, &b) == 4) { put16(P, P_TRIM_L, l); put16(P, P_TRIM_T, t); put16(P, P_TRIM_R, r); put16(P, P_TRIM_B, b); OW = r - l + 1; OH = b - t + 1; } }
  if (fhas(f, "w")) OW = (uint32_t)atoi(fget(f, "w"));
  if (fhas(f, "h")) OH = (uint32_t)atoi(fget(f, "h"));
  put16(P, P_WIDTH, (uint16_t)OW); put16(P, P_HEIGHT, (uint16_t)OH);

  stRECT loupe = { -1, -1, -1, -1 };
  if (fhas(f, "loupe")) sscanf(fget(f, "loupe"), "%d,%d,%d,%d", &loupe.left, &loupe.top, &loupe.right, &loupe.bottom);

  if (fhas(f, "set")) {   /* raw pokes, for experiments: off:ty:a/b;... */
    char *spec = strdup(fget(f, "set")), *tok, *save = NULL;
    for (tok = strtok_r(spec, ";", &save); tok; tok = strtok_r(NULL, ";", &save)) {
      unsigned off; char ty[8]; long a = 0, b = 1;
      if (sscanf(tok, "%u:%7[^:]:%ld/%ld", &off, ty, &a, &b) >= 3 && off < PARAMS_SIZE) {
        if (!strcmp(ty, "u8")) P[off] = (uint8_t)a;
        else if (!strcmp(ty, "u16")) put16(P, off, (uint16_t)a);
        else if (!strcmp(ty, "u32")) put32(P, off, (uint32_t)a);
        else if (!strcmp(ty, "sr")) putsr(P, off, (int32_t)a, (int32_t)b);
      }
    }
    free(spec);
  }

  uint32_t desig = fhas(f, "desig") ? (uint32_t)atoi(fget(f, "desig")) : 5;
  int bpp = ((desig & ~2u) == 5) ? 6 : 3;
  size_t outlen = (size_t)OW * OH * bpp;
  /* On the quick-display path the engine chooses its own output size (up to a bit over
     half the frame), so always give it room for that plus generous slack. */
  size_t halfcap = ((size_t)L->OW / 2 + 128) * ((size_t)L->OH / 2 + 128) * 8;
  size_t alloc = (outlen > halfcap ? outlen : halfcap) + (64u << 20);
  uint8_t *pix = calloc(alloc, 1);
  if (!pix) { reply_err(id, "out of memory"); return; }
  uint16_t membudget = fhas(f, "mem") ? (uint16_t)atoi(fget(f, "mem")) : 250;
  /* incremental processing (Quattro, same designation and loupe as the last request; see change_mask) */
  int same_view = L->processed && desig == L->lastDesig && memcmp(&loupe, &L->lastLoupe, sizeof loupe) == 0;
  uint32_t mask = 0xffffffffu;
  if (L->kind == K_QUATTRO && same_view && !fhas(f, "full")) mask = change_mask(L->lastP, P, 0);
  if (mask != 0xffffffffu) { put32(P, 4, mask); memset(P + 8, 0, 20); }   /* SPP zeroes cells 8..27 on these */
  uint8_t sent[PARAMS_SIZE]; memcpy(sent, P, PARAMS_SIZE);   /* the engine writes into P; the next mask compares against what was asked */
  eng_rows = eng_cols = 0;
  double t1 = now();
  long r = engine_request((void *)E->req, P, loupe, desig, L->inbuf, (void *)my_get_surface, (void *)my_return_surface, (void *)my_percentage, (void *)0x7016, membudget, pix);
  double t2 = now();
  E->used = 1;
  if (r) { L->processed = 0; free(pix); char m[128]; snprintf(m, sizeof m, "engine requestProcess failed (%ld)", r); reply_err(id, m); return; }
  memcpy(L->lastP, sent, PARAMS_SIZE); L->processed = 1; L->lastDesig = desig; L->lastLoupe = loupe;
  logv("render desig %u %ux%u mask %#x: engine %.0f ms, wrote %llu bytes above its stack arguments", desig, OW, OH, mask, (t2 - t1) * 1000,
       (unsigned long long)engine_stack_written);
  if (engine_stack_written > 3072) fprintf(stderr, "warning: the engine wrote %llu bytes into its 4 KB stack scratch\n", (unsigned long long)engine_stack_written);
  /* The engine writes a complete BMP into the buffer: 54-byte file+info header, then the
     rows (top-down when the height is negative), 24-bit BGR on the display paths and 48-bit
     RGB on the 16-bit save path. Unwrap it so the rest of the pipeline sees packed pixels. */
  if (pix[0] == 'B' && pix[1] == 'M') {
    uint32_t off = get32(pix, 10); int32_t bw = (int32_t)get32(pix, 18), bh = (int32_t)get32(pix, 22); int bits = get16(pix, 28);
    uint32_t rows = (uint32_t)(bh < 0 ? -bh : bh);
    if (bits == bpp * 8 && bw > 0 && rows > 0 && off >= 54 && (size_t)bw * bpp * rows + off <= alloc) {
      size_t stride = ((size_t)bw * bpp + 3) & ~(size_t)3;
      uint8_t *packed = malloc((size_t)bw * rows * bpp);
      if (packed) {
        for (uint32_t y = 0; y < rows; y++) {
          const uint8_t *src = pix + off + (size_t)(bh < 0 ? y : rows - 1 - y) * stride;
          memcpy(packed + (size_t)y * bw * bpp, src, (size_t)bw * bpp);
        }
        free(pix); pix = packed;
        OW = (uint32_t)bw; OH = rows; outlen = (size_t)OW * OH * bpp;
        eng_rows = eng_cols = 0;
      }
    }
  }
  if (eng_cols > 0 && eng_rows > 0 && ((uint32_t)eng_cols != OW || (uint32_t)eng_rows != OH)) {
    /* quick-display path: the engine wrote a smaller, tightly packed image into the buffer */
    if ((size_t)eng_cols * eng_rows * bpp <= outlen) { OW = (uint32_t)eng_cols; OH = (uint32_t)eng_rows; outlen = (size_t)OW * OH * bpp; }
  }
  int want_rgb8 = !strcmp(fmt, "rgb8");
  /* 8-bit display designations (0..3) come out as BGR; the 8-bit save designations (4, 6) are RGB */
  int swap = fhas(f, "swap") ? atoi(fget(f, "swap")) : (desig <= 3);
  if (bpp == 3) {
    size_t npx = (size_t)OW * OH;
    if (swap) for (size_t i = 0; i < npx; i++) { uint8_t t = pix[i * 3]; pix[i * 3] = pix[i * 3 + 2]; pix[i * 3 + 2] = t; }
    outlen = npx * 3;
  }
  /* The quick-display path leaves a vertical chroma dot pattern. For on-screen use only,
     smooth (R-G) and (B-G) horizontally over 2*dedot+1 pixels; luminance detail is kept. */
  int dedot = fhas(f, "dedot") ? atoi(fget(f, "dedot")) : 0;
  if (L->kind == K_MERRILL) dedot = 0;   /* the Merrill quick path has no dot pattern; smoothing would only soften it */
  if (bpp == 3 && dedot > 0 && OW > (uint32_t)(2 * dedot + 1)) {
    int rad = dedot; int win = 2 * rad + 1;
    int32_t *dr = malloc(sizeof(int32_t) * (OW + 1)), *db = malloc(sizeof(int32_t) * (OW + 1));
    for (uint32_t y = 0; y < OH; y++) {
      uint8_t *row = pix + (size_t)y * OW * 3;
      dr[0] = 0; db[0] = 0;
      for (uint32_t x = 0; x < OW; x++) { dr[x + 1] = dr[x] + ((int)row[x * 3] - (int)row[x * 3 + 1]); db[x + 1] = db[x] + ((int)row[x * 3 + 2] - (int)row[x * 3 + 1]); }
      for (uint32_t x = 0; x < OW; x++) {
        int lo = (int)x - rad, hi = (int)x + rad; if (lo < 0) lo = 0; if (hi >= (int)OW) hi = OW - 1;
        int n = hi - lo + 1;
        int g = row[x * 3 + 1];
        int r = g + (dr[hi + 1] - dr[lo]) / n, b = g + (db[hi + 1] - db[lo]) / n;
        row[x * 3] = (uint8_t)(r < 0 ? 0 : r > 255 ? 255 : r);
        row[x * 3 + 2] = (uint8_t)(b < 0 ? 0 : b > 255 ? 255 : b);
      }
    }
    free(dr); free(db); (void)win;
  }
  if (bpp == 3 && !want_rgb8) {   /* widen so the 16-bit writers can be used */
    uint16_t *o16 = calloc((size_t)OW * OH * 3, 2);
    for (size_t i = 0; i < (size_t)OW * OH * 3; i++) o16[i] = pix[i] * 257;
    free(pix); pix = (uint8_t *)o16; outlen = (size_t)OW * OH * 6; bpp = 6;
  } else if (bpp == 6 && want_rgb8) {   /* narrow a 16-bit render for display use */
    uint8_t *o8 = malloc((size_t)OW * OH * 3); const uint16_t *s = (const uint16_t *)pix;
    for (size_t i = 0; i < (size_t)OW * OH * 3; i++) o8[i] = (uint8_t)(s[i] >> 8);
    free(pix); pix = o8; outlen = (size_t)OW * OH * 3; bpp = 3;
  }

  char outpath[4096]; snprintf(outpath, sizeof outpath, "%s", out);
  if (verbose) {   /* process-state probe: the engine has been seen to disturb the host's fds */
    int probe = open(out, O_WRONLY | O_CREAT | O_TRUNC, 0644); int e1 = errno;
    int probe2 = open(outpath, O_WRONLY | O_CREAT | O_TRUNC, 0644); int e2 = errno;
    char cwd[1024]; if (!getcwd(cwd, sizeof cwd)) strcpy(cwd, "?");
    printf("dbg\tid=%s\tfd0=%d\tfd1=%d\tfd2=%d\topen_orig=%d(%s)\topen_copy=%d(%s)\tcwd=%s\tline=%p\tout=%p\n", id ? id : "",
           fcntl(0, F_GETFL), fcntl(1, F_GETFL), fcntl(2, F_GETFL), probe, probe < 0 ? strerror(e1) : "ok", probe2, probe2 < 0 ? strerror(e2) : "ok", cwd, (void *)line_buf, (const void *)out);
    fflush(stdout);
    if (probe >= 0) close(probe); if (probe2 >= 0) close(probe2);
  }
  out = outpath;
  int wr = 0;
  if (want_tif) {
    dng_meta_t dm; memset(&dm, 0, sizeof dm);
    char uniq_model[64]; snprintf(uniq_model, sizeof uniq_model, "%s", L->model);
    const char *base = strrchr(L->path, '/'); base = base ? base + 1 : L->path;
    dm.make = "SIGMA"; dm.model = L->model; dm.unique_model = uniq_model; dm.software = "X3F Studio (SIGMA Photo Pro engine)";
    dm.original_name = base;
    dm.fnumber = L->fnum; dm.exposure_time = L->tv > 0 ? pow(2.0, -L->tv) : 0; dm.iso = (int)lround(L->iso);
    if (L->focal > 0) { dm.focal_length = L->focal; dm.focal_length_35 = L->focal35; }
    dm.rotation = L->rotation; dm.capture_time = L->mtime;
    memcpy(dm.unique_id, L->uid, 16); dm.have_unique_id = 1;
    wr = write_tiff16(out, &dm, (const uint16_t *)pix, OW, OH);
  } else {
    FILE *of = fopen(out, "wb");
    if (!of) wr = -1; else { if (fwrite(pix, 1, outlen, of) != outlen) wr = -1; fclose(of); }
  }
  free(pix);
  if (wr) { char m[2300]; snprintf(m, sizeof m, "cannot write %s: %s", out, strerror(errno)); reply_err(id, m); return; }
  printf("ok\tid=%s\tw=%u\th=%u\trot=%u\tbpp=%d\tfmt=%s\tms=%.0f\tengine_ms=%.0f\tengine=%s\n", id ? id : "", OW, OH, L->rotation, bpp, fmt, (now() - t0) * 1000, (t2 - t1) * 1000, E->name);
  fflush(stdout);
}

int main(int argc, char **argv) {
  verbose = getenv("SPPQD_VERBOSE") != NULL;
  debug_engine = getenv("SPPQ_DEBUG") != NULL;
  x3f_printf_level = ERR;
  const char *ppath = getenv("SPPQ_PARAMS") ? getenv("SPPQ_PARAMS") : (argc > 1 ? argv[1] : "010_params.bin");
  FILE *pf = fopen(ppath, "rb");
  if (!pf || fread(template_params, 1, PARAMS_SIZE, pf) != PARAMS_SIZE) { fprintf(stderr, "cannot read params template %s\n", ppath); return 1; }
  fclose(pf);
  load_lensprof(ppath);
  host_gpucard = calloc(256, 1); host_tchist = calloc(1 << 16, 1); host_tchist_m = calloc(1 << 16, 1);
  host_tcpts_c = calloc(1 << 16, 1); host_tcpts_m = calloc(1 << 16, 1);
  setvbuf(stdout, NULL, _IOLBF, 0);
  printf("ready\tversion=2\tengines=quattro,merrill\n"); fflush(stdout);

  char *line = line_buf;
  while (fgets(line, sizeof line_buf, stdin)) {
    size_t n = strlen(line); while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
    if (!n) continue;
    fields_t f = { 0 };
    char *cmd = line, *rest = strchr(line, '\t');
    if (rest) { *rest++ = 0; char *save = NULL; for (char *tok = strtok_r(rest, "\t", &save); tok && f.n < MAXF; tok = strtok_r(NULL, "\t", &save)) { char *eq = strchr(tok, '='); if (!eq) continue; *eq = 0; f.k[f.n] = tok; f.v[f.n] = eq + 1; f.n++; } }
    if (!strcmp(cmd, "info")) do_info(&f);
    else if (!strcmp(cmd, "render")) do_render(&f);
    else if (!strcmp(cmd, "unload")) { unload(); printf("ok\tid=%s\n", fget(&f, "id") ? fget(&f, "id") : ""); fflush(stdout); }
    else if (!strcmp(cmd, "ping")) { printf("ok\tid=%s\n", fget(&f, "id") ? fget(&f, "id") : ""); fflush(stdout); }
    else if (!strcmp(cmd, "quit")) break;
    else reply_err(fget(&f, "id"), "unknown command");
  }
  for (int k = 0; k < K_COUNT; k++) if (engines[k].ready && engines[k].fin) engines[k].fin();
  return 0;
}
