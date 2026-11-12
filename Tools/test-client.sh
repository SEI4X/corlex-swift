#!/bin/sh
# Exact Foundation client pipeline. UIKit/native-crash branches fail if accidentally entered.
set -eu
sdk=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/corlex-client-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/Sources/Corlex" "$work/Tests/CorlexTests"
cp "$sdk/Sources/Corlex/Internal/"*.swift "$work/Sources/Corlex/"
cp "$sdk/Sources/Corlex/Config/"*.swift "$work/Sources/Corlex/"
cp "$sdk/Sources/Corlex/"*.swift "$work/Sources/Corlex/"
cp "$sdk/Sources/Corlex/Crash/CrashReportReader.swift" "$sdk/Sources/Corlex/Crash/NativeCrashPrivacy.swift" "$work/Sources/Corlex/"
cp "$sdk/Tests/Foundation/PlatformBoundaries.swift" "$work/Sources/Corlex/"
for test in TestSupport ClientTests RemoteConfigTests BindingLifecycleTests AttBindingTests DiagnosticsPrivacyTests ImmediateDenialTests OwnerChoiceTests OwnerChoiceStorageTests StorageBindingTests PrivacyLedgerTests ClientBindingTests SenderTests; do
  cp "$sdk/Tests/CorlexTests/$test.swift" "$work/Tests/CorlexTests/"
done
cat > "$work/Package.swift" <<'PACKAGE'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "CorlexClientTests", platforms: [.macOS(.v13)], targets: [
    .target(name: "Corlex"), .testTarget(name: "CorlexTests", dependencies: ["Corlex"]),
])
PACKAGE
swift test --package-path "$work" "$@"
