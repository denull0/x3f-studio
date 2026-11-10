/*
 * Minimal DNG writer for SPP-rendered images.
 *
 * Input: 16-bit RGB in ROMM/ProPhoto encoding (gamma 1.8, D50), straight from
 * SIGMA Photo Pro's engine. Output: a LinearRaw DNG holding the linearised
 * ProPhoto data, with an exact ColorMatrix/ForwardMatrix for that space and an
 * embedded camera profile whose tone curve is linear, so a DNG reader that
 * honours embedded profiles (Camera Raw, Lightroom) shows SPP's rendering as
 * the starting point while keeping every raw control.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <time.h>
#include "dng.h"
#include "ljpeg.h"

/* ---- tiny TIFF builder ---- */
typedef struct { uint16_t tag, type; uint32_t count; uint8_t *data; uint32_t size; } entry_t;
typedef struct { entry_t e[64]; int n; } ifd_t;

enum { T_BYTE = 1, T_ASCII = 2, T_SHORT = 3, T_LONG = 4, T_RATIONAL = 5, T_SBYTE = 6, T_UNDEF = 7, T_SSHORT = 8, T_SLONG = 9, T_SRATIONAL = 10, T_FLOAT = 11, T_DOUBLE = 12 };
static const int tsize[] = { 0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8 };

static void add(ifd_t *i, uint16_t tag, uint16_t type, uint32_t count, const void *data) {
  entry_t *e = &i->e[i->n++];
  e->tag = tag; e->type = type; e->count = count; e->size = count * tsize[type];
  e->data = malloc(e->size ? e->size : 1); memcpy(e->data, data, e->size);
}
static void add_short(ifd_t *i, uint16_t tag, uint16_t v) { add(i, tag, T_SHORT, 1, &v); }
static void add_long(ifd_t *i, uint16_t tag, uint32_t v) { add(i, tag, T_LONG, 1, &v); }
static void add_ascii(ifd_t *i, uint16_t tag, const char *s) { add(i, tag, T_ASCII, (uint32_t)strlen(s) + 1, s); }
static void add_rat(ifd_t *i, uint16_t tag, uint32_t n, uint32_t d) { uint32_t v[2] = { n, d }; add(i, tag, T_RATIONAL, 1, v); }
static void add_srat(ifd_t *i, uint16_t tag, int32_t n, int32_t d) { int32_t v[2] = { n, d }; add(i, tag, T_SRATIONAL, 1, v); }
static void add_srats(ifd_t *i, uint16_t tag, int cnt, const double *v, int32_t den) {
  int32_t *b = malloc(cnt * 8); for (int k = 0; k < cnt; k++) { b[2 * k] = (int32_t)lround(v[k] * den); b[2 * k + 1] = den; }
  add(i, tag, T_SRATIONAL, cnt, b); free(b);
}
static int cmp_entry(const void *a, const void *b) { return (int)((const entry_t *)a)->tag - (int)((const entry_t *)b)->tag; }

/* write an IFD at the current position; large values go after the IFD. Returns the IFD offset. */
static uint32_t write_ifd(FILE *f, ifd_t *i, uint32_t next_ifd) {
  qsort(i->e, i->n, sizeof(entry_t), cmp_entry);
  uint32_t start = (uint32_t)ftell(f);
  uint32_t tail = start + 2 + i->n * 12 + 4;
  uint16_t n = (uint16_t)i->n; fwrite(&n, 2, 1, f);
  uint32_t extra = tail;
  for (int k = 0; k < i->n; k++) {
    entry_t *e = &i->e[k];
    fwrite(&e->tag, 2, 1, f); fwrite(&e->type, 2, 1, f); fwrite(&e->count, 4, 1, f);
    if (e->size <= 4) { uint8_t pad[4] = {0}; memcpy(pad, e->data, e->size); fwrite(pad, 4, 1, f); }
    else { fwrite(&extra, 4, 1, f); extra += (e->size + 1) & ~1u; }
  }
  fwrite(&next_ifd, 4, 1, f);
  for (int k = 0; k < i->n; k++) {
    entry_t *e = &i->e[k];
    if (e->size > 4) { fwrite(e->data, 1, e->size, f); if (e->size & 1) fputc(0, f); }
    free(e->data);
  }
  return start;
}

