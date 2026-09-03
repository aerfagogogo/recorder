#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/录音机.app"
contents_dir="$app_dir/Contents"
helper_dir="$contents_dir/Helpers/录音核心.app"
helper_contents="$helper_dir/Contents"

cd "$project_dir"
swift build -c release

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$helper_contents/MacOS"
cp ".build/release/qishui-capture-ui" "$contents_dir/MacOS/qishui-capture-ui"
cp ".build/release/qishui-capture" "$helper_contents/MacOS/qishui-capture"
cp "AppBundle/Info.plist" "$contents_dir/Info.plist"
cp "AppBundle/CaptureInfo.plist" "$helper_contents/Info.plist"
cp "AppBundle/NowPlayingAgent.swift" "$contents_dir/Resources/NowPlayingAgent.swift"
swiftc -O "AppBundle/NowPlayingAgent.swift" -o "$contents_dir/Helpers/now-playing-agent"
chmod +x "$contents_dir/MacOS/qishui-capture-ui" "$helper_contents/MacOS/qishui-capture"
chmod +x "$contents_dir/Helpers/now-playing-agent"
rm -f "$contents_dir/MacOS/qishui-capture"

capture_requirement='=designated => identifier "com.sunyiting.qishui-audio-capture.capture"'
app_requirement='=designated => identifier "com.sunyiting.qishui-audio-capture"'

# Explicit designated requirements keep macOS TCC permissions stable across
# local ad-hoc rebuilds. The default ad-hoc requirement is the changing CDHash.
codesign --force --sign - "$contents_dir/Helpers/now-playing-agent"
codesign \
  --force \
  --sign - \
  --identifier "com.sunyiting.qishui-audio-capture.capture" \
  --requirements "$capture_requirement" \
  "$helper_dir"
codesign \
  --force \
  --sign - \
  --identifier "com.sunyiting.qishui-audio-capture" \
  --requirements "$app_requirement" \
  "$app_dir"
echo "$app_dir"
