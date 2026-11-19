# Screen Translate

Screen Translate 是一个 macOS 菜单栏工具。框选屏幕区域后，它会把简体中文译文覆盖到截图中的原文位置。

## 使用

1. 解压 GitHub Release 中的 `Screen-Translate-macOS.zip`，将 **Screen Translate.app** 拖到「应用程序」并打开。
2. 按 **⌃⇧T** 框选区域。首次使用时，按 macOS 提示在「隐私与安全性 → 屏幕与系统音频录制」里授权，然后重新打开应用。
3. 在译图窗口点击「查看原图」切换视图，或点击「复制译文」。按 **⌘W** 关闭窗口。
4. 点击菜单栏图标，选择「快捷键 → 自定义…」更改快捷键。

需要 macOS 15 或更新版本，支持 Apple 芯片与 Intel Mac。下载包采用临时代码签名，未经 Apple 公证。

截图使用 macOS 自带的截图工具，文字识别和翻译分别使用 Apple Vision 和 Translation 框架。Apple 的语言包可能需要首次下载。当前按截图中的主要源语言翻译。

## 从源码构建

安装 Xcode Command Line Tools 后，在项目目录运行 `zsh build.sh`。应用和分享包会生成在 `dist`。运行 `zsh install.sh` 可将构建产物安装到「应用程序」。

应用图标来自 Apple「翻译」应用。
