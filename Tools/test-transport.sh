#!/bin/sh
# Run the exact Foundation transport source on macOS without linking the iOS-only UIKit module.
set -eu
sdk_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/corlex-transport-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/Sources/Corlex" "$work/Tests/CorlexTests"
for source in Transport Sender EventQueue Storage Limits JSONValue WireEvent EndpointPolicy StorageBinding PrivacyLedger OwnerChoices PrivacyFence StorageScope ClientBinding BoundTransport; do
  cp "$sdk_root/Sources/Corlex/Internal/$source.swift" "$work/Sources/Corlex/$source.swift"
done
cp "$sdk_root/Tests/CorlexTests/TransportSecurityTests.swift" "$work/Tests/CorlexTests/TransportSecurityTests.swift"
cp "$sdk_root/Tests/CorlexTests/SenderConsentTests.swift" "$work/Tests/CorlexTests/SenderConsentTests.swift"
cp "$sdk_root/Tests/CorlexTests/ConfigSecurityTests.swift" "$work/Tests/CorlexTests/ConfigSecurityTests.swift"
cp "$sdk_root/Tests/CorlexTests/EndpointPolicyTests.swift" "$work/Tests/CorlexTests/EndpointPolicyTests.swift"
cp "$sdk_root/Tests/CorlexTests/ClientBindingTests.swift" "$work/Tests/CorlexTests/"
cp "$sdk_root/Tests/CorlexTests/ScopedStorageTests.swift" "$work/Tests/CorlexTests/ScopedStorageTests.swift"
cp "$sdk_root/Tests/CorlexTests/PrivacyCeilingTests.swift" "$work/Tests/CorlexTests/"
cp "$sdk_root/Tests/CorlexTests/PrivacyLedgerTests.swift" "$work/Tests/CorlexTests/PrivacyLedgerTests.swift"
cp "$sdk_root/Tests/CorlexTests/StorageBindingTests.swift" "$work/Tests/CorlexTests/StorageBindingTests.swift"
cp "$sdk_root/Tests/CorlexTests/BucketVectorsTests.swift" "$work/Tests/CorlexTests/BucketVectorsTests.swift"
cp -R "$sdk_root/Tests/CorlexTests/Fixtures" "$work/Tests/CorlexTests/Fixtures"
cp "$sdk_root/Sources/Corlex/Crash/CrashReportReader.swift" "$sdk_root/Sources/Corlex/Crash/NativeCrashPrivacy.swift" "$work/Sources/Corlex/"
cp "$sdk_root/Tests/CorlexTests/NativeCrashPrivacyTests.swift" "$work/Tests/CorlexTests/"
cp "$sdk_root/Sources/Corlex/Config/"*.swift "$work/Sources/Corlex/"
cat > "$work/Package.swift" <<'PACKAGE'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "CorlexTransportTests", platforms: [.macOS(.v13)], targets: [
    .target(name: "Corlex"),
    .testTarget(name: "CorlexTests", dependencies: ["Corlex"], resources: [.copy("Fixtures")]),
])
PACKAGE
swift test --package-path "$work"
