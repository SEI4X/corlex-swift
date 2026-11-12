#!/bin/sh
set -eu
sdk=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/corlex-swift-thread-stack.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
core="$sdk/Sources/CCorlexCrash"
mkdir -p "$work/module"
printf 'module CCorlexCrash { header "%s/include/CorlexCrash.h" export * }\n' "$core" > "$work/module/module.modulemap"
for source in "$core"/*.c; do
    clang -O2 -fsanitize=address,undefined -I "$core/include" -c "$source" -o "$work/$(basename "$source" .c).o"
done
swiftc -sanitize=address -I "$work/module" "$sdk/Sources/Corlex/Crash/NativeCrashThreadStack.swift" \
    "$sdk/Tests/NativeThreadStack/main.swift" "$work"/*.o -o "$work/probe"
for mode in own host; do ASAN_OPTIONS=use_sigaltstack=0:detect_leaks=0 "$work/probe" "$mode"; done
