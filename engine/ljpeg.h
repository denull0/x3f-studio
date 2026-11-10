#ifndef LJPEG_H
#define LJPEG_H
#include <stdint.h>
#include <stddef.h>
/* Encode interleaved 16-bit samples as a lossless JPEG stream. Caller frees the result. */
uint8_t *ljpeg_encode(const uint16_t *img, uint32_t w, uint32_t h, int ncomp, size_t *outlen);
#endif
