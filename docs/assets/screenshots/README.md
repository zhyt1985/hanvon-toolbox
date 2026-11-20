# README 截图维护

这三张 PNG 来自现有 SwiftUI 视图，使用纯合成数据演示文件管理、传输记录与内容导出。它们不代表真机连接、任务执行或验收结果。不要用真实设备截图替换。

在项目根目录运行（macOS 26、Xcode、Apple Silicon Homebrew libusb）：

```sh
python3 scripts/render-readme-screenshots.py
```

脚本在 `.build` 中建立独立临时 Swift Package，复制当前视图及依赖，用隔离后的模型替换启动时的设置、历史和发现加载，再注入合成数据。不会启动正式工具箱、读取钥匙串、连接设备或使用签名材料；产品源码保持不变。会短暂显示三个演示窗口，用 AppKit 缓存显示内容生成图片，不采集桌面或其他窗口。SwiftUI 与系统字体版本变化可能影响渲染，因此不保证跨系统像素一致。

生成时移除图片附加元数据，保留原像素。逐张打开图片核对文字完整、无裁切，以及没有真实路径、账号、网络地址、设备标识、配对码或私人内容。审阅后再执行：

```sh
python3 scripts/render-readme-screenshots.py --record-review
```

此命令只记录已存在图片的精确摘要和尺寸，不自动证明图片安全。把图片和 `reviewed.json` 一起暂存，然后运行仓库隐私检查并人工审阅：

```sh
python3 scripts/privacy-check.py --staged --identity
git diff --cached
```

检查器仅放行三个指定文件名、匹配清单且无文本/EXIF 等附加元数据的 PNG。其他图片继续拦截；暂存区与历史分别使用各自版本中的清单，工作区中的新清单不能为旧图片放行。
