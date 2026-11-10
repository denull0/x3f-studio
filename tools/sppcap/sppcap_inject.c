/*
 * sppcap_inject - test harness: replaces the input buffer our sppqd hands to the engine with a
 * buffer captured from SIGMA Photo Pro (same file), so the engine's output can be compared with
 * and without SPP's host-side pixel corrections.
 *
 *   clang -O1 -dynamiclib -o sppcap_inject.dylib sppcap_inject.c
 *   SPPCAP_INJECT=/path/to/NNN_input.bin DYLD_INSERT_LIBRARIES=$PWD/sppcap_inject.dylib sppqd ...
 *
 * Copies min(malloc_size(input), file size, SPPCAP_INJECT_BYTES) bytes over the input before each
 * requestProcess (SPPCAP_INJECT_BYTES defaults to the 6-floats-per-quad Quattro frame size).
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <malloc/malloc.h>

typedef struct { int32_t l, t, r, b; } stRECT;
typedef long (*fnRequestProcess)(void *, stRECT, uint32_t, const void *, void *, void *, void *, void *, uint16_t, void *);
static fnRequestProcess real_rp;

static long my_requestProcess(void *P, stRECT loupe, uint32_t desig, const void *input, void *gs, void *rs, void *cb, void *obj, uint16_t outMB, void *out) {
  const char *path = getenv("SPPCAP_INJECT");
  if (path && input) {
    FILE *f = fopen(path, "rb");
    if (f) {
      size_t have = malloc_size(input);
      size_t want = getenv("SPPCAP_INJECT_BYTES") ? strtoull(getenv("SPPCAP_INJECT_BYTES"), NULL, 10) : (size_t)2712 * 1808 * 6 * 4;
      if (want > have) want = have;
      size_t n = fread((void *)input, 1, want, f);
      fclose(f);
      fprintf(stderr, "sppcap_inject: copied %zu bytes from %s over the engine input (%zu available)\n", n, path, have);
    } else {
      fprintf(stderr, "sppcap_inject: cannot open %s\n", path);
    }
  }
  return real_rp(P, loupe, desig, input, gs, rs, cb, obj, outMB, out);
}

static int is_sensor_dylib(void *sym) {
  Dl_info di; if (!dladdr(sym, &di) || !di.dli_fname) return 0;
  return strstr(di.dli_fname, "/Sensor/lib9") != NULL || strstr(di.dli_fname, "lib95_") != NULL || strstr(di.dli_fname, "lib99_") != NULL;
}

static void *my_dlsym(void *handle, const char *name) {
  void *p = dlsym(handle, name);
  if (p && name && !strcmp(name, "requestProcess") && is_sensor_dylib(p)) { real_rp = (fnRequestProcess)p; return (void *)my_requestProcess; }
  return p;
}

__attribute__((used)) static const struct { const void *replacement; const void *original; }
interposers[] __attribute__((section("__DATA,__interpose"))) = { { (const void *)my_dlsym, (const void *)dlsym } };
