# Changelog

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
