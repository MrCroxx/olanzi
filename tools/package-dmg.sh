#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Olanzi.app"
if [[ $# -ne 0 ]]; then echo "Usage: $0" >&2; exit 2; fi
codesign --verify --strict "$app"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
architecture="$(lipo -archs "$app/Contents/MacOS/Olanzi" | tr ' ' '-')"
if [[ ! "$version" =~ ^[A-Za-z0-9._-]+$ || ! "$architecture" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid app version or architecture for DMG filename." >&2
    exit 1
fi
output="$root/build/Olanzi-$version-$architecture.dmg"
work="$(mktemp -d "$root/build/.dmg-XXXXXX")"
mount_point="$work/mounted"
mounted=0
detach_image() {
    local attempt
    for attempt in 1 2 3; do
        if hdiutil detach "$mount_point" -quiet; then
            mounted=0
            return 0
        fi
        sleep 1
    done
    return 1
}
cleanup() {
    local status=$?
    trap - EXIT
    # 未成功卸载时保留目录，不能递归删除仍挂载的卷。
    if [[ "$mounted" == 1 ]] && ! detach_image; then
        echo "Could not unmount $mount_point; temporary files retained at $work." >&2
        exit 1
    fi
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$work/staging" "$mount_point"
ditto "$app" "$work/staging/Olanzi.app"
ln -s /Applications "$work/staging/Applications"
cp "$app/Contents/Resources/AppIcon.icns" "$work/VolumeIcon.icns"

# 从已签名 App 的公开证书取得身份，让 DMG 与 App 使用相同证书，不导出私钥。
codesign --display --extract-certificates="$work/cert-" "$app"
signing_identity=-
if [[ -f "$work/cert-0" ]]; then
    signing_identity="$(shasum -a 1 "$work/cert-0" | awk '{print $1}')"
fi
hdiutil create -volname Olanzi -srcfolder "$work/staging" -format UDRW -fs HFS+ "$work/writable.dmg"
# 卷图标必须写入镜像内部，下载或复制 DMG 后仍然保留。
mounted=1
hdiutil attach "$work/writable.dmg" -nobrowse -mountpoint "$mount_point" -quiet
cp "$work/VolumeIcon.icns" "$mount_point/.VolumeIcon.icns"
xcrun SetFile -a C "$mount_point"
detach_image
hdiutil convert "$work/writable.dmg" -format UDZO -o "$work/Olanzi.dmg"
swift "$root/tools/set-file-icon.swift" "$work/VolumeIcon.icns" "$work/Olanzi.dmg"
codesign --force --sign "$signing_identity" --identifier com.mrcroxx.olanzi.dmg "$work/Olanzi.dmg"
codesign --verify --strict "$work/Olanzi.dmg"
hdiutil verify "$work/Olanzi.dmg"

# 用实际挂载后的文件验证签名、内容与安装入口，验证成功才替换上次产物。
mounted=1
hdiutil attach "$work/Olanzi.dmg" -readonly -nobrowse -mountpoint "$mount_point" -quiet
codesign --verify --strict "$mount_point/Olanzi.app"
diff -qr "$app" "$mount_point/Olanzi.app"
[[ -L "$mount_point/Applications" && "$(readlink "$mount_point/Applications")" == /Applications ]]
cmp "$work/VolumeIcon.icns" "$mount_point/.VolumeIcon.icns"
[[ "$(xcrun GetFileInfo -a "$mount_point")" == *C* ]]
[[ "$(xcrun GetFileInfo -a "$work/Olanzi.dmg")" == *C* ]]
detach_image
mv -f "$work/Olanzi.dmg" "$output"
echo "DMG: $output"
echo "Install: open the DMG and drag Olanzi into Applications."
