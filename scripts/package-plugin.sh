#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
cd "$repo_dir"

bin_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
binary="$bin_dir/usb-ssd-status"
[[ -x "$binary" ]] || { print -u2 "Release binary is missing. Run scripts/build-release.sh first."; exit 1; }

package="$repo_dir/USB-SSD-Status.dynamiclakeplugin"
development_package="$repo_dir/USB-SSD-Status-Development.dynamiclakeplugin"
dist="$repo_dir/dist"
mkdir -p "$package" "$development_package" "$dist"

cp "$binary" "$package/usb-ssd-status"
cp "$repo_dir/plugin.json" "$package/plugin.json"
cp "$repo_dir/Assets/icon.png" "$package/icon.png"
cp "$repo_dir/Assets/drive-transfer-symbol.png" "$package/drive-transfer-symbol.png"
cp "$repo_dir/PrivacyInfo.xcprivacy" "$package/PrivacyInfo.xcprivacy"
chmod 755 "$package/usb-ssd-status"
codesign --force --sign - --timestamp=none "$package/usb-ssd-status"

cp "$package/usb-ssd-status" "$development_package/usb-ssd-status"
cp "$package/icon.png" "$development_package/icon.png"
cp "$package/drive-transfer-symbol.png" "$development_package/drive-transfer-symbol.png"
cp "$package/PrivacyInfo.xcprivacy" "$development_package/PrivacyInfo.xcprivacy"
jq '.identifier = "com.rafaelreverberi.plugins.usb-ssd-status.development" | .name = "USB / SSD Status Development" | .version = (.version + "-dev") | .arguments = ["--mock-transfer", "--debug"]' \
  "$repo_dir/plugin.json" > "$development_package/plugin.json"
chmod 755 "$development_package/usb-ssd-status"
codesign --force --sign - --timestamp=none "$development_package/usb-ssd-status"

version="$(jq -r .version "$repo_dir/plugin.json")"
archive="$dist/USB-SSD-Status-$version.dynamiclakeplugin.zip"
rm -f "$archive"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$package" "$archive"

print "$archive"
