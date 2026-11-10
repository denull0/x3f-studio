/* Dump CAMF matrices of an X3F by name: dimensions, type and the first values.
   cc -O1 -isysroot $SDK -I../../engine/x3f -o camfdump camfdump.c ../../engine/x3f/x3f_io.c ../../engine/x3f/x3f_meta.c ../../engine/x3f/x3f_printf.c ../../engine/x3f/x3f_print_meta.c -lz
   camfdump file.X3F Name [Name ...]      (Name "list" prints every CAMF entry name) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "x3f_io.h"
#include "x3f_meta.h"

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: camfdump file.X3F Name...\n"); return 2; }
  FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
  x3f_t *x3f = x3f_new_from_file(f); if (!x3f) { fprintf(stderr, "not an X3F\n"); return 1; }
  if (x3f_load_data(x3f, x3f_get_camf(x3f)) != X3F_OK) { fprintf(stderr, "cannot load CAMF\n"); return 1; }
  for (int a = 2; a < argc; a++) {
    if (!strcmp(argv[a], "list")) {
      x3f_directory_entry_t *de = x3f_get_camf(x3f);
      x3f_camf_t *camf = &de->header.data_subsection.camf;
      for (uint32_t i = 0; i < camf->entry_table.size; i++) {
        camf_entry_t *e = &camf->entry_table.element[i];
        printf("%-40s id=%08x", e->name_address, e->id);
        if (e->id == X3F_CMbM) printf("  matrix dims=%u", e->matrix_dim);
        for (uint32_t d = 0; e->id == X3F_CMbM && d < e->matrix_dim; d++) printf(" [%s=%u]", e->matrix_dim_entry[d].name, e->matrix_dim_entry[d].size);
        printf("\n");
      }
      continue;
    }
    uint32_t dim = 0, dims[3] = {0, 0, 0}; char *dimnames[3] = {0, 0, 0}; void *data = NULL; matrix_type_t type;
    x3f_directory_entry_t *de = x3f_get_camf(x3f);
    x3f_camf_t *camf = &de->header.data_subsection.camf;
    camf_entry_t *e = NULL;
    for (uint32_t i = 0; i < camf->entry_table.size; i++) if (!strcmp(camf->entry_table.element[i].name_address, argv[a])) e = &camf->entry_table.element[i];
    if (!e) { printf("%s: not found\n", argv[a]); continue; }
    if (e->id != X3F_CMbM) { printf("%s: not a matrix (id %08x)\n", argv[a], e->id); continue; }
    dim = e->matrix_dim; type = e->matrix_decoded_type; data = e->matrix_decoded;
    size_t total = 1;
    if (getenv("CAMFDUMP_OUT")) {   /* also write the decoded array (4 bytes per element) to <dir>/<Name>.bin */
      size_t cnt = 1; for (uint32_t d = 0; d < dim; d++) cnt *= e->matrix_dim_entry[d].size;
      char path[1024]; snprintf(path, sizeof path, "%s/%s.bin", getenv("CAMFDUMP_OUT"), argv[a]);
      FILE *o = fopen(path, "wb"); if (o) { fwrite(data, type == M_FLOAT ? 8 : 4, cnt, o); fclose(o); }
    }
    printf("%s: type=%d dims=%u", argv[a], (int)type, dim);
    for (uint32_t d = 0; d < dim; d++) { dims[d] = e->matrix_dim_entry[d].size; dimnames[d] = e->matrix_dim_entry[d].name; total *= dims[d]; printf(" [%s=%u]", dimnames[d], dims[d]); }
    printf("  total=%zu\n  ", total);
    size_t show = total < 48 ? total : 48;
    for (size_t i = 0; i < show; i++) {
      if (type == M_FLOAT) printf("%g ", ((double *)data)[i]);
      else if (type == M_INT) printf("%d ", ((int32_t *)data)[i]);
      else printf("%u ", ((uint32_t *)data)[i]);
    }
    printf("%s\n", total > show ? "…" : "");
    (void)dims; (void)dimnames;
  }
  return 0;
}
