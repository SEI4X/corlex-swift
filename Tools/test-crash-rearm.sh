#!/bin/sh
set -eu
sdk=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
core="$sdk/Sources/CCorlexCrash"
work=$(mktemp -d "${TMPDIR:-/tmp}/corlex-rearm.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
clang -g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -D_DARWIN_C_SOURCE \
  -I "$core" -I "$core/include" "$sdk/Tests/Native/rearm.test.c" \
  "$core/CorlexImages.c" "$core/CorlexStack.c" "$core/CorlexOutput.c" -o "$work/rearm"
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 "$work/rearm"
