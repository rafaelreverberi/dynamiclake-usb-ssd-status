#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
cd "$repo_dir"

bin_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
binary="$bin_dir/transfer-center"
[[ -x "$binary" ]] || { print -u2 "Release binary is missing. Run scripts/build-release.sh first."; exit 1; }

package="$repo_dir/TransferCenter.dynamiclakeplugin"
development_package="$repo_dir/TransferCenter-Development.dynamiclakeplugin"
dist="$repo_dir/dist"
mkdir -p "$package" "$development_package" "$dist"

cp "$binary" "$package/transfer-center"
cp "$repo_dir/plugin.json" "$package/plugin.json"
cp "$repo_dir/Assets/icon.png" "$package/icon.png"
cp "$repo_dir/PrivacyInfo.xcprivacy" "$package/PrivacyInfo.xcprivacy"
chmod 755 "$package/transfer-center"
codesign --force --sign - --timestamp=none "$package/transfer-center"

cp "$package/transfer-center" "$development_package/transfer-center"
cp "$package/icon.png" "$development_package/icon.png"
cp "$package/PrivacyInfo.xcprivacy" "$development_package/PrivacyInfo.xcprivacy"
jq '.identifier = "com.rafaelreverberi.plugins.transfer-center.development" | .name = "Transfer Center Development" | .version = (.version + "-dev") | .arguments = ["--mock-transfer", "--debug"]' \
  "$repo_dir/plugin.json" > "$development_package/plugin.json"
chmod 755 "$development_package/transfer-center"
codesign --force --sign - --timestamp=none "$development_package/transfer-center"

version="$(jq -r .version "$repo_dir/plugin.json")"
archive="$dist/TransferCenter-$version.dynamiclakeplugin.zip"
rm -f "$archive"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$package" "$archive"

print "$archive"
