/* Print the raw-section layout of a Quattro X3F: plane sizes, data block size, unknown fields —
   to see whether the file carries data beyond the three Huffman planes (highlight pixels?).
   cc -O1 -isysroot $SDK -I../../engine/x3f -o x3fprobe x3fprobe.c ../../engine/x3f/x3f_io.c ../../engine/x3f/x3f_meta.c ../../engine/x3f/x3f_printf.c ../../engine/x3f/x3f_print_meta.c -lz -liconv */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "x3f_io.h"
#include "x3f_meta.h"

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
  x3f_t *x3f = x3f_new_from_file(f); if (!x3f) { fprintf(stderr, "not an X3F\n"); return 1; }
  x3f_directory_entry_t *DE = x3f_get_raw(x3f); if (!DE) { fprintf(stderr, "no raw\n"); return 1; }
  if (x3f_load_data(x3f, DE) != X3F_OK) { fprintf(stderr, "cannot load raw\n"); return 1; }
  x3f_image_data_t *ID = &DE->header.data_subsection.image_data;
  x3f_true_t *TRU = ID->tru; x3f_quattro_t *Q = ID->quattro;
  printf("raw section: input offset %u length %u; type %u format %u; image %ux%u\n", DE->input.offset, DE->input.size, ID->type, ID->format, ID->columns, ID->rows);
  printf("ID->data_size %u\n", ID->data_size);
  if (Q) {
    for (int i = 0; i < 3; i++) printf("  plane %d: %ux%u\n", i, Q->plane[i].columns, Q->plane[i].rows);
    printf("  Q->unknown = %u (0x%x)\n", Q->unknown, Q->unknown);
    if (argc > 2 && Q->top16.data) {   /* write the decoded top plane (uint16, row-major, plane width) */
      char path[512]; snprintf(path, sizeof path, "%s.top16.bin", argv[2]);
      FILE *o = fopen(path, "wb");
      if (o) { fwrite(Q->top16.data, 2, (size_t)Q->top16.columns * Q->top16.rows, o); fclose(o); printf("  top plane written to %s (%ux%u)\n", path, Q->top16.columns, Q->top16.rows); }
    }
    if (argc > 2 && TRU && TRU->x3rgb16.data) {
      char path[512]; snprintf(path, sizeof path, "%s.rg16.bin", argv[2]);
      FILE *o = fopen(path, "wb");
      if (o) { fwrite(TRU->x3rgb16.data, 2, (size_t)TRU->x3rgb16.columns * TRU->x3rgb16.rows * TRU->x3rgb16.channels, o); fclose(o); printf("  bottom planes written to %s (%ux%u x%u)\n", path, TRU->x3rgb16.columns, TRU->x3rgb16.rows, TRU->x3rgb16.channels); }
    }
  }
  if (TRU) {
    printf("  TRU seeds %u %u %u unknown %u\n", TRU->seed[0], TRU->seed[1], TRU->seed[2], TRU->unknown);
    uint32_t sum = 0;
    for (int i = 0; i < 3; i++) { printf("  plane_size[%d] = %u (padded %u)\n", i, TRU->plane_size.element[i], ((TRU->plane_size.element[i] + 15) / 16) * 16); sum += ((TRU->plane_size.element[i] + 15) / 16) * 16; }
    printf("  planes total (padded) %u; data_size - planes = %ld bytes after the planes\n", sum, (long)ID->data_size - (long)sum);
    if (ID->data_size > sum) {
      const unsigned char *p = (const unsigned char *)ID->data + sum;
      printf("  first bytes after the planes:"); for (int i = 0; i < 48 && sum + i < ID->data_size; i++) printf(" %02x", p[i]); printf("\n");
      char path[512]; snprintf(path, sizeof path, "%s.tail.bin", argv[2] ? argv[2] : "/tmp/x3f");
      FILE *o = fopen(path, "wb"); if (o) { fwrite(p, 1, ID->data_size - sum, o); fclose(o); printf("  tail written to %s\n", path); }
    }
  }
  return 0;
}