/* ProPhoto (ROMM) primaries, D50 */
static const double M_pp2xyz[9] = { 0.7976749, 0.1351917, 0.0313534, 0.2880402, 0.7118741, 0.0000857, 0.0, 0.0, 0.8252100 };
static const double M_xyz2pp[9] = { 1.3459433, -0.2556075, -0.0511118, -0.5445989, 1.5081673, 0.0205351, 0.0, 0.0, 1.2118128 };
/* ProPhoto linear (D50) -> sRGB linear (D65), Bradford */
static const double M_pp2srgb[9] = { 2.0341920, -0.7274210, -0.3067710, -0.2288204, 1.2317200, -0.0028996, -0.0085279, -0.1530414, 1.1615693 };

int write_dng(const char *path, const dng_meta_t *m, const uint16_t *romm, uint32_t w, uint32_t h) {
  FILE *f = fopen(path, "wb");
  if (!f) { perror(path); return -1; }

  /* --- linearise: ROMM gamma 1.8 -> linear, via a LUT --- */
  static uint16_t lut[65536]; static int lut_ready = 0;
  if (!lut_ready) { for (int v = 0; v < 65536; v++) lut[v] = (uint16_t)lround(pow(v / 65535.0, 1.8) * 65535.0); lut_ready = 1; }
  size_t npx = (size_t)w * h;
  uint16_t *lin = malloc(npx * 6);
  if (!lin) { fclose(f); return -1; }
  for (size_t k = 0; k < npx * 3; k++) lin[k] = lut[romm[k]];

  /* --- thumbnail: 1/16 size, sRGB 8-bit --- */
  int tw = w / 16, th = h / 16;
  uint8_t *thumb = malloc((size_t)tw * th * 3);
  for (int y = 0; y < th; y++) for (int x = 0; x < tw; x++) {
    double acc[3] = {0, 0, 0};
    for (int dy = 0; dy < 16; dy += 4) for (int dx = 0; dx < 16; dx += 4) for (int c = 0; c < 3; c++)
      acc[c] += lin[((size_t)(y * 16 + dy) * w + (x * 16 + dx)) * 3 + c] / 65535.0;
    for (int c = 0; c < 3; c++) acc[c] /= 16.0;
    for (int c = 0; c < 3; c++) {
      double v = M_pp2srgb[c * 3] * acc[0] + M_pp2srgb[c * 3 + 1] * acc[1] + M_pp2srgb[c * 3 + 2] * acc[2];
      v = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v < 0 ? 0 : v, 1 / 2.4) - 0.055;
      int iv = (int)lround(v * 255); thumb[((size_t)y * tw + x) * 3 + c] = (uint8_t)(iv < 0 ? 0 : iv > 255 ? 255 : iv);
    }
  }

  /* --- header --- */
  uint8_t hdr[8] = { 'I', 'I', 42, 0, 8, 0, 0, 0 };
  fwrite(hdr, 1, 8, f);

  /* layout: [header][IFD0 placeholder written last? no: we write data blobs first, then IFDs] */
  /* write pixel data first so offsets are known */
  fseek(f, 8, SEEK_SET);
  uint32_t thumb_off = 8;
  fwrite(thumb, 1, (size_t)tw * th * 3, f);
  if (ftell(f) & 1) fputc(0, f);
  uint32_t raw_off = (uint32_t)ftell(f);
  size_t raw_len; int compression = 7;
  uint8_t *lj = getenv("SPPQ_UNCOMPRESSED") ? NULL : ljpeg_encode(lin, w, h, 3, &raw_len);
  if (lj) { fwrite(lj, 1, raw_len, f); free(lj); }
  else { compression = 1; raw_len = npx * 6; fwrite(lin, 2, npx * 3, f); }
  if (ftell(f) & 1) fputc(0, f);

  char datetime[32];
  { time_t t = m->capture_time ? m->capture_time : time(NULL); struct tm *tmv = localtime(&t);
    strftime(datetime, sizeof datetime, "%Y:%m:%d %H:%M:%S", tmv); }
  uint16_t orient = m->rotation == 90 ? 6 : m->rotation == 180 ? 3 : m->rotation == 270 ? 8 : 1;

  /* --- raw SubIFD --- */
  ifd_t raw = { .n = 0 };
  add_long(&raw, 254, 0);
  add_long(&raw, 256, w); add_long(&raw, 257, h);
  { uint16_t bps[3] = {16, 16, 16}; add(&raw, 258, T_SHORT, 3, bps); }
  add_short(&raw, 259, (uint16_t)compression);
  add_short(&raw, 262, 34892);              /* LinearRaw */
  add_long(&raw, 273, raw_off);
  add_short(&raw, 277, 3);
  add_long(&raw, 278, h);
  add_long(&raw, 279, (uint32_t)raw_len);
  add_short(&raw, 284, 1);
  { uint16_t wl[3] = {65535, 65535, 65535}; add(&raw, 50717, T_SHORT, 3, wl); }
  if (m->crop_w && m->crop_h) {
    uint32_t o[2] = { m->crop_x, m->crop_y }, s[2] = { m->crop_w, m->crop_h };
    add(&raw, 50719, T_LONG, 2, o); add(&raw, 50720, T_LONG, 2, s);
  }

  /* --- EXIF IFD --- */
  ifd_t exif = { .n = 0 };
  if (m->exposure_time > 0) add_rat(&exif, 33434, (uint32_t)lround(m->exposure_time * 1000000), 1000000);
  if (m->fnumber > 0) add_rat(&exif, 33437, (uint32_t)lround(m->fnumber * 10), 10);
  if (m->iso > 0) add_short(&exif, 34855, (uint16_t)m->iso);
  { uint8_t ev[4] = {'0', '2', '3', '0'}; add(&exif, 36864, T_UNDEF, 4, ev); }
  add_ascii(&exif, 36867, datetime); add_ascii(&exif, 36868, datetime);
  if (m->focal_length > 0) add_rat(&exif, 37386, (uint32_t)lround(m->focal_length * 10), 10);
  if (m->focal_length_35 > 0) add_short(&exif, 41989, (uint16_t)m->focal_length_35);
  add_long(&exif, 40962, w); add_long(&exif, 40963, h);

  /* --- IFD0 (thumbnail + DNG metadata) --- */
  ifd_t ifd0 = { .n = 0 };
  add_long(&ifd0, 254, 1);
  add_long(&ifd0, 256, tw); add_long(&ifd0, 257, th);
  { uint16_t bps[3] = {8, 8, 8}; add(&ifd0, 258, T_SHORT, 3, bps); }
  add_short(&ifd0, 259, 1);
  add_short(&ifd0, 262, 2);
  add_ascii(&ifd0, 271, m->make); add_ascii(&ifd0, 272, m->model);
  add_long(&ifd0, 273, thumb_off);
  add_short(&ifd0, 274, orient);
  add_short(&ifd0, 277, 3);
  add_long(&ifd0, 278, th);
  add_long(&ifd0, 279, (uint32_t)tw * th * 3);
  add_short(&ifd0, 284, 1);
  add_ascii(&ifd0, 305, m->software);
  add_ascii(&ifd0, 306, datetime);
  /* SubIFDs and ExifIFD offsets are patched after writing */
  uint32_t zero = 0; add_long(&ifd0, 330, zero); add_long(&ifd0, 34665, zero);
  { uint8_t v[4] = {1, 4, 0, 0}; add(&ifd0, 50706, T_BYTE, 4, v); }
  { uint8_t v[4] = {1, 1, 0, 0}; add(&ifd0, 50707, T_BYTE, 4, v); }
  add_ascii(&ifd0, 50708, m->unique_model);
  add_srats(&ifd0, 50721, 9, M_xyz2pp, 10000);       /* ColorMatrix1: XYZ(D50) -> camera (ProPhoto) */
  { uint32_t n3[6] = {1, 1, 1, 1, 1, 1}; add(&ifd0, 50728, T_RATIONAL, 3, n3); }  /* AsShotNeutral */
  add_srat(&ifd0, 50730, 0, 100);                     /* BaselineExposure */
  add_short(&ifd0, 50778, 23);                        /* CalibrationIlluminant1: D50 */
  add_ascii(&ifd0, 50827, m->original_name);          /* OriginalRawFileName */
  add_ascii(&ifd0, 50936, "SIGMA Photo Pro rendering (linear)");
  { float tc[4] = {0, 0, 1, 1}; add(&ifd0, 50940, T_FLOAT, 4, tc); }   /* ProfileToneCurve: linear */
  add_long(&ifd0, 50941, 0);                          /* ProfileEmbedPolicy: allow copying */
  add_srats(&ifd0, 50964, 9, M_pp2xyz, 10000);        /* ForwardMatrix1: camera -> XYZ(D50) */
  if (m->have_unique_id) add(&ifd0, 50781, T_BYTE, 16, m->unique_id);   /* RawDataUniqueID */

  /* write raw IFD and exif IFD, then IFD0, then patch the header pointer */
  uint32_t raw_ifd_off = write_ifd(f, &raw, 0);
  uint32_t exif_ifd_off = write_ifd(f, &exif, 0);
  for (int k = 0; k < ifd0.n; k++) {
    if (ifd0.e[k].tag == 330) memcpy(ifd0.e[k].data, &raw_ifd_off, 4);
    if (ifd0.e[k].tag == 34665) memcpy(ifd0.e[k].data, &exif_ifd_off, 4);
  }
  uint32_t ifd0_off = write_ifd(f, &ifd0, 0);
  fseek(f, 4, SEEK_SET); fwrite(&ifd0_off, 4, 1, f);
  fclose(f);
  free(lin); free(thumb);
  return 0;
}

