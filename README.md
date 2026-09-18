# Transfer Center for DynamicLake

See file transfers to USB drives, external SSDs, and other storage devices directly in DynamicLake.

Transfer Center is a local, native Swift plugin. It correlates public macOS file-progress publications with low-cost filesystem activity and can optionally use Finder Accessibility as a compatibility fallback. Unknown values stay hidden: the plugin never invents a byte count, speed, ETA, or percentage.

> Development status: the plugin builds, tests, packages, and speaks the DynamicLake 1.9.7 JSON-plugin protocol. Real Finder-to-external-drive detection is **not yet manually tested** on this machine because no external physical volume was mounted during development.

## Features

- Compact active-transfer status in DynamicLake.
- Progress, byte count, speed, ETA, file count, and current item when the source API actually supplies them.
- Multiple simultaneous transfers in the core; the newest highest-confidence operation owns the single foreground activity.
- Foundation `Progress` as the preferred semantic provider.
- File-level FSEvents fallback for honest, indeterminate write activity.
- Optional, isolated Finder Accessibility provider.
- Completion, cancellation, failure, and drive-disconnected states.
- Safe eject action after confirmed completion; never force-unmounts.
- Event-driven volume mount/unmount handling and no idle directory crawling.
- Brief, self-dismissing Sneak Peeks when an external drive connects or disconnects.
- No persistent activity while idle.
- Custom transparent silver drive artwork for drive and transfer activities instead of the macOS SF Symbol.
- Local-only operation with no telemetry, analytics, accounts, or network service.

## Screenshots

Screenshots will be added after the real-device test matrix has been run. The development package provides a deterministic mock activity for visual verification without pretending it is a Finder copy.

## Requirements

- macOS 13 or newer.
- DynamicLake Pro with JSON plugins (developed against 1.9.7.5).
- Xcode/Swift toolchain only when building from source.
- An external/removable volume for meaningful real-transfer testing.

## Installation

1. Build the package:

   ```sh
   ./scripts/build-release.sh
   ```

2. Open DynamicLake → Settings → Plugins → Install Local.
3. Select `TransferCenter.dynamiclakeplugin` from this repository.
4. Keep **Finder Accessibility Fallback** disabled initially. It is not needed for Foundation Progress or FSEvents.

For a visual host-only check, install `TransferCenter-Development.dynamiclakeplugin`; it sends a synthetic 42% transfer followed by completion and then dismisses itself. Do not use the development package as the everyday plugin.

## Build from source

```sh
swift build
swift test
swift build -c release --arch arm64 --arch x86_64
./scripts/package-plugin.sh
./scripts/check-package.sh dist/TransferCenter-0.1.3.dynamiclakeplugin.zip
```

The Release binary is universal (`arm64` and `x86_64`). No third-party runtime dependency is bundled.

## How transfer detection works

Provider priority is:

1. **Foundation Progress** — semantic progress, preferred when an application publishes it.
2. **Finder Accessibility** — optional exact progress-indicator value with inferred context.
3. **FSEvents** — activity evidence only; shown as indeterminate and never promoted into fake exact progress.

`TransferCoordinator` correlates providers by destination path, destination volume, timestamp, and provider quality. Two independent high-confidence transfers remain separate. A low-confidence FSEvents activity can enrich or be replaced by the matching semantic transfer.

### Foundation Progress support

`transfer-probe` subscribes to every relevant mounted volume with `Progress.addSubscriber(forFileURL:withPublishingHandler:)`, tracks mount/unmount while running, and prints all public fields. Run:

```sh
./scripts/run-progress-probe.sh
```

Then start Finder copies involving the external volume. See [the recorded findings](docs/PROGRESS_API_FINDINGS.md).

### Fallback behavior

File-level FSEvents detects writes without scanning the drive. It emits an indeterminate “Transferring…” state and removes it after activity settles. It does not claim byte progress or semantic completion.

Finder Accessibility is off by default. When enabled and already authorized, it listens to Finder AX window/progress-indicator events and uses numeric progress values only. Missing roles, values, windows, localization, or permission disable the provider gracefully.

## Permissions

