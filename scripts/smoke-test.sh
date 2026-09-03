#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="${1:-$project_dir/release/录音机.app}"

test -d "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist"
plutil -lint "$app_dir/Contents/Helpers/录音核心.app/Contents/Info.plist"
codesign --verify --deep --strict "$app_dir"
test -x "$app_dir/Contents/MacOS/qishui-capture-ui"
test -x "$app_dir/Contents/Helpers/录音核心.app/Contents/MacOS/qishui-capture"
test -x "$app_dir/Contents/Helpers/now-playing-agent"
lipo "$app_dir/Contents/MacOS/qishui-capture-ui" -verify_arch arm64 x86_64
lipo "$app_dir/Contents/Helpers/录音核心.app/Contents/MacOS/qishui-capture" -verify_arch arm64 x86_64
lipo "$app_dir/Contents/Helpers/now-playing-agent" -verify_arch arm64 x86_64
"$app_dir/Contents/Helpers/录音核心.app/Contents/MacOS/qishui-capture" --help >/dev/null
echo "录音机应用包验证通过"
