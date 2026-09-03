#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
release_dir="$project_dir/release"
arm_build="$project_dir/.build-arm64"
x86_build="$project_dir/.build-x86_64"
app_dir="$release_dir/录音机.app"
contents_dir="$app_dir/Contents"
capture_app="$contents_dir/Helpers/录音核心.app"
capture_contents="$capture_app/Contents"

cd "$project_dir"
rm -rf "$release_dir"
swift build -c release --triple arm64-apple-macosx15.0 --scratch-path "$arm_build"
swift build -c release --triple x86_64-apple-macosx15.0 --scratch-path "$x86_build"

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$capture_contents/MacOS"
lipo -create \
  "$arm_build/arm64-apple-macosx/release/qishui-capture-ui" \
  "$x86_build/x86_64-apple-macosx/release/qishui-capture-ui" \
  -output "$contents_dir/MacOS/qishui-capture-ui"
lipo -create \
  "$arm_build/arm64-apple-macosx/release/qishui-capture" \
  "$x86_build/x86_64-apple-macosx/release/qishui-capture" \
  -output "$capture_contents/MacOS/qishui-capture"

swiftc -O -target arm64-apple-macosx15.0 AppBundle/NowPlayingAgent.swift \
  -o "$release_dir/now-playing-agent-arm64"
swiftc -O -target x86_64-apple-macosx15.0 AppBundle/NowPlayingAgent.swift \
  -o "$release_dir/now-playing-agent-x86_64"
lipo -create \
  "$release_dir/now-playing-agent-arm64" \
  "$release_dir/now-playing-agent-x86_64" \
  -output "$contents_dir/Helpers/now-playing-agent"

cp AppBundle/Info.plist "$contents_dir/Info.plist"
cp AppBundle/CaptureInfo.plist "$capture_contents/Info.plist"
cp AppBundle/NowPlayingAgent.swift "$contents_dir/Resources/NowPlayingAgent.swift"
chmod +x "$contents_dir/MacOS/qishui-capture-ui" \
  "$capture_contents/MacOS/qishui-capture" \
  "$contents_dir/Helpers/now-playing-agent"

capture_requirement='=designated => identifier "com.sunyiting.qishui-audio-capture.capture"'
app_requirement='=designated => identifier "com.sunyiting.qishui-audio-capture"'
codesign --force --sign - "$contents_dir/Helpers/now-playing-agent"
codesign --force --sign - \
  --identifier "com.sunyiting.qishui-audio-capture.capture" \
  --requirements "$capture_requirement" "$capture_app"
codesign --force --sign - \
  --identifier "com.sunyiting.qishui-audio-capture" \
  --requirements "$app_requirement" "$app_dir"

ditto -c -k --keepParent "$app_dir" "$release_dir/Recorder-macOS.zip"
(cd "$release_dir" && shasum -a 256 "Recorder-macOS.zip" > "Recorder-macOS.zip.sha256")
echo "$release_dir/Recorder-macOS.zip"
