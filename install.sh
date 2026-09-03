#!/bin/bash
set -euo pipefail

repo="aerfagogogo/qishui-audio-capture"
asset="Recorder-macOS.zip"
download_url="${RECORDER_RELEASE_URL:-https://github.com/${repo}/releases/latest/download/${asset}}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "录音机只支持 macOS。" >&2
  exit 1
fi

major_version="$(sw_vers -productVersion | cut -d. -f1)"
if (( major_version < 15 )); then
  echo "录音机需要 macOS 15 或更新版本。" >&2
  exit 1
fi

case "$(uname -m)" in
  arm64|x86_64) ;;
  *) echo "不支持当前处理器架构：$(uname -m)" >&2; exit 1 ;;
esac

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/recorder-install.XXXXXX")"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

echo "正在下载录音机…"
curl -fL --retry 3 \
  "$download_url" \
  -o "$work_dir/$asset"
if [[ -z "${RECORDER_RELEASE_URL:-}" ]]; then
  curl -fL --retry 3 "${download_url}.sha256" -o "$work_dir/${asset}.sha256"
  (cd "$work_dir" && shasum -a 256 -c "${asset}.sha256")
fi
ditto -x -k "$work_dir/$asset" "$work_dir/unpacked"

source_app="$work_dir/unpacked/录音机.app"
if [[ ! -x "$source_app/Contents/MacOS/qishui-capture-ui" ]]; then
  echo "下载的应用包不完整，已停止安装。" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "需要 FFmpeg，正在安装 Homebrew…"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi
  echo "正在安装 FFmpeg…"
  brew install ffmpeg
fi

install_root="${RECORDER_INSTALL_ROOT:-/Applications}"
if [[ -z "${RECORDER_INSTALL_ROOT:-}" && ! -w "$install_root" ]]; then
  install_root="$HOME/Applications"
fi
mkdir -p "$install_root"
target_app="$install_root/录音机.app"

if [[ -e "$target_app" ]]; then
  backup_dir="$HOME/.Trash/录音机-旧版本-$(date +%Y%m%d-%H%M%S).app"
  echo "正在把旧版本移到废纸篓…"
  mv "$target_app" "$backup_dir"
fi

echo "正在安装到 $target_app …"
ditto "$source_app" "$target_app"
xattr -dr com.apple.quarantine "$target_app" 2>/dev/null || true
codesign --verify --deep --strict "$target_app"
if [[ "${RECORDER_SKIP_OPEN:-0}" != "1" ]]; then
  open "$target_app"
fi

echo "安装完成：$target_app"
