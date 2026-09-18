# Foundation Progress / Finder findings

## Result

**Finder Progress Result: NOT YET MANUALLY TESTED**

No external physical disk was mounted on the development Mac during implementation (`diskutil list external physical` returned no device). Consequently, neither internal → external Finder copy scenario requested for the probe could honestly be run.

This is distinct from two verified facts:

1. The public macOS API exists and the project compiles against `Progress.addSubscriber(forFileURL:withPublishingHandler:)`.
2. DynamicLake's currently installed official Chrome Downloads plugin uses the same cross-process Progress subscriber mechanism for browser file operations.

Neither fact proves Finder publishes compatible objects for external-volume copies.

## Implemented probe

`transfer-probe`:

- enumerates mounted volumes through `VolumeMonitor`;
- subscribes to every external-local/removable volume root;
- subscribes and unsubscribes as volumes mount/unmount;
- retains every published proxy until its unpublishing handler fires;
- samples active proxy properties at 2 Hz;
- prints operation kind, file URL, fraction/indeterminate state, unit counts, file counts, throughput, ETA, localized descriptions, cancellation/pause support, finish/cancel state, and `isOld`;
- removes all subscribers on shutdown.

Run:

```sh
./scripts/run-progress-probe.sh | tee progress-probe.log
```

Then execute both tests in Finder:

1. Internal disk → external USB/SSD, one large file.
2. Internal disk → external USB/SSD, one folder with multiple files.

Leave the copy running long enough to capture multiple updates. Cancel once in a separate run to verify cancellation and unpublication.

## Acceptance criteria for confirmation

Change the status to **CONFIRMED** only if the log contains a published Progress object caused by Finder for both scenarios and its fraction advances consistently with Finder. Record macOS version, filesystem, drive connection, operation kind, whether byte/file/ETA/speed fields exist, and cancellation behavior.

Change it to **NOT DETECTED** only after running the real tests and recording that no matching publication appeared. Absence without an attached external device is not a negative result.

## Current provider decision

Foundation Progress remains the primary provider because it is the only public API in this architecture capable of semantic, cancellable, byte/file-aware progress. FSEvents is active as an honest indeterminate fallback. Finder Accessibility is implemented but disabled by default until the probe result shows it is needed.
