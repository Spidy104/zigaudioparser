#ifndef ZAP_OGG_COMPAT_H
#define ZAP_OGG_COMPAT_H
#include <ogg/os_types.h>
typedef struct {
  long endbyte;
  int endbit;
  unsigned char *buffer;
  unsigned char *ptr;
  long storage;
} oggpack_buffer;
typedef struct {
  unsigned char *packet;
  long bytes;
  long b_o_s;
  long e_o_s;
  ogg_int64_t granulepos;
  ogg_int64_t packetno;
} ogg_packet;
void oggpack_writeinit(oggpack_buffer *b);
int oggpack_writecheck(oggpack_buffer *b);
void oggpack_writetrunc(oggpack_buffer *b, long bits);
void oggpack_writealign(oggpack_buffer *b);
void oggpack_writecopy(oggpack_buffer *b, void *source, long bits);
void oggpack_reset(oggpack_buffer *b);
void oggpack_writeclear(oggpack_buffer *b);
void oggpack_readinit(oggpack_buffer *b, unsigned char *buf, int bytes);
void oggpack_write(oggpack_buffer *b, unsigned long value, int bits);
long oggpack_look(oggpack_buffer *b, int bits);
long oggpack_look1(oggpack_buffer *b);
void oggpack_adv(oggpack_buffer *b, int bits);
void oggpack_adv1(oggpack_buffer *b);
long oggpack_read(oggpack_buffer *b, int bits);
long oggpack_read1(oggpack_buffer *b);
long oggpack_bytes(oggpack_buffer *b);
long oggpack_bits(oggpack_buffer *b);
unsigned char *oggpack_get_buffer(oggpack_buffer *b);
#endif
