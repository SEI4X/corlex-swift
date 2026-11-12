#include <unistd.h>
#include <string.h>

#include "CorlexInternal.h"

// Everything here uses only write(2) and arithmetic: snprintf and friends are not
// async-signal-safe.

void corlex_put(int fd, const char *s, size_t n) {
  while (n > 0) {
    ssize_t written = write(fd, s, n);
    if (written <= 0) return;
    s += written;
    n -= (size_t)written;
  }
}

void corlex_put_str(int fd, const char *s) { corlex_put(fd, s, strlen(s)); }

void corlex_put_int(int fd, long long value) {
  char buffer[24];
  int i = (int)sizeof(buffer);
  int negative = value < 0;
  unsigned long long u = negative ? (unsigned long long)(-value) : (unsigned long long)value;
  do {
    buffer[--i] = (char)('0' + (u % 10));
    u /= 10;
  } while (u > 0);
  if (negative) buffer[--i] = '-';
  corlex_put(fd, buffer + i, sizeof(buffer) - (size_t)i);
}

void corlex_put_hex(int fd, uint64_t value) {
  static const char digits[] = "0123456789abcdef";
  char buffer[18];
  int i = (int)sizeof(buffer);
  do {
    buffer[--i] = digits[value & 0xf];
    value >>= 4;
  } while (value > 0);
  buffer[--i] = 'x';
  buffer[--i] = '0';
  corlex_put(fd, buffer + i, sizeof(buffer) - (size_t)i);
}
