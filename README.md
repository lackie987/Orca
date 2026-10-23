# Orca

把 DeepSeek Harness 的 Web UI 原生封装成 macOS 应用：Swift + AppKit + WKWebView，不带 Electron。
双击即用——应用自己拉起本地 `dsh web` 服务，把界面装进原生窗口。

![Orca 窗口](docs/screenshot.png)

## 构建与安装

要求：macOS 13+、Xcode Command Line Tools（`swiftc`）。

```sh
./build.sh              # 编译 → 组装 → ad-hoc 签名 → 安装到 /Applications/Orca.app
./build.sh --no-install # 只产出 build/Orca.app
```

改完源码重复执行即可。重启应用：

```sh
osascript -e 'quit app "Orca"'; open -a /Applications/Orca.app
```

## 行为

- 默认端口 **4319**；被别的进程占用时自动改用系统分配的空闲端口。端口固定意味着页面 origin 固定，主题、上次会话等界面状态可以跨启动保留。
- 启动前检查端口，随后拉起 `dsh --profile web --port <port> --no-open`；服务就绪通常需要 3–6 秒，期间显示原生启动页。
- 启动失败时显示原因，并提供「Try Again / Service Log / Settings…」。
- 上次运行异常退出留下的服务进程会被下一次启动复用（不重新拉起，端口与登录 cookie 不变）。
- 无红绿灯、无可见标题栏：页面整幅铺满窗口，顶部页面 header 就是拖拽区（高度按页面 header 实测，兜底 40px）；点按仍先交给网页，按钮不受影响。
- 关闭窗口（⌘W）不退出应用，点 Dock 图标回到窗口；最小化 ⌘M；⌘Q 退出并停止服务。
- 菜单栏：File / Edit / View / Service / Window / Help；Edit 走系统响应链，输入框的剪切复制粘贴正常。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 刷新页面 | ⌘R |
| 从服务器重新加载 | ⌥⌘R |
| 实际大小 / 放大 / 缩小 | ⌘0 / ⌘+ / ⌘- |
| 全屏 | ⌃⌘F |
| 拖动窗口 | 按住页面顶部 header 拖动 |
| 关闭窗口（应用保留） | ⌘W |
| 最小化 | ⌘M |
| 设置 | ⌘, |
| 重启本地服务 | ⇧⌘R |
| 在浏览器打开（带 token 的地址） | ⇧⌘O |
| Web Inspector | ⌥⌘I（自动开启开发者选项） |
| 退出 | ⌘Q |

`Service → Copy Access Link` 可复制带 token 的访问地址。

## 设置

⌘, 打开设置：

- **Port**：默认 4319，`0` 表示自动挑空闲端口。
- **Profile**：默认 `web`。
- **dsh command**：PATH 中的命令名或绝对路径。GUI 启动的进程继承 launchd 的最小 PATH，应用会自动在 `~/.npm-global/bin`、`~/.local/bin`、`/opt/homebrew/bin`、`/usr/local/bin` 等目录查找。
- **Keep the local service running after Orca quits**：退出后保留服务，下次启动直接复用。
- **Enable the Web Inspector**：允许右键「检查元素」与 ⌥⌘I。

修改端口 / Profile / 命令会重启服务。改端口会改变页面 origin，主题和「上次会话」等本地状态会重置。

## 数据与日志

| 路径 | 内容 |
| --- | --- |
| `~/Library/Logs/Orca/service.log` | `dsh web` 的 stdout/stderr，含访问 URL 与 token（分享前注意脱敏） |
| `~/Library/Logs/Orca/web.log` | 页面 `console.error` 与未捕获异常 |
| `~/Library/Application Support/Orca/session.json` | 服务 pid + 访问 URL（权限 0600） |

## 代码结构

```text
Sources/Orca/
  main.swift                    应用入口
  AppDelegate.swift             生命周期、设置窗口、Help
  MainWindowController.swift    窗口、启动页状态、主题同步、菜单动作
  WebPageController.swift       WKWebView、导航策略、下载、JS 桥、对话框
  ServiceController.swift       dsh 子进程、就绪探测、复用、退出
  SplashView.swift              原生启动 / 故障页
  SettingsWindowController.swift
  MainMenu.swift
  Preferences.swift             设置项
  ServiceSession.swift          复用服务用的会话记录
  AppPaths.swift                日志与会话路径
Resources/AppIcon.icns          图标
Resources/Info.plist            bundle 元数据与 ATS/隐私说明
build.sh                        编译 + 组装 + 安装
```

## 实现说明

- **用 Web 运行时，而不是 Electron 桌面运行时**：DSH 页面把 `html[data-platform]` 当作「桌面壳」标志，会要求 `window.dshDesktop` 的原生键盘桥；WKWebView 没有这套桥，设了该属性反而会让 `dsh-client-ui-shortcuts` 启动失败。Orca 不设该属性，页面走浏览器路径。
- **无红绿灯窗口**：窗口保留 `.titled + .fullSizeContentView` 以维持阴影、圆角、缩放与全屏，只隐藏三个标准窗口按钮；`WKWebView` 子类在顶部拖拽区内把拖动转成 `performDrag`，点击先调 `super.mouseDown` 再决定，页面按钮照常响应。
- **拖拽区跟高**：注入脚本查找视口顶部、宽 ≥ 400、高 24–160 的 `<header>`，把实测高度上报给原生侧；找不到时用 40px 兜底。
- **透明 WebView**：`WKWebView.drawsBackground = false` + `underPageBackgroundColor = .clear`，页面按自己的浅/深色绘制。
- **主题**：页面把主题写在 `html[data-ds-theme-source]`，应用同步 `NSApp.appearance`，标题栏、菜单、原生对话框跟随页面明暗。
- **文件选择**：注入 `__DSH_DIRECTORY_PICKER__`，用 `NSOpenPanel` 选择工作区目录。
- **下载与外链**：`WKDownload` + `NSSavePanel` 保存文件；`target=_blank` 与站外链接交给默认浏览器。
- **隐私授权**：`dsh` 子进程以 Orca 的身份访问文件，首次打开工作区时 macOS 会询问「文稿」文件夹权限，需要允许。重建后 ad-hoc 签名变化，系统可能再次询问；可在「系统设置 → 隐私与安全性 → 文件与文件夹」中调整。

## 已知限制

- Orca 自带一个 `dsh web` 实例。如果同时开着终端里的 `dsh web`（3080），两个实例共享 `~/.dsh` 存储，会话引用与工作区状态可能互相干扰；日常使用建议只保留 Orca。
- ad-hoc 签名，未公证；从源码重建即可，不需要绕过 Gatekeeper（本机构建不带隔离属性）。
- 与 `~/Documents/dsh/Orca-app`（8 月的 Electron/WebKit + launchd 版本）互不影响，旧工程原样保留。
