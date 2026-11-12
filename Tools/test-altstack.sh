#!/bin/sh
set -eu
sdk=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/corlex-altstack-proof.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
core="$sdk/Sources/CCorlexCrash"
clang -O2 -fsanitize=address,undefined -I "$core/include" -I "$core" "$sdk/Tests/NativeAltStack/main.c" "$core"/*.c -o "$work/probe"
ASAN_OPTIONS=use_sigaltstack=0 "$work/probe" "$work/owned.corlex" own
ASAN_OPTIONS=use_sigaltstack=0 "$work/probe" "$work/host.corlex" host
