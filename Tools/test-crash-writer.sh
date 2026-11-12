#!/bin/sh
# NSException writes in fresh isolated CLI processes, without raising any fatal signal.
set -eu
sdk=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/corlex-native-writer.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
core="$sdk/Sources/CCorlexCrash"
mkdir -p "$work/module"
printf 'module CCorlexCrash { header "%s/include/CorlexCrash.h" export * }\n' "$core" > "$work/module/module.modulemap"
for source in "$core"/*.c; do
  clang -g -O1 -fno-omit-frame-pointer -fsanitize=address -I "$core/include" -c "$source" -o "$work/$(basename "$source" .c).o"
done
swiftc -g -sanitize=address -I "$work/module" \
  "$sdk/Sources/Corlex/Internal/DeviceInfo.swift" "$sdk/Sources/Corlex/Internal/WireEvent.swift" \
  "$sdk/Sources/Corlex/Internal/Limits.swift" "$sdk/Sources/Corlex/Internal/JSONValue.swift" \
  "$sdk/Sources/Corlex/Internal/Storage.swift" "$sdk/Sources/Corlex/Internal/StorageScope.swift" \
  "$sdk/Sources/Corlex/Internal/PrivacyLedger.swift" "$sdk/Sources/Corlex/Internal/OwnerChoices.swift" \
  "$sdk/Sources/Corlex/Internal/PrivacyFence.swift" \
  "$sdk/Sources/Corlex/Crash/"*.swift "$sdk/Tests/NativeWriter/main.swift" "$work/"*.o -o "$work/writer"
for mode in default detailed rearm lock-order; do
  ASAN_OPTIONS=detect_leaks=0 "$work/writer" "$mode"
done
