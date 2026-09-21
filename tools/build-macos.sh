#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
configuration=debug
if [[ "${1:-}" == "--release" ]]; then configuration=release
elif [[ -n "${1:-}" ]]; then echo "Usage: $0 [--release]" >&2; exit 2; fi
# 优先使用稳定的钥匙串身份，避免每次临时签名重编都改变权限身份。
signing_identity="${OLANZI_SIGNING_IDENTITY:-auto}"
if [[ "$signing_identity" == auto ]]; then
    identities=()
    while IFS= read -r identity; do
        identities+=("$identity")
    done < <(security find-identity -v -p codesigning | awk '/^[[:space:]]*[0-9]+\)/ { print $2 }')
    case ${#identities[@]} in
        0)
            signing_identity=-
            echo "Warning: no code-signing identity found; using ad-hoc signing. Rebuilds may require renewed permissions." >&2
            ;;
        1) signing_identity="${identities[0]}" ;;
        *)
            echo "Multiple code-signing identities found. Set OLANZI_SIGNING_IDENTITY to a certificate name or SHA-1 hash:" >&2
            security find-identity -v -p codesigning >&2
            exit 2
            ;;
    esac
fi
swift build --package-path "$root/native" -c "$configuration"
bin_dir="$(swift build --package-path "$root/native" -c "$configuration" --show-bin-path)"
app="$root/build/Olanzi.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Olanzi" "$app/Contents/MacOS/Olanzi"
resource_bundle="$bin_dir/Olanzi_OlanziCore.bundle"
if [[ ! -d "$resource_bundle" ]]; then
    echo "Missing localization resources: $resource_bundle" >&2
    exit 1
fi
rm -rf "$app/Contents/Resources/Olanzi_OlanziCore.bundle"
cp -R "$resource_bundle" "$app/Contents/Resources/"
cp "$root/native/Resources/Info.plist" "$app/Contents/Info.plist"
iconset="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$iconset")"' EXIT
swift "$root/tools/make-app-icon.swift" "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign "$signing_identity" --identifier com.mrcroxx.olanzi "$app"
codesign --verify --strict "$app"
codesign --display --requirements - "$app"
echo "Built: $app"
echo "Open: open \"$app\""
