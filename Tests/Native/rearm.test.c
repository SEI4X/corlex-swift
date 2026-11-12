// Exercise the real core under sanitizers through normal functions, never raise a signal.
#include "CorlexCrash.c"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>

static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static int admitted, released;
static void *capture(void *unused) {
  (void)unused;
  int fd = corlex_crash_open_report(); assert(fd >= 0);
  pthread_mutex_lock(&mutex);
  admitted = 1; pthread_cond_signal(&condition);
  while (!released) pthread_cond_wait(&condition, &mutex);
  pthread_mutex_unlock(&mutex);
  corlex_crash_write_header(fd, "test", "NativeError", "Error details omitted");
  close(fd);
  return NULL;
}

int main(void) {
  char folder[] = "/tmp/corlex-rearm-test.XXXXXX";
  assert(mkdtemp(folder));
  char first[1024], second[1024];
  snprintf(first, sizeof(first), "%s/A.corlex", folder);
  snprintf(second, sizeof(second), "%s/B.corlex", folder);
  const char *headerA = "{\"scope\":\"A\",";
  const char *headerB = "{\"scope\":\"B\",";
  assert(corlex_crash_install(first, headerA) == 1);
  struct sigaction before, after;
  assert(sigaction(SIGABRT, NULL, &before) == 0);
  struct sigaction previous[CORLEX_SIGNAL_COUNT];
  memcpy(previous, gPrevious, sizeof(previous));
  assert(corlex_crash_install(first, headerA) == 1); // idempotent only
  assert(corlex_crash_install(second, headerB) == 0); // enabled state cannot be retargeted
  assert(strcmp(gPath, first) == 0 && strcmp(gHeaderPrefix, headerA) == 0);
  corlex_crash_set_enabled(0);
  assert(corlex_crash_open_report() < 0);
  char oversized[1025];
  memset(oversized, 'x', sizeof(oversized) - 1); oversized[sizeof(oversized) - 1] = '\0';
  assert(corlex_crash_install(oversized, headerB) == 0);
  assert(corlex_crash_install(second, oversized) == 0);
  assert(corlex_crash_install(NULL, headerB) == 0);
  assert(corlex_crash_install(second, NULL) == 0);
  assert(strcmp(gPath, first) == 0 && strcmp(gHeaderPrefix, headerA) == 0);
  // Deterministically interrupt normal-context editing with withdrawal.
  int expected = CORLEX_DISABLED;
  assert(atomic_compare_exchange_strong(&gState, &expected, CORLEX_EDITING));
  corlex_crash_set_enabled(0);
  assert(atomic_load(&gState) == CORLEX_EDIT_CANCELLED);
  assert(finish_install() == 0);
  assert(atomic_load(&gState) == CORLEX_DISABLED);
  assert(strcmp(gPath, first) == 0 && strcmp(gHeaderPrefix, headerA) == 0);
  assert(corlex_crash_install(second, headerB) == 1);
  assert(sigaction(SIGABRT, NULL, &after) == 0);
  assert(before.sa_sigaction == after.sa_sigaction && before.sa_flags == after.sa_flags);
  assert(memcmp(previous, gPrevious, sizeof(previous)) == 0);
  // Admission pins the buffers even if normal code disables capture afterwards.
  pthread_t writer;
  pthread_mutex_lock(&mutex);
  assert(pthread_create(&writer, NULL, capture, NULL) == 0);
  while (!admitted) pthread_cond_wait(&condition, &mutex);
  pthread_mutex_unlock(&mutex);
  corlex_crash_set_enabled(0);
  assert(corlex_crash_install(first, headerA) == 0);
  assert(strcmp(gPath, second) == 0 && strcmp(gHeaderPrefix, headerB) == 0);
  pthread_mutex_lock(&mutex);
  released = 1; pthread_cond_signal(&condition);
  pthread_mutex_unlock(&mutex);
  assert(pthread_join(writer, NULL) == 0);
  assert(access(first, F_OK) != 0);
  FILE *file = fopen(second, "r"); assert(file);
  char text[512]; assert(fgets(text, sizeof(text), file)); fclose(file);
  assert(strstr(text, "\"scope\":\"B\"") && !strstr(text, "\"scope\":\"A\""));
  unlink(second); rmdir(folder);
  puts("Disabled crash core rearm preserves bounds and signal dispositions");
}
