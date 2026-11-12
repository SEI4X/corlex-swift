#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "CorlexInternal.h"

#define CORLEX_MAX_FRAMES 100
#define CORLEX_PATH_MAX 1024
#define CORLEX_HEADER_MAX 1024
#define CORLEX_ALT_STACK_BYTES (64 * 1024)

static const int kSignals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
#define CORLEX_SIGNAL_COUNT (int)(sizeof(kSignals) / sizeof(kSignals[0]))

static struct sigaction gPrevious[CORLEX_SIGNAL_COUNT];
static char gPath[CORLEX_PATH_MAX];
static char gHeaderPrefix[CORLEX_HEADER_MAX];
static char gAltStack[CORLEX_ALT_STACK_BYTES];
// A signal may interrupt normal rearm on another thread. Never wait in the handler.
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "crash admission requires always-lock-free int atomics");
enum { CORLEX_DISABLED, CORLEX_EDITING, CORLEX_ARMED, CORLEX_HANDLING, CORLEX_EDIT_CANCELLED };
static atomic_int gState = CORLEX_DISABLED;
static atomic_int gInstalled = 0;

int corlex_crash_prepare_thread_stack(void) {
  // Only main may own this backing storage. Never share one alt stack between live threads.
  if (!pthread_main_np()) return 0;
  stack_t current;
  if (sigaltstack(NULL, &current) != 0) return 0;
  if (!(current.ss_flags & SS_DISABLE)) return 1; // Preserve an enabled host reporter/runtime stack.
  stack_t alt;
  memset(&alt, 0, sizeof(alt));
  alt.ss_sp = gAltStack;
  alt.ss_size = sizeof(gAltStack);
  return sigaltstack(&alt, NULL) == 0;
}

static int index_of(int sig) {
  for (int i = 0; i < CORLEX_SIGNAL_COUNT; i++) {
    if (kSignals[i] == sig) return i;
  }
  return -1;
}

static const char *name_of(int sig) {
  switch (sig) {
    case SIGABRT: return "SIGABRT";
    case SIGSEGV: return "SIGSEGV";
    case SIGBUS: return "SIGBUS";
    case SIGILL: return "SIGILL";
    case SIGFPE: return "SIGFPE";
    case SIGTRAP: return "SIGTRAP";
    default: return "SIGNAL";
  }
}

int corlex_crash_open_report(void) {
  int expected = CORLEX_ARMED;
  if (!atomic_compare_exchange_strong_explicit(&gState, &expected, CORLEX_HANDLING,
                                               memory_order_acquire, memory_order_relaxed)) return -1;
  // HANDLING is terminal: both signal and NSException writers keep these buffers pinned.
  return open(gPath, O_WRONLY | O_CREAT | O_EXCL, 0600);
}

void corlex_crash_write_header(int fd, const char *source, const char *name, const char *message) {
  struct timespec now;
  clock_gettime(CLOCK_REALTIME, &now);
  long long millis = (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
  corlex_put_str(fd, gHeaderPrefix);
  corlex_put_str(fd, "\"source\":\"");
  corlex_put_str(fd, source);
  corlex_put_str(fd, "\",\"name\":\"");
  corlex_put_str(fd, name);
  corlex_put_str(fd, "\",\"message\":\"");
  corlex_put_str(fd, message);
  corlex_put_str(fd, "\",\"timestamp_ms\":");
  corlex_put_int(fd, millis);
  corlex_put_str(fd, "}\n");
}

static void put_uuid(int fd, const uint8_t *uuid) {
  static const char digits[] = "0123456789abcdef";
  char text[36];
  int out = 0;
  for (int i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) text[out++] = '-';
    text[out++] = digits[uuid[i] >> 4];
    text[out++] = digits[uuid[i] & 0xf];
  }
  corlex_put(fd, text, sizeof(text));
}

// One frame: F <TAB> debug_id <TAB> image_addr <TAB> addr <TAB> image [<TAB> function]
static void write_frame(int fd, uintptr_t address, int with_symbols) {
  corlex_image_t image;
  int known = corlex_crash_find_image(address, &image);
  corlex_put_str(fd, "F\t");
  if (known) put_uuid(fd, image.uuid); else corlex_put_str(fd, "-");
  corlex_put_str(fd, "\t");
  corlex_put_hex(fd, known ? image.base : 0);
  corlex_put_str(fd, "\t");
  corlex_put_hex(fd, address);
  corlex_put_str(fd, "\t");
  corlex_put_str(fd, known && image.name[0] != '\0' ? image.name : "-");
  Dl_info info;
  if (with_symbols && dladdr((void *)address, &info) != 0 && info.dli_sname != NULL) {
    corlex_put_str(fd, "\t");
    corlex_put_str(fd, info.dli_sname);
  }
  corlex_put_str(fd, "\n");
}

void corlex_crash_write_frames(int fd, const uintptr_t *addresses, int count, int with_symbols) {
  if (count > CORLEX_MAX_FRAMES) count = CORLEX_MAX_FRAMES;
  for (int i = 0; i < count; i++) write_frame(fd, addresses[i], with_symbols);
}

