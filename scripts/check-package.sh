#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
target="${1:-$repo_dir/TransferCenter.dynamiclakeplugin}"
work_dir=""

if [[ "$target" == *.zip ]]; then
  if unzip -Z1 "$target" | grep -E -q '(^|/)(\.DS_Store|\._[^/]+|__MACOSX)(/|$)'; then
    print -u2 "Archive contains Finder or AppleDouble metadata."
    exit 1
  fi
  work_dir="$(mktemp -d -t transfer-center-package-check)"
  trap 'rm -rf "$work_dir"' EXIT
  ditto -x -k "$target" "$work_dir"
  packages=("$work_dir"/*.dynamiclakeplugin(N))
  (( ${#packages} == 1 )) || { print -u2 "Archive must contain exactly one .dynamiclakeplugin package."; exit 1; }
  package="${packages[1]}"
  archive_size="$(stat -f %z "$target")"
  (( archive_size <= 7 * 1024 * 1024 )) || { print -u2 "Archive exceeds 7 MB."; exit 1; }
else
  package="$target"
fi

[[ -d "$package" ]] || { print -u2 "Package not found: $package"; exit 1; }
[[ -f "$package/plugin.json" ]] || { print -u2 "plugin.json is missing."; exit 1; }
(( $(stat -f %z "$package/plugin.json") <= 128 * 1024 )) || { print -u2 "plugin.json exceeds 128 KB."; exit 1; }
jq -e '
  .schemaVersion == 1 and
  (.identifier | type == "string" and length >= 3 and length <= 128 and test("^[A-Za-z0-9._-]+$")) and
  (.name | type == "string" and length >= 1 and length <= 80) and
  (.version | type == "string" and length >= 1 and length <= 40) and
  (.developerName | type == "string") and
  (.executable | type == "string" and length > 0) and
  (.icon | type == "string" and length > 0) and
  (.arguments | type == "array") and
  (.autoStart | type == "boolean") and
  ((.settings // []) | type == "array" and length <= 24 and all(.[]; .type == "switch" or .type == "slider" or .type == "select" or .type == "button"))
' "$package/plugin.json" >/dev/null

executable="$(jq -r .executable "$package/plugin.json")"
icon="$(jq -r .icon "$package/plugin.json")"
[[ "$executable" != /* && "$executable" != *..* ]] || { print -u2 "Executable path must stay inside the package."; exit 1; }
[[ "$icon" != /* && "$icon" != *..* ]] || { print -u2 "Icon path must stay inside the package."; exit 1; }
[[ -x "$package/$executable" ]] || { print -u2 "Executable is missing or not executable: $executable"; exit 1; }
[[ -f "$package/$icon" ]] || { print -u2 "Icon is missing: $icon"; exit 1; }
[[ -f "$package/drive-transfer-symbol.png" ]] || { print -u2 "Inline drive artwork is missing."; exit 1; }
file "$package/$executable" | grep -E -q 'Mach-O universal binary.*x86_64.*arm64|Mach-O universal binary.*arm64.*x86_64'

width="$(sips -g pixelWidth "$package/$icon" | awk '/pixelWidth/ {print $2}')"
height="$(sips -g pixelHeight "$package/$icon" | awk '/pixelHeight/ {print $2}')"
[[ "$width" == "$height" ]] || { print -u2 "Icon must be square."; exit 1; }
[[ "${icon:e:l}" == "png" ]] || { print -u2 "Icon must be PNG."; exit 1; }
(( $(stat -f %z "$package/$icon") <= 1572864 )) || { print -u2 "Icon exceeds 1.5 MB."; exit 1; }
(( $(stat -f %z "$package/drive-transfer-symbol.png") <= 49152 )) || { print -u2 "Inline drive artwork exceeds DynamicLake's 48 KB decoded-image limit."; exit 1; }
[[ "$(sips -g hasAlpha "$package/drive-transfer-symbol.png" | awk '/hasAlpha/ {print $2}')" == "yes" ]] || { print -u2 "Inline drive artwork must have alpha transparency."; exit 1; }

if find "$package" \( -name .DS_Store -o -name '._*' -o -name __MACOSX -o -name '*.swift' -o -name '*.dSYM' -o -name Package.swift \) | grep -q .; then
  print -u2 "Package contains forbidden source/debug metadata."
  exit 1
fi

package_kb="$(du -sk "$package" | awk '{print $1}')"
(( package_kb <= 20 * 1024 )) || { print -u2 "Unpacked package exceeds 20 MB."; exit 1; }
codesign --verify --strict "$package/$executable"
plutil -lint "$package/PrivacyInfo.xcprivacy" >/dev/null

print "Package valid: $package"
print "Unpacked size: ${package_kb} KB"
if [[ "$target" == *.zip ]]; then
  print "Archive size: ${archive_size} bytes"
fi
exit 0
