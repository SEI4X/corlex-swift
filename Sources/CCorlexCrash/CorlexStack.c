#include <mach/mach.h>
#include <mach/vm_map.h>
#include <signal.h>
#include <sys/ucontext.h>

#include "CorlexInternal.h"

#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

static uintptr_t strip(uintptr_t address) {
#if __has_feature(ptrauth_calls)
  return (uintptr_t)ptrauth_strip((void *)address, ptrauth_key_function_pointer);
#else
  return address;
#endif
}

// Reads two words (saved frame pointer, return address) with a Mach call that fails instead
// of faulting on a bad address: a corrupted frame pointer must not crash the crash handler.
static int read_frame(uintptr_t fp, uintptr_t out[2]) {
  if (fp == 0 || (fp & (sizeof(uintptr_t) - 1)) != 0) return 0;
  vm_size_t read = 0;
  kern_return_t status = vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof(uintptr_t) * 2,
                                           (vm_address_t)out, &read);
  return status == KERN_SUCCESS && read == sizeof(uintptr_t) * 2;
}

static int add(uintptr_t *out, int count, int capacity, uintptr_t address) {
  if (address == 0 || count >= capacity) return count;
  // The same return address twice in a row is the link register and its saved copy.
  if (count > 0 && out[count - 1] == address) return count;
  out[count] = address;
  return count + 1;
}

int corlex_crash_walk_stack(void *context, uintptr_t *out, int capacity) {
  ucontext_t *uc = (ucontext_t *)context;
  if (uc == NULL || uc->uc_mcontext == NULL) return 0;
  uintptr_t pc, fp, lr = 0;
#if defined(__arm64__) || defined(__aarch64__)
  pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
  fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
  lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
#elif defined(__x86_64__)
  pc = (uintptr_t)uc->uc_mcontext->__ss.__rip;
  fp = (uintptr_t)uc->uc_mcontext->__ss.__rbp;
#else
  return 0;
#endif
  int count = add(out, 0, capacity, strip(pc));
  count = add(out, count, capacity, strip(lr));
  // A frame is [previous frame pointer, return address]. Stop when the chain stops growing
  // upwards, which also ends loops in corrupted stacks.
  while (count < capacity) {
    uintptr_t frame[2];
    if (!read_frame(fp, frame)) break;
    count = add(out, count, capacity, strip(frame[1]));
    if (frame[0] <= fp) break;
    fp = frame[0];
  }
  return count;
}
