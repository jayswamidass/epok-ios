# iOS replay sample

`EpokReplaySample.xcodeproj` is a UIKit sample using the local SwiftPM products
`EpokRum` (unchanged raw OTLP) and `EpokReplay` (PostHog 3.92.0 capture).
Replay starts only after the shared grant button succeeds in granting RUM consent.
The sample has layout/metric, offline, flush and withdrawal controls; every launch
starts denied. It reads local ingest configuration from its own Documents directory,
written by `../mac-replay-capture.sh`, rather than embedding credentials in source.

On the Mac mini, prepare local Epok with migration 152, replay/auth enabled, local
read and ingest keys, and an already-booted iPhone simulator on iOS 27 / Xcode 27:

```sh
export EPOK_LOCAL_PORT=4320
export EPOK_TENANT_ID=42 EPOK_PROJECT_ID=7
# Set EPOK_REPLAY_INGEST_KEY and EPOK_REPLAY_READ_KEY to LOCAL keys.
cd mobile/ios
./mac-replay-capture.sh SELECTED_SIMULATOR_UDID
```

The script runs Swift transport tests, builds/installs only `dev.epok.replay.sample`,
drives an XCUITest session, checks withdrawal and fresh-launch denial, reads actual
Epok wireframe chunks, and saves captures under `mobile/ios/artifacts/`. It does not
boot/erase/shut down simulators. The sample app is replaced for a fresh test; the
existing `ProcessDeathHarness` app and EpokRum library remain intact.

**Not built or run on Linux.** See [M2-IOS-REPORT.md](../../../M2-IOS-REPORT.md) for
source verification, Linux proof, queue tradeoffs and the exact remaining Mac gates.
The existing standalone process-death harness is in
[ProcessDeathHarness](../ProcessDeathHarness/README.md). The older manual flow below
remains available for raw-OTLP investigation.

# Historical manual raw-OTLP process-death flow

The package's mandatory XCTest simulates
process death by saving an ack and a 503-retained observation, releasing its store,
and constructing a new store from the same file. This proves reconstruction, not
OS process termination. The separate external-flow XCTest is intentionally skipped.

For a real out-of-process check, create a disposable iOS SwiftUI app in Xcode and
add this directory as a local Swift package dependency. Select the EpokRum product.
Build/install it on the already-selected iPhone 18 Pro iOS 27.0 simulator. Give the
app a unique bundle ID, such as `dev.epok.rum.processdeath`. These are manual review
steps; the package script never creates or resets a simulator.

## Host wiring

1. Retain one `Rum` and one `ManualConnectivity(initiallyOnline: false)` in the app.
   Construct them anew on every app launch. Never persist or automatically restore
   granted consent. Use `Rum(config:connectivity:storageURL:)` with the fixed file
   `Application Support/epok-process-death/ledger.json` in the app container.
2. Point config at a controllable local OTLP/HTTP collector with a dummy public key.
   Have it record received batch IDs from `rum.batch.id`, paths, headers and bodies.
   It must support switching 204/503/200 responses. Use only an isolated listener
   owned by this test; do not touch a shared backend. For cleartext loopback, configure
   the disposable host's ATS local-network exception in Xcode as needed.
   Set `config.retryBaseMs = 30_000` and `config.maxRetryDelayMs = 30_000` so manual
   actions have at least 15 seconds before the first retry. Keep the default age cap.
3. Provide buttons/actions for grant, record metric, record HTTP, offline, online,
   flush, and withdraw. SDK calls use `await`; toggling the manual connectivity gate
   uses `network.setOnline(...)`. The gate affects SDK export, not simulator networking.
4. After each phase, write a status JSON in the app's Documents directory. Include
   `ProcessInfo.processInfo.processIdentifier`, `snapshot.consent.rawValue`, session ID,
   `exporterConstructed`, `ledgerLoaded`, batch IDs, pending, enqueued, acked,
   dropped_capacity, dropped_error, storageHealthy and accountingUncertain. Use
   filenames `before-kill.json`, `startup.json`, `restored.json`, and `after.json`.
   Emit startup status immediately after construction, before any user action.

## Prepare, terminate, relaunch, verify

1. Start with a fresh test-host storage identity. Grant consent, record one metric,
   set the collector to 204, go online and flush. Assert `enqueued=1, acked=1, pending=0`.
2. Go offline, record an HTTP observation containing `?token=sample-secret`, then
   set the collector to 503, go online, and flush once. Go offline immediately before
   the next retry. Assert `enqueued=2, acked=1, pending=1`, healthy storage and no
   drops. Save `before-kill.json`; inspect the ledger for the pending batch's exact
   ID, body, attempts and notBefore. Confirm no raw secret appears in it.
3. Use an explicit simulator UDID and the disposable app's bundle ID. Find the UDID
   in Xcode's Devices and Simulators window. Run these commands in Terminal:

   ```bash
   poc_device_udid='REPLACE_WITH_SELECTED_SIMULATOR_UDID'
   poc_bundle_id='dev.epok.rum.processdeath'
   poc_container=$(xcrun simctl get_app_container "$poc_device_udid" "$poc_bundle_id" data)
   cat "$poc_container/Documents/before-kill.json"
   xcrun simctl terminate "$poc_device_udid" "$poc_bundle_id"
   xcrun simctl launch "$poc_device_udid" "$poc_bundle_id"
   cat "$poc_container/Documents/startup.json"
   ```

   Do not call `close()`, withdraw, or delete the ledger before termination. Only
   terminate this test app. Do not shut down, erase, delete or boot simulators.
4. Verify a new process ID. At startup require denied consent, no session, no
   exporter, `ledgerLoaded=false`, and no collector requests. The snapshot has not
   loaded disk yet; use the unchanged ledger to inspect retained observations.
5. Keep the manual network gate offline, grant fresh consent, and save
   `restored.json`. Require the **same pending batch ID and payload**, `enqueued=2`,
   `acked=1`, `pending=1`, and a new runtime session ID. Attempt count and retry
   deadline must be unchanged, not reset. Queued payloads keep their original session.
6. After the persisted retry deadline, switch the collector to 200 and go online.
   Flush and save `after.json`. Require `enqueued=2, acked=2, pending=0`, zero drops,
   and conservation. The collector must receive the pending batch ID again with the
   same body; the previously acknowledged metric must **not** be resent. Inspect
   `X-API-Key`, `AccountID`, `ProjectID`, JSON content type, and scrubbed URLs.
7. Terminate/relaunch once more; grant while offline and verify both acks remain
   accounted with no pending batches. Record host/toolchain versions and artifacts
   separately from the in-package XCTest results.

If the pending observation exhausts its lifetime cap or ages out during manual
setup, reset only this disposable host's fixture and repeat. Do not describe the
flow as passed until the external kill/relaunch and collector checks are complete.
