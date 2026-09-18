# Architecture

## Data flow

```text
NSWorkspace volume events
          │
          ▼
    VolumeMonitor ───────► FoundationProgressProvider
          │               FSEventsTransferProvider
          │               FinderAccessibilityProvider (optional)
          │                         │
          └─────────────────────────▼
                              TransferCoordinator
                         correlate / enrich / retain N
                                     │
                                     ▼
                           DynamicLakeRenderer (4 Hz)
                                     │
                                     ▼
                      framed local Unix-domain JSON socket
```

## Volume layer

`VolumeMonitor` uses `NSWorkspace` mount, will-unmount, and unmount notifications plus `URLResourceValues`. `DiskArbitration` contributes a public device-protocol hint so mounted disk images can be kept separate from real local external devices when the system exposes that distinction.

Free space uses `volumeAvailableCapacity` first because removable FAT/exFAT volumes can report zero for `volumeAvailableCapacityForImportantUsage` even when ordinary filesystem space is available. The important-usage value remains a fallback when the raw volume capacity is unavailable.

Classification does not assume every `/Volumes` path is USB:

- `isInternal == true` → internal storage
- `isLocal == false` → network
- Disk Arbitration virtual/disk-image protocol → disk image
- removable → removable
- non-internal local/ejectable → external local
- incomplete evidence → unknown

Only external-local and removable volumes are monitored in 0.1.x. A relevant mount produces a four-second connected Sneak Peek. Unmount metadata is retained from `willUnmount` until `didUnmount`, allowing a disconnected Sneak Peek after the URL has disappeared.

## Providers

### FoundationProgressProvider

Registers one public cross-process `Progress` subscriber per relevant volume. Publication/unpublication is event-driven. A 250 ms timer exists only while at least one progress proxy is alive because proxy properties change without a per-property public callback contract.

The provider forwards optional values without substitution. Unit counts are treated as bytes only when byte throughput is present; this avoids labeling arbitrary Progress units as bytes.

### FSEventsTransferProvider

Uses per-volume file-level streams with `FileEvents`, `WatchRoot`, and `NoDefer`. It neither walks the tree nor totals file sizes. Meaningful write-related events produce one low-confidence indeterminate activity per volume. A 1.5 second quiet window ends the activity but is not rendered as semantic “transfer complete.”

### FinderAccessibilityProvider

Disabled by default. It never prompts for permission. If enabled and already trusted, it registers an `AXObserver` against Finder, bounds traversal to eight levels/160 nodes, and observes numeric progress-indicator changes. It does not parse localized status sentences into made-up metrics.

## Correlation

The coordinator keeps all transfers by stable canonical ID and aliases provider IDs after a match. Correlation prefers:

1. matching destination path,
2. matching destination volume where one side is FSEvents,
3. an unambiguous single stronger transfer for pathless AX evidence,
4. a bounded eight-second time window.

Foundation values win over AX; AX wins over FSEvents. Missing fields can be enriched from a lower-priority source. Two Foundation transfers remain separate, even on the same volume.

## Presentation policy

DynamicLake 1.9.7 presents one foreground JSON-plugin activity. The renderer deterministically selects the newest active transfer from the highest-quality provider and adds an active-transfer count. All transfers remain in memory. Terminal states remain visible for ten seconds.

The renderer delays first presentation by 0.75 seconds and caps output at four updates per second. All Sneak Peek center strings are single-line and at most 240 characters for the host validator.

## Eject safety

`EjectService` calls `NSWorkspace.unmountAndEjectDevice(at:)`. It rejects non-ejectable volumes, known active transfers, or uncertain recent-write state. It never force-unmounts and never auto-ejects. In 0.1.x the renderer offers Eject only after a semantic provider reports completion and a destination volume is known.

## Lifecycle and failure behavior

- DynamicLake launches the executable and owns the socket.
- Losing the socket does not create a retry loop; DynamicLake is expected to restart its plugin.
- Unmount during a matching active transfer produces `volumeDisconnected`, not a corruption claim.
- An unpublishing Progress proxy that is neither finished nor cancelled becomes failed.
- FSEvents quieting removes the fallback activity silently.
- Connected, disconnected, and eject-result peeks dismiss after four seconds. An unmount during an active transfer uses the transfer-interrupted terminal state instead of creating a competing volume-event activity.
