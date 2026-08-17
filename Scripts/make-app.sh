#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
output_dir="$project_dir/dist"
build_dir="$project_dir/.build/app"
export CLANG_MODULE_CACHE_PATH="$output_dir/ModuleCache/Clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$output_dir/ModuleCache/SwiftPM"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

swift build --package-path "$project_dir" --configuration release --disable-sandbox --build-path "$build_dir"

app_path="$output_dir/Logi Easy Switch.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$build_dir/release/LogiEasySwitch" "$app_path/Contents/MacOS/LogiEasySwitch"
cp "$project_dir/Packaging/Info.plist" "$app_path/Contents/Info.plist"
cp "$project_dir/Assets/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_path"
echo "$app_path"
