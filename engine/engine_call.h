/*
 * engine_call.h - calling SIGMA Photo Pro's sensor engines safely.
 *
 * lib95 (dp Quattro) writes up to 128 bytes above its entry stack pointer although requestProcess
 * takes only 24 bytes of stack-passed arguments (obj, outBufSizeMB, output): those writes land in
 * the caller's own frame. Measured 10 Nov 2026 with a canary-filled scratch area; lib99 (Merrill)
 * writes nothing there. In sppqd it clobbered whatever the compiler kept just above the outgoing
 * arguments: after an unrelated edit that was the "write a TIFF" flag, and 16-bit masters came out
 * as headerless pixel dumps the app could not read (and timings came back as garbage).
 *
 * engine_request() therefore calls requestProcess through a trampoline that gives the engine a
 * 4 KB scratch area holding a copy of the stack arguments, so whatever it writes above them stays
 * in the scratch. The high-water mark of those writes is kept in engine_stack_written.
 */
#ifndef ENGINE_CALL_H
#define ENGINE_CALL_H
#include <stdint.h>

__attribute__((used)) void *volatile engine_call_target;
__attribute__((used)) volatile uint64_t engine_stack_written;

__attribute__((naked, noinline)) static long engine_call_padded(void) {
  __asm__ volatile(
    "stp x29, x30, [sp, #-16]!\n\t"
    "mov x29, sp\n\t"
    "sub sp, sp, #4096\n\t"
    /* canary-fill the scratch above the copied arguments */
    "movz x10, #0xA5A5\n\t" "movk x10, #0xA5A5, lsl #16\n\t" "movk x10, #0xA5A5, lsl #32\n\t" "movk x10, #0xA5A5, lsl #48\n\t"
    "mov x9, #64\n\t"
    "1: str x10, [sp, x9]\n\t" "add x9, x9, #8\n\t" "cmp x9, #4096\n\t" "b.lt 1b\n\t"
    /* copy the caller's stack-passed arguments (64 bytes covers them) to the new stack pointer */
    "ldp x9, x10, [x29, #16]\n\t" "stp x9, x10, [sp, #0]\n\t"
    "ldp x9, x10, [x29, #32]\n\t" "stp x9, x10, [sp, #16]\n\t"
    "ldp x9, x10, [x29, #48]\n\t" "stp x9, x10, [sp, #32]\n\t"
    "ldp x9, x10, [x29, #64]\n\t" "stp x9, x10, [sp, #48]\n\t"
    "adrp x16, _engine_call_target@PAGE\n\t" "ldr x16, [x16, _engine_call_target@PAGEOFF]\n\t"
    "blr x16\n\t"
    /* how far up did the engine write? (x0, the result, is left alone) */
    "movz x10, #0xA5A5\n\t" "movk x10, #0xA5A5, lsl #16\n\t" "movk x10, #0xA5A5, lsl #32\n\t" "movk x10, #0xA5A5, lsl #48\n\t"
    "mov x9, #4088\n\t"
    "2: ldr x11, [sp, x9]\n\t" "cmp x11, x10\n\t" "b.ne 3f\n\t" "sub x9, x9, #8\n\t" "cmp x9, #64\n\t" "b.ge 2b\n\t" "mov x9, #0\n\t" "b 4f\n\t"
    "3: add x9, x9, #8\n\t"
    "4: adrp x16, _engine_stack_written@PAGE\n\t" "str x9, [x16, _engine_stack_written@PAGEOFF]\n\t"
    "mov sp, x29\n\t"
    "ldp x29, x30, [sp], #16\n\t"
    "ret");
}

/* requestProcess(params, loupe, designation, input, getSurface, returnSurface, progress, obj, outMB, output) */
typedef long (*engine_request_fn)(void *, stRECT, uint32_t, const void *, void *, void *, void *, void *, uint16_t, void *);
static inline long engine_request(void *fn, void *params, stRECT loupe, uint32_t desig, const void *input, void *gs, void *rs, void *cb,
                                  void *obj, uint16_t outMB, void *output) {
  engine_call_target = fn;
  return ((engine_request_fn)(void *)engine_call_padded)(params, loupe, desig, input, gs, rs, cb, obj, outMB, output);
}
#endif
