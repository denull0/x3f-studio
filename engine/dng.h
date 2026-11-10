#ifndef DNG_H
#define DNG_H
#include <stdint.h>
#include <time.h>
typedef struct {
  const char *make, *model, *unique_model, *software, *original_name;
  double exposure_time, fnumber, focal_length; int iso, focal_length_35;
  uint32_t rotation;                 /* 0, 90, 180, 270 */
  uint32_t crop_x, crop_y, crop_w, crop_h;
  time_t capture_time;
  int have_unique_id; uint8_t unique_id[16];
} dng_meta_t;
/* romm: 16-bit RGB, ProPhoto primaries, gamma 1.8 (SPP's ProPhoto output). Returns 0 on success. */
int write_dng(const char *path, const dng_meta_t *m, const uint16_t *romm, uint32_t w, uint32_t h);
int write_tiff16(const char *path, const dng_meta_t *m, const uint16_t *srgb16, uint32_t w, uint32_t h);
#endif
