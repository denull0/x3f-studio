/*
 * sppcap - records what a host (SIGMA Photo Pro, X3FM Converter, our own sppqd) hands to
 * SPP's sensor engines (lib95 Quattro / lib99 Merrill): the 1008-byte parameter block,
 * designation, loupe rect, the input buffer and the output buffer of every requestProcess.
 *
 *   clang -O2 -dynamiclib -o sppcap.dylib sppcap.c && codesign -fs - sppcap.dylib
 *   SPPCAP_DIR=/tmp/sppcap DYLD_INSERT_LIBRARIES=$PWD/sppcap.dylib <host executable>
 *
 * Works by interposing dlsym(): when the host resolves "initialize"/"requestProcess" from a
 * dylib whose path contains "/Sensor/lib9", it gets our wrappers instead.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/stat.h>
#include <malloc/malloc.h>

typedef struct { int32_t l, t, r, b; } stRECT;
typedef long (*fnRequestProcess)(void *, stRECT, uint32_t, const void *, void *, void *, void *, void *, uint16_t, void *);
typedef long (*fnInitialize)(const char *, void *, const char *);

static fnRequestProcess real_rp;
static fnInitialize real_init;
static int seq = 0;

static const char *capdir(void) {
  static char d[512];
  if (!d[0]) { const char *e = getenv("SPPCAP_DIR"); snprintf(d, sizeof d, "%s", e ? e : "/tmp/sppcap"); mkdir(d, 0755); }
  return d;
}
static void note(const char *fmt, ...) {
  char path[600]; snprintf(path, sizeof path, "%s/log.txt", capdir());
  FILE *f = fopen(path, "a"); if (!f) return;
  va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap); fputc('\n', f); fclose(f);
}
static void dump(const char *name, const void *p, size_t n) {
  if (!p || !n) return;
  char path[600]; snprintf(path, sizeof path, "%s/%03d_%s", capdir(), seq, name);
  FILE *f = fopen(path, "wb"); if (!f) return; fwrite(p, 1, n, f); fclose(f);
}
static size_t cap(size_t n) { return n > (768u << 20) ? (768u << 20) : n; }

static long my_initialize(const char *cert, void *capdata, const char *tmp) {
  char cwd[1024]; if (!getcwd(cwd, sizeof cwd)) strcpy(cwd, "?");
  note("initialize pid=%d cert='%s' tmp='%s' cwd='%s'", getpid(), cert ? cert : "(null)", tmp ? tmp : "(null)", cwd);
  long r = real_init(cert, capdata, tmp);
  note("initialize -> %ld", r);
  return r;
}

static long my_requestProcess(void *P, stRECT loupe, uint32_t desig, const void *input, void *gs, void *rs, void *cb, void *obj, uint16_t outMB, void *out) {
  seq++;
  const uint8_t *p = P;
  dump("params.bin", P, 1008);
  void *camf = NULL, *lens = NULL, *uniq = NULL;
  memcpy(&camf, p + 48, 8); memcpy(&lens, p + 104, 8); memcpy(&uniq, p + 416, 8);
  size_t insz = input ? malloc_size(input) : 0, outsz = out ? malloc_size(out) : 0, camfsz = camf ? malloc_size(camf) : 0, lenssz = lens ? malloc_size(lens) : 0;
  char cwd[1024]; if (!getcwd(cwd, sizeof cwd)) strcpy(cwd, "?");
  note("requestProcess #%d desig=%u loupe=%d,%d,%d,%d outMB=%u obj=%p input=%p(%zu) output=%p(%zu) camf=%p(%zu) lens=%p(%zu) uniq='%s' cwd='%s' w=%u h=%u",
       seq, desig, loupe.l, loupe.t, loupe.r, loupe.b, outMB, obj, input, insz, out, outsz, camf, camfsz, lens, lenssz,
       uniq ? (const char *)uniq : "(null)", cwd, (unsigned)(p[28] | p[29] << 8), (unsigned)(p[30] | p[31] << 8));
  if (insz) dump("input.bin", input, cap(insz));
  if (camfsz) dump("camf.bin", camf, cap(camfsz));
  if (lenssz) dump("lensprof.bin", lens, cap(lenssz));
  else if (lens) dump("lensprof.txt", lens, strnlen((const char *)lens, 1 << 20));
  long r = real_rp(P, loupe, desig, input, gs, rs, cb, obj, outMB, out);
  note("requestProcess #%d -> %ld", seq, r);
  if (outsz) dump("output.bin", out, cap(outsz));
  dump("params_after.bin", P, 1008);
  return r;
}

static int is_sensor_dylib(void *sym) {
  Dl_info di; if (!dladdr(sym, &di) || !di.dli_fname) return 0;
  return strstr(di.dli_fname, "/Sensor/lib9") != NULL || strstr(di.dli_fname, "lib95_") != NULL || strstr(di.dli_fname, "lib99_") != NULL;
}

static void *my_dlsym(void *handle, const char *name) {
  void *p = dlsym(handle, name);
  if (!p || !name) return p;
  if (!strcmp(name, "requestProcess") && is_sensor_dylib(p)) { real_rp = (fnRequestProcess)p; note("hooked requestProcess %p", p); return (void *)my_requestProcess; }
  if (!strcmp(name, "initialize") && is_sensor_dylib(p)) { real_init = (fnInitialize)p; note("hooked initialize %p", p); return (void *)my_initialize; }
  return p;
}

__attribute__((used)) static const struct { const void *replacement; const void *original; }
interposers[] __attribute__((section("__DATA,__interpose"))) = { { (const void *)my_dlsym, (const void *)dlsym } };

__attribute__((constructor)) static void sppcap_loaded(void) {
  char exe[1024]; uint32_t n = sizeof exe; exe[0] = 0;
  extern int _NSGetExecutablePath(char *, uint32_t *); _NSGetExecutablePath(exe, &n);
  note("sppcap loaded into pid %d (%s)", getpid(), exe);
}