static void write_signal_report(int sig, void *context) {
  int fd = corlex_crash_open_report();
  if (fd < 0) return;
  char message[40] = "Signal ";
  size_t used = strlen(message);
  if (sig >= 10) message[used++] = (char)('0' + (sig / 10) % 10);
  message[used++] = (char)('0' + sig % 10);
  message[used] = '\0';
  corlex_crash_write_header(fd, "signal", name_of(sig), message);
  uintptr_t frames[CORLEX_MAX_FRAMES];
  int count = corlex_crash_walk_stack(context, frames, CORLEX_MAX_FRAMES);
  corlex_crash_write_frames(fd, frames, count, 0);
  close(fd);
}

static void pass_on(int sig, siginfo_t *info, void *context) {
  int i = index_of(sig);
  struct sigaction previous = gPrevious[i];
  // Put the earlier disposition back first: either it handles the signal, or the default kills us.
  sigaction(sig, &previous, NULL);
  if ((previous.sa_flags & SA_SIGINFO) && previous.sa_sigaction != NULL) {
    previous.sa_sigaction(sig, info, context);
  } else if (previous.sa_handler != SIG_DFL && previous.sa_handler != SIG_IGN &&
             previous.sa_handler != NULL) {
    previous.sa_handler(sig);
  } else {
    // Default action: returning would re-run a faulting instruction, abort() needs the signal again.
    raise(sig);
  }
}

static void handler(int sig, siginfo_t *info, void *context) {
  write_signal_report(sig, context);
  pass_on(sig, info, context);
}

static int finish_install(void) {
  int expected = CORLEX_EDITING;
  if (atomic_compare_exchange_strong_explicit(&gState, &expected, CORLEX_ARMED,
                                              memory_order_release, memory_order_relaxed)) return 1;
  atomic_store_explicit(&gState, CORLEX_DISABLED, memory_order_release);
  return 0;
}

int corlex_crash_install(const char *report_path, const char *header_prefix) {
  if (report_path == NULL || header_prefix == NULL) return 0;
  size_t path_length = strnlen(report_path, sizeof(gPath));
  size_t header_length = strnlen(header_prefix, sizeof(gHeaderPrefix));
  if (path_length >= sizeof(gPath) || header_length >= sizeof(gHeaderPrefix)) return 0;
  int previous = atomic_load_explicit(&gState, memory_order_relaxed);
  if (previous != CORLEX_DISABLED && previous != CORLEX_ARMED) return 0;
  int expected = previous;
  if (!atomic_compare_exchange_strong_explicit(&gState, &expected, CORLEX_EDITING,
                                               memory_order_acquire, memory_order_relaxed)) return 0;
  if (previous == CORLEX_ARMED) {
    int identical = strcmp(gPath, report_path) == 0 && strcmp(gHeaderPrefix, header_prefix) == 0;
    expected = CORLEX_EDITING;
    if (!atomic_compare_exchange_strong_explicit(&gState, &expected, CORLEX_ARMED,
                                                 memory_order_release, memory_order_relaxed)) {
      atomic_store_explicit(&gState, CORLEX_DISABLED, memory_order_release);
      return 0;
    }
    return identical;
  }
  memcpy(gPath, report_path, path_length + 1);
  memcpy(gHeaderPrefix, header_prefix, header_length + 1);
  if (atomic_load_explicit(&gInstalled, memory_order_acquire)) return finish_install();
  corlex_crash_track_images();

  // Wrappers prepare main before dispatching IO here. A worker must never claim its storage.
  if (pthread_main_np()) (void)corlex_crash_prepare_thread_stack();

  struct sigaction action;
  memset(&action, 0, sizeof(action));
  sigemptyset(&action.sa_mask);
  action.sa_sigaction = handler;
  action.sa_flags = SA_SIGINFO | SA_ONSTACK;
  for (int i = 0; i < CORLEX_SIGNAL_COUNT; i++) {
    if (sigaction(kSignals[i], &action, &gPrevious[i]) != 0) {
      atomic_store_explicit(&gState, CORLEX_DISABLED, memory_order_release);
      return 0;
    }
  }
  atomic_store_explicit(&gInstalled, 1, memory_order_release);
  return finish_install();
}

void corlex_crash_set_enabled(int enabled) {
  if (enabled) {
    int expected = CORLEX_DISABLED;
    if (atomic_load_explicit(&gInstalled, memory_order_acquire))
      atomic_compare_exchange_strong_explicit(&gState, &expected, CORLEX_ARMED,
                                              memory_order_acq_rel, memory_order_relaxed);
    return;
  }
  int current = atomic_load_explicit(&gState, memory_order_relaxed);
  while (current == CORLEX_ARMED || current == CORLEX_EDITING) {
    int next = current == CORLEX_EDITING ? CORLEX_EDIT_CANCELLED : CORLEX_DISABLED;
    if (atomic_compare_exchange_weak_explicit(&gState, &current, next,
                                             memory_order_acq_rel, memory_order_relaxed)) return;
  }
}
