# Changelog

## 0.1.7 - 2026-09-18

- Fixed the center flashing `success` multiple times during multi-file copies. Sequential per-file Foundation Progress objects on the same volume now continue one logical transfer, so completion appears once at the end.
- Replaced the address-based Progress transfer ID with a stable UUID per observed Progress object.
- Fixed identical payloads being resent by excluding `requestID` from the renderer throttle signature.

## 0.1.6 - 2026-09-18

- Show completed transfers and connected drives with a plain checkmark instead of the circled status badge in the notch.
- Failures and interruptions keep the circled status indicator.

- Suppressed Foundation Progress objects that are already terminal when first published.
- Show completion only for a transfer that previously crossed the Live Activity visibility threshold.
- Prevented short Finder preflight operations from flashing `Transfer complete` before the real copy starts.

## 0.1.4 - 2026-09-18

- Fixed removable drives incorrectly showing `0 KB free` when macOS reports zero only for the important-usage capacity estimate.
- Use the filesystem's normal available-capacity value first and retain important-usage capacity as a fallback.

## 0.1.3 - 2026-09-18

- Replaced the drive SF Symbol with custom transparent silver drive artwork derived from the supplied reference.
- Added package validation for the inline artwork's alpha channel and DynamicLake 48 KB decoded-image limit.

## 0.1.2 - 2026-09-18

- Standardized drive-related leading artwork on Apple's `externaldrive.fill` SF Symbol.
- Replaced the disconnected warning indicator with a neutral gray `xmark`.

## 0.1.1 - 2026-09-18

- Fixed the development mock activity remaining visible indefinitely.
- Added brief connected and disconnected drive Sneak Peeks that dismiss automatically.
- Preserved disconnected-volume metadata across the macOS unmount notification sequence.
- Made eject-result peeks transient as well.

## 0.1.0 - 2026-09-18

- Initial development release.
- Added external-volume monitoring and classification.
- Added Foundation `Progress`, FSEvents, and optional Finder Accessibility providers.
- Added transfer correlation, safe eject, DynamicLake rendering, diagnostics, tests, and packaging.
