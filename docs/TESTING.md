# Testing

Legend: `[x]` actually run and passed, `[ ]` not run. Automated/stub evidence is listed separately and never used to mark hardware tests complete.

## Automated validation run on 2026-09-18

- [x] Debug Swift build (`swift build`)
- [x] Unit tests (`swift test`): 15 tests, 0 failures
- [x] Universal Release build (`arm64`, `x86_64`)
- [x] DynamicLake JSON payload serialization tests
- [x] Local framed Unix-socket create/update/response smoke test
- [x] Package validation for folder and ZIP
- [x] Volume diagnostics on the development Mac
- [x] Finder Accessibility fallback disabled path does not prompt and remains optional

The socket smoke test uses a controlled synthetic transfer. It validates transport and payload lifecycle, not Finder detection or visible DynamicLake UI.

## Manual integration matrix

- [ ] Internal SSD → external SSD, one 10+ GB file
- [ ] Internal SSD → external SSD, folder with thousands of small files
- [ ] External SSD → internal SSD
- [ ] External SSD A → external SSD B
- [ ] USB flash drive
- [ ] APFS external drive
- [ ] exFAT external drive
- [ ] Cancel Finder copy midway
- [ ] Safely eject after copy
- [ ] Attempt eject during active copy (must be refused by the plugin)
- [ ] Physically disconnect drive during active copy
- [ ] Two drives connected
- [ ] Two simultaneous copy operations
- [ ] DynamicLake not running
- [ ] DynamicLake restarted while plugin is running (host is expected to restart plugin)
- [ ] Plugin restarted during active operation
- [ ] Sleep/wake during external-drive connection
- [ ] Progress API available with Accessibility denied
- [ ] Accessibility fallback enabled and authorized

## Procedure

1. Start `./scripts/run-progress-probe.sh` in Terminal for the first two cases.
2. Install the normal plugin in DynamicLake and keep the Finder fallback off.
3. Record whether Foundation, FSEvents, or neither appears in the `--debug` log.
4. Compare visible percentage to Finder at start, midpoint, and end. Do not infer byte/speed/ETA validity from percentage alone.
5. Repeat with Accessibility fallback enabled only if Foundation is absent or unreliable.
6. For each case record macOS, DynamicLake, filesystem, connection type, operation direction, provider, visible fields, cancellation result, and observed idle CPU.
7. Never test physical disconnect with irreplaceable data.

## Safe-eject checks

- The action must not be offered for a failed/cancelled/disconnected transfer.
- `EjectService` must reject a known active transfer before calling macOS.
- macOS refusal must appear as a concise error.
- No force-unmount command exists in the repository.

## Idle-performance check

With two external volumes mounted and no transfers, use Activity Monitor for ten minutes. Expect no directory crawl and effectively zero CPU between system volume/FSEvents notifications. The Foundation 4 Hz timer must not exist without a published Progress proxy.
