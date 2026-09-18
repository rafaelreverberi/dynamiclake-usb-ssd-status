#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
cd "$repo_dir"

swift test
swift build -c release --arch arm64 --arch x86_64 --product transfer-center
swift build -c release --arch arm64 --arch x86_64 --product transfer-probe
archive="$($repo_dir/scripts/package-plugin.sh)"
$repo_dir/scripts/check-package.sh "$repo_dir/TransferCenter.dynamiclakeplugin"
$repo_dir/scripts/check-package.sh "$archive"
$repo_dir/scripts/socket-smoke.py "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/transfer-center"
shasum -a 256 "$archive"
