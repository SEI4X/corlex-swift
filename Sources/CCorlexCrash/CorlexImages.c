#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdatomic.h>
#include <string.h>

#include "CorlexCrash.h"

// The images are recorded when dyld loads them, so that the signal handler only reads a
// static table: no dyld call, no lock, no allocation while the process is dying.
#define CORLEX_MAX_IMAGES 2048

static corlex_image_t gImages[CORLEX_MAX_IMAGES];
static atomic_int gImageCount = 0;
static atomic_int gRegistered = 0;

#ifdef __LP64__
typedef struct mach_header_64 corlex_header_t;
typedef struct segment_command_64 corlex_segment_t;
#define CORLEX_LC_SEGMENT LC_SEGMENT_64
#else
typedef struct mach_header corlex_header_t;
typedef struct segment_command corlex_segment_t;
#define CORLEX_LC_SEGMENT LC_SEGMENT
#endif

static void copy_basename(char *out, size_t cap, const char *path) {
  const char *base = path;
  for (const char *p = path; *p != '\0'; p++) {
    if (*p == '/') base = p + 1;
  }
  size_t i = 0;
  for (; base[i] != '\0' && i + 1 < cap; i++) {
    unsigned char c = (unsigned char)base[i];
    // The report is line and tab separated text.
    out[i] = (c < 0x20 || c == 0x7f) ? '_' : (char)c;
  }
  out[i] = '\0';
}

static void on_image_added(const struct mach_header *header, intptr_t slide) {
  (void)slide;
  int index = atomic_load(&gImageCount);
  if (header == NULL || index >= CORLEX_MAX_IMAGES) return;
  const corlex_header_t *mh = (const corlex_header_t *)header;
  corlex_image_t image;
  memset(&image, 0, sizeof(image));
  image.base = (uintptr_t)header;
  image.end = image.base;
  const uint8_t *cursor = (const uint8_t *)(mh + 1);
  for (uint32_t i = 0; i < mh->ncmds; i++) {
    const struct load_command *lc = (const struct load_command *)cursor;
    if (lc->cmd == LC_UUID) {
      memcpy(image.uuid, ((const struct uuid_command *)lc)->uuid, 16);
    } else if (lc->cmd == CORLEX_LC_SEGMENT) {
      const corlex_segment_t *segment = (const corlex_segment_t *)lc;
      if (strcmp(segment->segname, "__TEXT") == 0) image.end = image.base + segment->vmsize;
    }
    cursor += lc->cmdsize;
  }
  Dl_info info;
  if (dladdr(header, &info) != 0 && info.dli_fname != NULL) {
    copy_basename(image.name, sizeof(image.name), info.dli_fname);
  }
  gImages[index] = image;
  // Publish after the entry is complete; the handler only reads below the count.
  atomic_store(&gImageCount, index + 1);
}

void corlex_crash_track_images(void) {
  if (atomic_exchange(&gRegistered, 1) == 0) _dyld_register_func_for_add_image(on_image_added);
}

int corlex_crash_find_image(uintptr_t address, corlex_image_t *out) {
  int count = atomic_load(&gImageCount);
  for (int i = 0; i < count; i++) {
    if (address >= gImages[i].base && address < gImages[i].end) {
      if (out != NULL) *out = gImages[i];
      return 1;
    }
  }
  return 0;
}
