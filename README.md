# Live Photo Converter（本 fork）

基于上游 [wszqkzqk/live-photo-conv](https://github.com/wszqkzqk/live-photo-conv) 0.51.0。用法、安装、源码结构完全同上——下面只说这个 fork 改了什么。

## 本 fork 的改动

### Motion Photo 1.0 合规

规范里的读取器匹配规则要求文件名主干以 `MP` 结尾，`Item:Mime` 只能是 `video/mp4` 或 `video/quicktime`。原来的实现两处都不满足：

- 输出名改为 `live_<视频名>MP.jpg`：剥掉源名的 `MVIMG`/`IMG`/`VID` 前缀和紧随的 `_`/`-`，主干补齐 `MP` 尾巴；给了主图也按视频取名，图形界面保存框的默认名同样跟随视频
- `Item:Mime` 改为读源文件 `ftyp` 的 brand，`.mov` 写 `video/quicktime`（修复功能同样处理）
- `MotionPhotoPresentationTimestampUs` 写 `0` 而不是 `-1`——真机文件都是有效数值，部分相册列表读到 `-1` 就不标动态
- 源文件元数据读不出来时只打警告，不再中断整个导出

### 后端

默认 FFmpeg，图形界面和命令行一致；GStreamer 只在显式 `--use-gst` 时用。构建里的 GStreamer 插件集不含常见消费视频的解码器，默认走它会直接报 `missing plug-in`。FFmpeg 后端要求 `ffmpeg` 与 `ffprobe` 在 `PATH` 里。

Windows 分发包另外补了三样东西，缺了同样跑不动：`gspawn-win64-helper*.exe`（GLib 起子进程用，没有就 `Failed to execute helper program`）、`libgstriff-1.0-0.dll` 与 `libgstrtp-1.0-0.dll`（`libgstisomp4` 的依赖，缺了 qtdemux 整个加载失败）。

### 目标设备

命令行加 `--brand`，图形界面里是「目标设备」下拉：

| 取值 | 写入的私有字段 |
|---|---|
| `google`（默认） | 无，标准 Motion Photo 1.0 + MicroVideo V1 |
| `oppo` | `OpCamera`：`MotionPhotoOwner="oplus"`、`OLivePhotoVersion="2"`、`VideoLength` 等 |
| `vivo` | `VCamera`：`VMotionPhotoVersion`、`VMotionPhotoSource`、`VMediaKitVersion` |
| `xiaomi` | 只写 MicroVideo V1，**不写** MotionPhoto / Container 节点 |

字段名取自真机文件，不是按规范猜的。小米真机里根本没有 `Camera:MotionPhoto` 节点。

### 界面

- 窗口固定 570×810，不能拖大、没有最大化按钮
- 「结果」里显示预计输出大小（视频字节数 + 静态图）

---

已向上游提交 PR [#85](https://github.com/wszqkzqk/live-photo-conv/pull/85)（合规）和 [#86](https://github.com/wszqkzqk/live-photo-conv/pull/86)（目标设备）。