Normal operation needs no root, sudo, kernel extension, Full Disk Access, or Accessibility permission.

Accessibility is optional and only supports the Finder fallback. Transfer Center never opens System Settings or triggers the permission prompt automatically. If you enable the fallback, grant Accessibility to the installed `transfer-center` executable when macOS asks you to manage it manually. Foundation Progress, volume monitoring, and FSEvents continue without it.

## Privacy

- All processing happens on the Mac.
- No analytics, telemetry, remote server, account, or network upload exists.
- File contents are never opened or collected.
- File/volume labels and transfer statistics are sent only to DynamicLake over its local Unix-domain plugin socket for rendering.
- Normal logs omit full file paths. The explicit progress probe prints the affected URL because that is its diagnostic purpose.
- `PrivacyInfo.xcprivacy` declares no collection/tracking and documents disk-space display reason `85F4.1` for the optional connected-drive free-space label.

## Performance

- Volume changes, FSEvents, AX notifications, and socket reads are event-driven.
- There is no idle directory scan.
- Foundation progress polls only while published operations exist, at 4 Hz.
- DynamicLake renders at most 4 updates per second.
- Tiny transfers are held for 0.75 seconds to avoid notch spam.
- The diagnostic log is capped at 512 KB.

## Supported transfer scenarios

The architecture supports internal → external, external → internal, and external → external operations when at least one provider exposes usable evidence. Public Foundation subscriptions are rooted at external volumes, so Finder operations whose published URL exists only on an internal destination may require the optional AX fallback. Network/NAS volumes are classified but intentionally not monitored in 0.1.x.

## Known limitations

- Finder has not yet been proven on real external hardware in this environment. Do not interpret the official Chrome/Safari Progress usage as proof that Finder publishes equivalent objects.
- FSEvents observes writes, not reads, and therefore cannot quantify external → internal copies.
- Foundation file progress does not explicitly declare the unit-count unit. Byte counts are shown only when the object also supplies byte throughput; fraction and file counts remain usable independently.
- DynamicLake 1.9.7 JSON Sneak Peek center text is one line and limited to 240 characters, so the hover view is a concise summary rather than a multiline panel.
- The JSON plugin surface exposes one foreground activity here; simultaneous transfers remain in the coordinator and the count is displayed.
- Finder Accessibility is a compatibility layer over UI structure and can change with macOS/Finder updates.

## Development and diagnostics

```sh
swift run transfer-center --list-volumes
swift run transfer-center --diagnostics
swift run transfer-center --demo-json
swift run transfer-center --probe-progress
```

Add `--debug` for bounded local diagnostics. The log lives at `~/Library/Application Support/DynamicLake/PluginLogs/transfer-center-debug.log`.

Architecture details are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), the current DynamicLake contract in [docs/DYNAMICLAKE_INTEGRATION.md](docs/DYNAMICLAKE_INTEGRATION.md), and the complete manual matrix in [docs/TESTING.md](docs/TESTING.md).

## Testing

Automated tests cover volume classification, provider precedence/deduplication, lifecycle states, simultaneous transfers, formatting, and DynamicLake JSON structures. A local Unix-socket smoke test validates framed create/update messages and host response handling.

No hardware scenario in `docs/TESTING.md` is marked passed unless it actually ran.

## Packaging and DynamicLake Market

`scripts/build-release.sh` builds a universal Release executable, runs tests, packages the plugin, validates manifest/icon/executable/layout/size constraints, runs the wire smoke test, and prints SHA-256. The current checks enforce the documented Market limits supplied for this project: 7 MB ZIP, 20 MB unpacked, square PNG icon no larger than 1.5 MB.

The archive is created at `dist/TransferCenter-0.1.3.dynamiclakeplugin.zip`. Releases are not automatically published.

## Icon

`Assets/icon.png` is the generated development plugin artwork. `Assets/drive-transfer-symbol.png` is the supplied drive design recreated on transparency and optimized to 96×96/4.8 KB for DynamicLake's inline-image component. Replace either with final reviewed artwork before Market submission if desired.

## License

MIT. See [LICENSE](LICENSE).
