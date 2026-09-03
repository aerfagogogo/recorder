# macOS 应用音频录制

这是一个 macOS 原生录音工具，包含可双击运行的图形界面和命令行版本。它使用 Apple ScreenCaptureKit 捕获指定应用已经解码并正在播放的系统音频，先写入无压缩 PCM，再转换为所选格式。

它不读取应用缓存，也不绕过 DRM、会员权限或平台访问控制。歌曲名称和进度来自 macOS 的系统“正在播放”信息。只应用于你有权保存的音频；保存和使用时请遵守版权法律及相关平台条款。

## 一键安装

适用于 macOS 15 或更新版本，同时支持 Apple 芯片和 Intel Mac：

```bash
curl -fsSL https://raw.githubusercontent.com/aerfagogogo/qishui-audio-capture/main/install.sh | bash
```

安装程序会下载最新版本到“应用程序”，缺少 FFmpeg 时会通过 Homebrew 安装，并在完成后打开“录音机”。首次录音时，请按系统提示允许“系统音频录制”。

## 环境

- macOS 15 或更新版本
- Swift 6.2 / Xcode Command Line Tools（仅从源码编译需要）
- FFmpeg（默认寻找 `/opt/homebrew/bin/ffmpeg` 或 `/usr/local/bin/ffmpeg`）

## 编译

```bash
swift build -c release
```

打包图形应用：

```bash
./scripts/package-app.sh
open "dist/录音机.app"
```

## 图形界面

1. 从下拉列表选择正在运行的音乐播放器。
2. 可点“读取当前歌曲”预览歌名、歌手、专辑和总时长。
3. 选择录制模式和 FLAC、WAV、MP3、ALAC 或 AAC 格式。
4. 点“开始录制”让工具进入等待，再从歌曲开头播放。

录制模式：

- 单曲：完整录完一首后自动停止和保存；如果中途停止或跳到别的歌，未完成片段丢弃。
- 连续：每首完整播完后记录分轨边界。人工停止、播放器退出或意外中断时，之前完整播放的歌曲分别保存，正在播放的半截歌曲丢弃。

两种模式都由常驻的轻量歌曲信息助手读取 macOS“正在播放”信息，并用实时进度、总时长和曲目切换判断边界；不使用截图、像素识别或界面文字扫描。

默认保存到 `~/Music/汽水录音`。同名文件不会被覆盖，而是自动添加数字后缀。

“置顶并显示在所有桌面”默认开启。开启后窗口使用浮动层级，并在所有 macOS Space 和全屏桌面中显示；关闭后恢复普通窗口行为。

“读取当前歌曲”会读取所选播放器当前歌曲的歌名、歌手、专辑和总时长；系统未提供专辑时会尝试通过公开音乐目录补全。应用只需要“屏幕与系统音频录制”权限，不需要辅助功能权限。

目标应用使用正在运行的音乐播放器下拉列表，并向录制核心传递精确 Bundle ID，避免名称相似的应用被误选。打开新的播放器后点“刷新”即可更新。

“转换已有音频”支持 FLAC、WAV、MP3、M4A 等输入，并可转换为 FLAC、WAV、MP3、ALAC 或 AAC。选择文件后会自动读取其歌名、歌手和专辑标签；转换结果保存在原文件旁边，原文件不会被覆盖。

- FLAC：无损压缩，适合收藏。
- WAV：24-bit/48 kHz PCM，适合 PAW 类播放器、录音笔和嵌入式解码设备。
- MP3：320 kbps，兼容性最广。
- ALAC：Apple 无损，输出为 M4A。
- AAC：256 kbps，输出为 M4A。

## 使用

先打开汽水音乐并把播放位置停在歌曲开头，然后：

```bash
.build/release/qishui-capture --list-apps
.build/release/qishui-capture --app 汽水 \
  --format flac \
  --title "百里芭蕉百里花" \
  --artist "梦里梦外" \
  --album "爱在时光里回响" \
  --audio-seconds 241 \
  --output "Captures/百里芭蕉百里花.flac"
```

工具启动后再按播放。检测到有声以后，连续两秒低于 `-50 dBFS` 会自动结束；也可以按 `Control-C` 手动结束。

已知歌曲时长时，建议使用 `--audio-seconds`。计时从第一段高于静音阈值的声音开始，因此准备和点击播放所花的时间不会算进歌曲时长。

转换时默认裁掉录制开始和结束处低于 `-70 dBFS` 的数字静音。全程没有检测到声音时会返回失败并保留 WAV 诊断文件，不会把静音文件误报为成品。

如果歌曲中有很长的安静段，可以延长自动停止时间：

```bash
.build/release/qishui-capture --app 汽水 \
  --silence-seconds 5 \
  --max-seconds 360 \
  --output "Captures/百里芭蕉百里花.flac"
```

首次运行时，macOS 会请求“屏幕与系统音频录制”权限。授权后可能需要退出终端或 Codex，再重新运行。

## 音质说明

FLAC 对捕获到的 PCM 数据进行无损压缩，不会产生二次有损编码。但它不能恢复播放源中此前已经损失的音频信息。
