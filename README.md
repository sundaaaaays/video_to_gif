# 🎬 短视频转GIF工具（纯本地离线）

一款 Android 短视频转 GIF 工具，**全部在手机本地运算，不上传任何网络**。

## ✨ 功能特性

- 📹 从系统相册选择本地 MP4 视频（走系统选择器，无需存储权限）
- 🎞️ 自定义 GIF 帧率（FPS 1~30，**真正生效**，转换后自动回读验证帧数）
- 📐 等比缩放输出分辨率（自定义宽度，高度自动）
- ✂️ 拖拽滑块截取视频起止时间片段
- 🎨 可选双通道调色板（颜色更细腻）
- 💾 输出自动保存到系统相册 `Pictures/GIFTools`
- 🚫 无后端、无在线 API，**100% 本地 ffmpeg 处理**

## 🛠️ 技术栈

| 组件 | 说明 |
|---|---|
| Flutter 3.44+ | UI 框架 |
| ffmpeg_kit_flutter_new 4.6.2 | 社区维护版 FFmpeg 内核（FFmpeg 8.1，纯本地） |
| Android 原生通道 | 选视频（Intent）+ 保存（MediaStore） |

## 📱 安装

下载 `app-arm64-v8a-release.apk`（或对应架构）安装到手机，允许"未知来源"即可。

> Android 10+ 无需任何存储权限；Android 9 及以下会请求存储权限。

## 🚀 使用

1. 打开 App → 点 **从相册选择** → 选一个 MP4 视频
2. 拖动滑块选择**开始/结束时间**（截取片段）
3. 设置 **FPS**（1~30，建议 10~20 画质/体积平衡）和**输出宽度**
4. 点 **转为 GIF** → 等待转换完成
5. 完成后会显示 **实际输出帧数**（验证 FPS 生效）→ 到相册 `Pictures/GIFTools` 查看

## 🔨 本地构建（开发者）

```bash
# 环境：Flutter 3.44+、JDK 17/18、Android SDK
flutter pub get
flutter run -d <设备ID>          # 真机调试
flutter build apk --release --split-per-abi   # 打包 APK
```

> ⚠️ 注意：ffmpeg 内核为社区维护版 `ffmpeg_kit_flutter_new`，API 与原版 ffmpeg-kit 不同。

## 📁 项目结构

```
lib/
├─ main.dart        # UI + 转换逻辑（fps=N 过滤器 + ffprobe 帧数验证）
└─ gif_saver.dart   # 保存 GIF 到相册
android/
└─ .../MainActivity.kt  # 原生选视频 + MediaStore 保存
```
界面截图：
<img width="1088" height="2181" alt="38a1ea352d1ec51339283ee83c0c73e0" src="https://github.com/user-attachments/assets/8512be0f-6b51-4476-8627-99db5fc592ea" />
