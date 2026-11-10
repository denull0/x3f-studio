/* Lossless JPEG (ITU T.81 process 14, SOF3) encoder for 16-bit, 3-component
 * interleaved data, as used by DNG (Compression = 7). Predictor 1, point
 * transform 0, one optimal Huffman table built per image (Annex K.2). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "ljpeg.h"

typedef struct { uint8_t *buf; size_t len, cap; uint32_t acc; int nbits; } bw_t;
static void bw_put8(bw_t *b, uint8_t v) {
  if (b->len + 2 > b->cap) { b->cap = b->cap ? b->cap * 2 : 1 << 20; b->buf = realloc(b->buf, b->cap); }
  b->buf[b->len++] = v; if (v == 0xff) b->buf[b->len++] = 0;   /* byte stuffing */
}
static void bw_bits(bw_t *b, uint32_t code, int n) {
  b->acc = (b->acc << n) | (code & ((1u << n) - 1)); b->nbits += n;
  while (b->nbits >= 8) { bw_put8(b, (uint8_t)(b->acc >> (b->nbits - 8))); b->nbits -= 8; }
}
static void bw_flush(bw_t *b) { if (b->nbits) { bw_bits(b, 0x7f, 8 - b->nbits); } }

static inline int category(int32_t d) { int s = 0; uint32_t a = d < 0 ? -d : d; while (a) { s++; a >>= 1; } return s; }

/* Annex K.2: code lengths from frequencies, limited to 16 bits. */
static void build_table(const uint64_t freq_in[17], uint8_t bits[17], uint8_t vals[17], int *nvals) {
  uint64_t freq[257] = {0}; int codesize[257] = {0}, others[257];
  for (int i = 0; i < 17; i++) freq[i] = freq_in[i];
  freq[256] = 1;                                  /* reserved symbol: no all-ones code */
  for (int i = 0; i < 257; i++) others[i] = -1;
  for (;;) {
    int v1 = -1, v2 = -1; uint64_t m1 = ~0ull, m2 = ~0ull;
    for (int i = 0; i < 257; i++) if (freq[i] && freq[i] <= m1) { m1 = freq[i]; v1 = i; }
    for (int i = 0; i < 257; i++) if (freq[i] && freq[i] <= m2 && i != v1) { m2 = freq[i]; v2 = i; }
    if (v2 < 0) break;
    freq[v1] += freq[v2]; freq[v2] = 0;
    codesize[v1]++; while (others[v1] >= 0) { v1 = others[v1]; codesize[v1]++; }
    others[v1] = v2;
    codesize[v2]++; while (others[v2] >= 0) { v2 = others[v2]; codesize[v2]++; }
  }
  int blcount[40] = {0};
  for (int i = 0; i < 257; i++) if (codesize[i]) blcount[codesize[i]]++;
  for (int i = 32; i > 16; i--) {               /* limit code lengths to 16 */
    while (blcount[i] > 0) {
      int j = i - 2; while (blcount[j] == 0) j--;
      blcount[i] -= 2; blcount[i - 1]++; blcount[j + 1] += 2; blcount[j]--;
    }
  }
  int i = 16; while (blcount[i] == 0) i--; blcount[i]--;   /* remove the reserved symbol */
  memset(bits, 0, 17); for (int k = 1; k <= 16; k++) bits[k] = (uint8_t)blcount[k];
  int n = 0;                                      /* symbols sorted by code length (then value) */
  for (int len = 1; len <= 32; len++) for (int s = 0; s < 17; s++) if (codesize[s] == len) vals[n++] = (uint8_t)s;
  *nvals = n;
}

uint8_t *ljpeg_encode(const uint16_t *img, uint32_t w, uint32_t h, int ncomp, size_t *outlen) {
  /* pass 1: statistics */
  uint64_t freq[17] = {0};
  size_t rowlen = (size_t)w * ncomp;
  for (uint32_t y = 0; y < h; y++) {
    const uint16_t *row = img + y * rowlen, *up = y ? row - rowlen : NULL;
    for (uint32_t x = 0; x < w; x++) for (int c = 0; c < ncomp; c++) {
      int pred = x ? row[(x - 1) * ncomp + c] : (y ? up[c] : 32768);
      int32_t d = (int32_t)row[x * ncomp + c] - pred; d = (int16_t)d;
      freq[category(d)]++;
    }
  }
  uint8_t bits[17], vals[17]; int nvals;
  build_table(freq, bits, vals, &nvals);
  uint16_t code[17]; uint8_t clen[17] = {0};     /* canonical codes */
  { int k = 0; uint16_t c = 0; for (int len = 1; len <= 16; len++) { for (int i = 0; i < bits[len]; i++) { code[vals[k]] = c; clen[vals[k]] = (uint8_t)len; c++; k++; } c <<= 1; } }

  bw_t b = {0};
  #define RAW8(v) do { if (b.len + 1 > b.cap) { b.cap = b.cap ? b.cap * 2 : 1 << 20; b.buf = realloc(b.buf, b.cap); } b.buf[b.len++] = (uint8_t)(v); } while (0)
  #define RAW16(v) do { RAW8((v) >> 8); RAW8((v) & 255); } while (0)
  RAW8(0xff); RAW8(0xd8);                           /* SOI */
  RAW8(0xff); RAW8(0xc4); RAW16(2 + 1 + 16 + nvals); RAW8(0x00);   /* DHT, table 0 */
  for (int k = 1; k <= 16; k++) RAW8(bits[k]);
  for (int k = 0; k < nvals; k++) RAW8(vals[k]);
  RAW8(0xff); RAW8(0xc3); RAW16(8 + 3 * ncomp); RAW8(16); RAW16(h); RAW16(w); RAW8(ncomp);   /* SOF3 */
  for (int c = 0; c < ncomp; c++) { RAW8(c + 1); RAW8(0x11); RAW8(0); }
  RAW8(0xff); RAW8(0xda); RAW16(6 + 2 * ncomp); RAW8(ncomp);     /* SOS */
  for (int c = 0; c < ncomp; c++) { RAW8(c + 1); RAW8(0x00); }
  RAW8(1); RAW8(0); RAW8(0);                      /* predictor 1, Se 0, Ah/Al 0 */
  /* pass 2: entropy-coded data */
  for (uint32_t y = 0; y < h; y++) {
    const uint16_t *row = img + y * rowlen, *up = y ? row - rowlen : NULL;
    for (uint32_t x = 0; x < w; x++) for (int c = 0; c < ncomp; c++) {
      int pred = x ? row[(x - 1) * ncomp + c] : (y ? up[c] : 32768);
      int32_t d = (int32_t)row[x * ncomp + c] - pred; d = (int16_t)d;
      int s = category(d);
      bw_bits(&b, code[s], clen[s]);
      if (s && s < 16) bw_bits(&b, (uint32_t)(d < 0 ? d - 1 : d), s);
    }
  }
  bw_flush(&b);
  RAW8(0xff); RAW8(0xd9);                           /* EOI */
  *outlen = b.len;
  return b.buf;
}
