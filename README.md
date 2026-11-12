# Corlex for Swift / iOS

Version 0.1.0 is an unpublished SDK-only source candidate. Stable package/tag publication and owner merge are separate release gates. The Corlex application/server and its private Git history are not part of this repository.

## Installation

From a reviewed checkout, add this directory as a local Swift package in Xcode and link the Corlex product. A future approved tag can be used with Swift Package Manager; no tag or registry release is promised by this source candidate.

Use the project's actual ingest/config URLs. The write-only project SDK key is compiled into the client; it is observable in an app bundle. MCP, upload and AI-provider secrets must never be embedded in an app. Corlex MCP onboarding can provision the SDK key directly into ignored build configuration.

## Quick start

The variables below come from your host app's ignored build configuration/project setup; they are not literal placeholder services.

```swift
import Corlex
var options = CorlexOptions()
options.endpoint = ingestURL
options.configEndpoint = configURL
options.consent = .pending
Corlex.start(key: projectWriteKey, options: options)
// After the host app has obtained the applicable consent:
Corlex.optIn()
Corlex.track("signup_completed", properties: ["method": "email"])
```

Call startup once. Never copy another analytics pipeline merely to obtain native upload tools. reset rotates identity; historical events retain their captured identities. optOut withdraws collection and clears pending SDK state.

## Features and API

`Corlex.start(key:options:)`, `track(_:properties:)`, `identify(_:traits:)`, `setUserProperties`, `screen`, `reset`, async `flush`, `optIn`, `optOut`, `consent`, `flag(_:default:)`, `experiment`; `Corlex.config.get/getAll/ready/refresh/onUpdate`.

Automatic lifecycle and screen events, explicit product events, consent, offline delivery, crash reports, Remote Config and deterministic experiments are described in [API](docs/API.md), [data/consent](docs/CONSENT-AND-DATA.md), [storage](docs/LOCAL-STORAGE.md) and [crashes](docs/CRASHES.md).

## Development

Xcode with an iOS simulator and Swift 5.9 or newer. Tested locally with Xcode 27.1 / Swift 6.4. `xcodebuild test -scheme Corlex -destination "platform=iOS Simulator,id=<your-test-simulator>" -parallel-testing-enabled NO`; `swift test --package-path Tools`; `Tools/test-transport.sh`, `Tools/test-client.sh`, `Tools/test-crash-rearm.sh`, `Tools/test-crash-exception.sh` and `Tools/test-crash-writer.sh` on macOS.

See [troubleshooting](docs/TROUBLESHOOTING.md), [security](SECURITY.md), [contributing](CONTRIBUTING.md), [release process](docs/PUBLISHING.md) and [changelog](CHANGELOG.md). MIT covers our SDK code; bundled third-party tools/dependencies keep their own licenses/notices.
