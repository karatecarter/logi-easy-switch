#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
output_dir="$project_dir/dist"
build_dir="$project_dir/.build/app"
export CLANG_MODULE_CACHE_PATH="$output_dir/ModuleCache/Clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$output_dir/ModuleCache/SwiftPM"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
# Use the active toolchain's SDK; IT can pin another installed SDK explicitly.
logi_sdk=${LOGI_MACOS_SDK:-macosx}
SDKROOT=$(xcrun --sdk "$logi_sdk" --show-sdk-path)
export SDKROOT

swift build --package-path "$project_dir" --configuration release --disable-sandbox --build-path "$build_dir"

app_path="$output_dir/Switchboard.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$build_dir/release/Switchboard" "$app_path/Contents/MacOS/Switchboard"
cp "$project_dir/Packaging/Info.plist" "$app_path/Contents/Info.plist"
cp "$project_dir/Assets/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
# Set LOGI_SIGNING_IDENTITY to an IT-approved Developer ID identity for release
# distribution. Ad-hoc signing remains available for local development.
signing_identity=${LOGI_SIGNING_IDENTITY:--}
if [[ "$signing_identity" == "-" ]]; then
    codesign --force --entitlements "$project_dir/Packaging/Switchboard.entitlements" --options runtime --sign - "$app_path"
else
    codesign --force --entitlements "$project_dir/Packaging/Switchboard.entitlements" --options runtime --timestamp --sign "$signing_identity" "$app_path"
fi
codesign --verify --deep --strict "$app_path"

# Rebuilt ad-hoc apps can retain stale TCC decisions. Reset only this app's
# privacy permissions so macOS can request fresh consent on the next launch.
# CI/distribution builds can opt out without affecting the produced bundle.
if [[ "${SWITCHBOARD_RESET_PERMISSIONS:-1}" != "0" ]]; then
    switchboard_bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Contents/Info.plist")
    if [[ -z "$switchboard_bundle_id" ]]; then
        print -u2 "Cannot reset permissions: the built app has no bundle identifier."
        exit 1
    fi
    if ! /usr/bin/tccutil reset All "$switchboard_bundle_id"; then
        print -u2 "Warning: could not reset macOS privacy permissions for $switchboard_bundle_id."
        print -u2 "The app was built successfully; reset its permissions manually if needed."
    fi
fi
echo "$app_path"
