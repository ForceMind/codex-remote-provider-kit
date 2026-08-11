# macOS 图标资源

- `codex-rp-icon-1024.png`：用于维护和再生成的 1024×1024 源图。
- `codex-rp.icns`：安装到 `Codex Remote Provider Kit.app` 的生产图标，内含
  16、32、64、128、256、512 和 1024 像素 PNG 块。

图标由 OpenAI 内置图像生成工具为本项目原创生成，未使用 OpenAI、ChatGPT、
Apple 或其他第三方商标。设计使用终端箭头、连接节点和远程信号弧线，
用深蓝、青色和靛蓝表达受控的远程 provider 连接。

## 生成规格

```text
Use case: logo-brand
Asset type: production macOS application icon, square 1024x1024 source
Primary request: Create an original, polished macOS app icon for a utility named
Codex Remote Provider Kit. Convey a secure remote connection to a developer
terminal/provider switcher.
Subject: a crisp abstract terminal prompt chevron combined with two connected
nodes and subtle radio-signal arcs, centered as one memorable symbol
Style/medium: premium modern macOS icon, dimensional layered 3D vector-like
rendering, restrained glass and soft metal materials, excellent legibility at 16px
Color palette: deep navy and charcoal background, electric cyan to indigo accents,
with a small restrained mint status highlight
Constraints: original design; no text, letters, watermark, OpenAI/ChatGPT/Apple
logos or other third-party trademarks; strong silhouette; edge-safe for macOS masks
```

修改源图后必须重新生成全部尺寸并验证 `.icns` 可被 macOS `iconutil` 反向解包；不要
只替换某一个小尺寸，也不要在安装脚本运行时动态下载图标。
