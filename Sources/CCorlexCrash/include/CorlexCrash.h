#ifndef CORLEX_CRASH_H
#define CORLEX_CRASH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One loaded Mach-O image, as the crash reporter sees it.
typedef struct {
  uintptr_t base;    ///< Address of the mach_header: the "image_addr" of a frame.
  uintptr_t end;     ///< End of the __TEXT segment.
  uint8_t uuid[16];  ///< LC_UUID; all zero when the image has none.
  char name[64];     ///< File name of the image, without its directory.
} corlex_image_t;

/// Prepares only main's alternate signal stack, preserving an enabled host stack.
/// Main-thread only (returns 0 on a worker). Does not install handlers, record a path or arm capture.
/// Can run before consent, outside SDK locks, and independently of global handler installation.
int corlex_crash_prepare_thread_stack(void);

/// Installs the fatal-signal handlers. `report_path` is the file one crash is written to,
/// `header_prefix` is the start of the JSON header line (an object text without its closing
/// brace, ending with a comma). Both are copied. Returns 1 on success.
/// After disabling, a bounded new path/header can rearm capture without reinstalling dispositions.
/// An enabled installation accepts only an identical idempotent call; failed updates change nothing.
int corlex_crash_install(const char *report_path, const char *header_prefix);

/// While disabled the handlers write nothing and only pass signals on.
void corlex_crash_set_enabled(int enabled);

/// The image that contains `address`, or 0. Safe to call from a signal handler.
int corlex_crash_find_image(uintptr_t address, corlex_image_t *out);

/// Opens the report file for writing, failing when it exists (one report per launch; the
/// NSException handler wins over the SIGABRT it ends in). Admission permanently pins the
/// current path/header against rearm, including after disable. Returns the descriptor or -1.
int corlex_crash_open_report(void);

/// Writes the header line. `name` and `message` must already be JSON-escaped.
void corlex_crash_write_header(int fd, const char *source, const char *name, const char *message);

/// Writes one line per address. `with_symbols` adds `dladdr` names, which is not
/// async-signal-safe and is therefore only for the NSException path.
void corlex_crash_write_frames(int fd, const uintptr_t *addresses, int count, int with_symbols);

#ifdef __cplusplus
}
#endif

#endif
