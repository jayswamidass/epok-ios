# Epok RUM and session replay for iOS

Masked wireframe session replay for iOS apps, sent to [Epok](https://getepok.dev).
Replays play in the same Epok player as browser sessions, next to your traces and errors.

Capture uses PostHog's open-source iOS recorder (MIT), pinned to one tested version (3.92.0)
and configured so that nothing is sent to PostHog.

## Install

iOS 15 or later, Swift Package Manager.

```swift
// Package.swift
.package(url: "https://github.com/jayswamidass/epok-ios.git", exact: "0.1.0"),

// target dependencies:
.product(name: "EpokRum", package: "epok-ios"),
.product(name: "EpokReplay", package: "epok-ios"),
```

In Xcode: File → Add Package Dependencies…, enter the URL above, and add `EpokRum` and
`EpokReplay` to your app target.

## Use

```swift
import EpokRum
import EpokReplay

// On launch — creates no PostHog SDK, no files, and sends nothing yet:
let rum = try Rum(config: RumConfig(
    endpoint: "https://ingest.getepok.dev",
    publicIngestKey: "epk_…",            // restricted ingest-only key
    accountId: "YOUR_TENANT_ID", projectId: "0",
    serviceName: "my-ios-app"))
let replay = try EpokReplay(rum: rum,
    host: URL(string: "https://ingest.getepok.dev/v1/rum/mobile/ios")!,
    publicIngestKey: "epk_…")

// From your consent UI (on the main actor):
await replay.grantConsent()     // grants RUM consent too, then starts capture
await replay.withdrawConsent()  // stop capture and erase anything still queued
```

## Privacy

- Wireframes only: screenshot mode is off.
- Text inputs, images and sandboxed views are always masked.
- Logs, network telemetry and analytics events are not captured.
- Nothing is created, recorded, queued or sent until `grantConsent()`. `withdrawConsent()`
  stops capture and erases anything still queued on the device.
- PostHog's remote-config request is answered on the device; no request reaches PostHog.

The key ships inside your app, so treat it as public and use an ingest-only key.

Full guide: https://getepok.dev/docs/install/mobile-replay

## Licence

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
