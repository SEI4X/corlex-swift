#ifndef CORLEX_INTERNAL_H
#define CORLEX_INTERNAL_H

#include <stdint.h>

#include "CorlexCrash.h"

/// Starts recording the loaded images (idempotent). Defined in CorlexImages.c.
void corlex_crash_track_images(void);

/// Walks the frame-pointer chain of an interrupted thread. Defined in CorlexStack.c.
/// `context` is the `ucontext_t` a SA_SIGINFO handler receives.
int corlex_crash_walk_stack(void *context, uintptr_t *out, int capacity);

/// Async-signal-safe output helpers. Defined in CorlexOutput.c.
void corlex_put(int fd, const char *s, size_t n);
void corlex_put_str(int fd, const char *s);
void corlex_put_int(int fd, long long value);
void corlex_put_hex(int fd, uint64_t value);

#endif
