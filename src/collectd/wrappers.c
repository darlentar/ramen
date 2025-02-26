// vim: ft=c bs=2 ts=2 sts=2 sw=2 expandtab
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <inttypes.h>
#include <string.h>

#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/callback.h>

#include "collectd.h"

#define STR_(s) STR(s)
#define STR(s) #s

static void set_nullable_string(value block, unsigned idx, char const *str)
{
  CAMLparam1(block);
  CAMLlocal1(tmp);
  if (!str || str[0] == '\0')
    Store_field(block, idx, Val_int(0));
  else {
    tmp = caml_alloc(1, 0);
    Store_field(tmp, 0, caml_copy_string(str));
    Store_field(block, idx, tmp);
  }
  CAMLreturn0;
}

CAMLprim value wrap_collectd_decode(value buffer_, value num_bytes_)
{
  CAMLparam2(buffer_, num_bytes_);
  CAMLlocal3(res, m_tup, tmp);
  unsigned num_bytes = Long_val(num_bytes_);
  assert(caml_string_length(buffer_) >= num_bytes);

  unsigned num_metrics;
  struct collectd_metric *metrics; // Will point into mem
  char mem[4096];
  // Must not call caml_alloc from there until we are done with buffer
  char *buffer = String_val(buffer_);
  enum collectd_decode_status status =
    collectd_decode(num_bytes, buffer, sizeof(mem), mem, &num_metrics, &metrics);

  // Return an array of collectd_metric:
  res = caml_alloc(num_metrics, 0);

  //printf("collectd_decode: collected %u metrics\n", num_metrics);
  for (unsigned i = 0; i < num_metrics; i++) {
    struct collectd_metric *m = metrics + i;
    assert(m->num_values > 0);
    m_tup = caml_alloc(6 + COLLECTD_NB_VALUES, 0);
    Store_field(m_tup, 0, caml_copy_string(m->host));
    Store_field(m_tup, 1, caml_copy_double(m->time));
    set_nullable_string(m_tup, 2, m->plugin_name);
    set_nullable_string(m_tup, 3, m->plugin_instance);
    set_nullable_string(m_tup, 4, m->type_name);
    set_nullable_string(m_tup, 5, m->type_instance);
    Store_field(m_tup, 6+0, caml_copy_double(m->values[0]));
    unsigned v;
    for (v = 1; v < m->num_values; v++) {
      tmp = caml_alloc(1, 0);
      Store_field(tmp, 0, caml_copy_double(m->values[v]));
      Store_field(m_tup, 6+v, tmp);
    }
    for (; v < COLLECTD_NB_VALUES; v++) {
      Store_field(m_tup, 6+v, Val_int(0)); // None
    }
    Store_field(res, i, m_tup);
  }

  switch (status) {
    case COLLECTD_OK:
      break;
    case COLLECTD_SHORT_DATA:
      fprintf(stderr, "collectd_decode: short data!\n");
      break;
    case COLLECTD_NOT_ENOUGH_RAM:
      fprintf(stderr, "collectd_decode: not enough RAM!\n");
      break;
    case COLLECTD_PARSE_ERROR:
      fprintf(stderr, "collectd_decode: parse error!\n");
      break;
  }

  CAMLreturn(res);
}
