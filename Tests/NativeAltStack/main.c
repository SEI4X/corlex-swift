#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include "CorlexCrash.h"
static char host_stack[128 * 1024];
static const char *report_path;
static void *worker(void *unused) {
  (void)unused;
  stack_t before, after;
  assert(sigaltstack(NULL, &before) == 0);
  assert(corlex_crash_prepare_thread_stack() == 0);
  assert(corlex_crash_install(report_path, "{\"v\":1,") == 1);
  assert(sigaltstack(NULL, &after) == 0);
  assert((before.ss_flags & SS_DISABLE) == (after.ss_flags & SS_DISABLE));
  if (!(before.ss_flags & SS_DISABLE)) assert(before.ss_sp == after.ss_sp);
  return NULL;
}
int main(int argc, char **argv) {
  assert(argc == 3); report_path = argv[1];
  if (!strcmp(argv[2], "host")) {
    stack_t host = {.ss_sp = host_stack, .ss_size = sizeof(host_stack), .ss_flags = 0};
    assert(sigaltstack(&host, NULL) == 0);
  }
  stack_t before, prepared, repeated;
  struct sigaction old_action, pending_action;
  assert(sigaltstack(NULL, &before) == 0);
  assert(sigaction(SIGSEGV, NULL, &old_action) == 0);
  assert(corlex_crash_prepare_thread_stack() == 1);
  assert(corlex_crash_open_report() == -1); // Pending preparation never arms capture or records a path.
  assert(sigaction(SIGSEGV, NULL, &pending_action) == 0);
  assert(old_action.sa_sigaction == pending_action.sa_sigaction);
  assert(old_action.sa_flags == pending_action.sa_flags);
  assert(sigaltstack(NULL, &prepared) == 0 && !(prepared.ss_flags & SS_DISABLE));
  if (!(before.ss_flags & SS_DISABLE)) assert(before.ss_sp == prepared.ss_sp && before.ss_size == prepared.ss_size);
  pthread_t thread; assert(pthread_create(&thread, NULL, worker, NULL) == 0);
  assert(pthread_join(thread, NULL) == 0);
  assert(corlex_crash_prepare_thread_stack() == 1); // Works after global worker installation too.
  assert(sigaltstack(NULL, &repeated) == 0);
  assert(prepared.ss_sp == repeated.ss_sp && prepared.ss_size == repeated.ss_size);
  puts("Main altstack preparation: no pending handlers/arming, host preservation, worker isolation and idempotence passed");
  return 0;
}
