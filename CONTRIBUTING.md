# Contributing

Thank you for considering a contribution.

## Scope

This plugin shows file-transfer activity for external USB drives, SSDs, and other removable storage in DynamicLake. It never invents percentages, byte counts, speeds, or ETAs. Contributions should preserve that rule.

## Workflow

1. Fork the repository and create a short-lived branch.
2. Run the checks locally before opening a pull request:
   ```sh
   swift build
   swift test
   ./scripts/build-release.sh
   ```
3. Keep pull requests focused. Explain what was tested and on which macOS version.
4. Do not include real device names, serial numbers, full file paths, or other personal data in issues, pull requests, or logs.

## Finder and hardware testing

If your change affects detection, please test with a real external drive when possible and document the result in `docs/TESTING.md`. Do not mark a hardware scenario as passed unless it actually ran.

## Style

- Swift 5.10, macOS 13+.
- Event-driven observers; no idle polling or directory crawls.
- Small, reviewable diffs are preferred over large refactors.
