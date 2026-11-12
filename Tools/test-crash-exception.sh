#!/bin/sh
# Real Swift NSException writer + canonical C, in an isolated non-crashing CLI process.
set -eu
sdk=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/corlex-exception.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
core="$sdk/Sources/CCorlexCrash"
mkdir -p "$work/module"
printf 'module CCorlexCrash { header "%s/include/CorlexCrash.h" export * }\n' "$core" > "$work/module/module.modulemap"
for source in "$core"/*.c; do
  clang -g -O1 -fno-omit-frame-pointer -fsanitize=address -I "$core/include" -c "$source" -o "$work/$(basename "$source" .c).o"
done
# Explicit optional foundations keep this probe valid before/after scoped Storage is introduced.
set --
for source in StorageScope PrivacyLedger OwnerChoices PrivacyFence; do
  file="$sdk/Sources/Corlex/Internal/$source.swift"
  if [ -f "$file" ]; then set -- "$@" "$file"; fi
done
swiftc -g -sanitize=address -I "$work/module" \
  "$sdk/Sources/Corlex/Internal/DeviceInfo.swift" "$sdk/Sources/Corlex/Internal/WireEvent.swift" \
  "$sdk/Sources/Corlex/Internal/Limits.swift" "$sdk/Sources/Corlex/Internal/JSONValue.swift" \
  "$sdk/Sources/Corlex/Internal/Storage.swift" "$@" "$sdk/Sources/Corlex/Crash/"*.swift \
  "$sdk/Tests/NativeException/main.swift" "$work/"*.o -o "$work/exception"
ASAN_OPTIONS=detect_leaks=0 "$work/exception"