/* 16-bit sRGB TIFF (data straight from SPP's sRGB output), with a thumbnail IFD first is not needed: single IFD */
int write_tiff16(const char *path, const dng_meta_t *m, const uint16_t *srgb16, uint32_t w, uint32_t h) {
  FILE *f = fopen(path, "wb");
  if (!f) { perror(path); return -1; }
  uint8_t hdr[8] = { 'I', 'I', 42, 0, 8, 0, 0, 0 };
  fwrite(hdr, 1, 8, f);
  size_t npx = (size_t)w * h;
  uint32_t data_off = 8;
  fwrite(srgb16, 2, npx * 3, f);
  char datetime[32];
  { time_t t = m->capture_time ? m->capture_time : time(NULL); struct tm *tmv = localtime(&t); strftime(datetime, sizeof datetime, "%Y:%m:%d %H:%M:%S", tmv); }
  uint16_t orient = m->rotation == 90 ? 6 : m->rotation == 180 ? 3 : m->rotation == 270 ? 8 : 1;
  ifd_t exif = { .n = 0 };
  if (m->exposure_time > 0) add_rat(&exif, 33434, (uint32_t)lround(m->exposure_time * 1000000), 1000000);
  if (m->fnumber > 0) add_rat(&exif, 33437, (uint32_t)lround(m->fnumber * 10), 10);
  if (m->iso > 0) add_short(&exif, 34855, (uint16_t)m->iso);
  { uint8_t ev[4] = {'0', '2', '3', '0'}; add(&exif, 36864, T_UNDEF, 4, ev); }
  add_ascii(&exif, 36867, datetime); add_ascii(&exif, 36868, datetime);
  if (m->focal_length > 0) add_rat(&exif, 37386, (uint32_t)lround(m->focal_length * 10), 10);
  if (m->focal_length_35 > 0) add_short(&exif, 41989, (uint16_t)m->focal_length_35);
  add_short(&exif, 40961, 1);   /* ColorSpace sRGB */
  add_long(&exif, 40962, w); add_long(&exif, 40963, h);
  uint32_t exif_off = write_ifd(f, &exif, 0);
  ifd_t i0 = { .n = 0 };
  add_long(&i0, 254, 0); add_long(&i0, 256, w); add_long(&i0, 257, h);
  { uint16_t bps[3] = {16, 16, 16}; add(&i0, 258, T_SHORT, 3, bps); }
  add_short(&i0, 259, 1); add_short(&i0, 262, 2);
  add_ascii(&i0, 271, m->make); add_ascii(&i0, 272, m->model);
  add_long(&i0, 273, data_off); add_short(&i0, 274, orient); add_short(&i0, 277, 3);
  add_long(&i0, 278, h); add_long(&i0, 279, (uint32_t)(npx * 6)); add_short(&i0, 284, 1);
  add_ascii(&i0, 305, m->software); add_ascii(&i0, 306, datetime);
  add_long(&i0, 34665, exif_off);
  uint32_t ifd0_off = write_ifd(f, &i0, 0);
  fseek(f, 4, SEEK_SET); fwrite(&ifd0_off, 4, 1, f);
  fclose(f);
  return 0;
}
