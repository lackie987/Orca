# Orca

把 DeepSeek Harness 的 Web UI 原生封装成 macOS 应用：Swift + AppKit + WKWebView，不带 Electron。
双击即用——应用自己拉起本地 `dsh web` 服务，把界面装进原生窗口。

![Orca 窗口](docs/screenshot.png)

## 构建与安装

要求：macOS 13+、Xcode Command Line Tools（`swiftc`）。

```sh
./build.sh              # 编译 → 组装 → ad-hoc 签名 → 安装到 /Applications/Orca.app
./build.sh --no-install # 只产出 build/Orca.app
./package.sh            # 出安装包到 dist/：Orca-1.0.0.dmg + Orca-1.0.0.pkg + SHA256SUMS.txt
```

改完源码重复执行即可。重启应用：

```sh
osascript -e 'quit app "Orca"'; open -a /Applications/Orca.app
```

### 安装包

`package.sh` 读 `Resources/Info.plist` 里的版本号，产出两个等价的分发件：

| 产物 | 用法 |
|---|---|
| `Orca-<版本>.pkg` | 双击安装，`installer` 直接写 `/Applications`，指定了最低系统版本 |
| `Orca-<版本>.dmg` | 打开后把 Orca 拖进 Applications，盘内附 `READ ME.txt` |

```sh
./package.sh --no-pkg   # 只要 dmg
./package.sh --no-dmg   # 只要 pkg
```

版本号只写在 `Resources/Info.plist` 一处（`CFBundleShortVersionString` / `CFBundleVersion`），
打包与安装包命名都从那里取，不要另建一处。

两个件都是 **ad-hoc 签名**（本机没有 Developer ID 证书，`security find-identity` 为 0 个身份），
所以拷到别的机器上首次打开会被 Gatekeeper 拦一次：右键「打开」，或到
「系统设置 → 隐私与安全性 → 仍要打开」。要彻底免掉这一步，需要开发者证书：

```sh
ORCA_SIGN_IDENTITY="Developer ID Application: …" \
ORCA_INSTALLER_IDENTITY="Developer ID Installer: …" ./package.sh
```

二进制目前是 **arm64 only**——`swift build --arch arm64 --arch x86_64` 需要完整 Xcode
（本机只装了 CommandLineTools，多架构构建会报 `xcbuild … does not exist`）。要出通用包得先装 Xcode。

## 行为

- 默认端口 **4319**；被别的进程占用时自动改用系统分配的空闲端口。端口固定意味着页面 origin 固定，主题、上次会话等界面状态可以跨启动保留。
- 启动前检查端口，随后拉起 `dsh --profile web --port <port> --no-open`；服务就绪通常需要 3–6 秒，期间显示原生启动页：透明磨砂玻璃底，图标圆角与窗口圆角一致。
- 重启本地服务（⇧⌘R、改设置或启动页按钮）走同一张启动页，只有进度条没有按钮。
- 交接时机：启动页不在「服务就绪」时撤，等的是页面自己的**首帧事件**——注入脚本在 `load` 之后连等两帧 `requestAnimationFrame`，再 `postMessage` 给壳（`orcaPagePainted`），壳收到就淡出。全程没有「先等 N 秒」这种写死的等待，只有淡出本身有固定时长（0.45s，开了「减弱动态效果」则为 0）。web view 自身不画背景、容器铺的是主题 base，所以淡出过程与首帧之间的任何缝隙看到的都是页面自己的颜色，不是默认窗口灰。
- 兜底：页面加载失败（`didFail*`）立即撤；页面 12 秒仍未报首帧（脚本被拦等极端情况）也强行撤，避免启动页焊死。
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
  MainWindowController.swift    窗口、启动页状态与交接、主题同步、菜单动作
  WindowChrome.swift            标题栏档位、红绿灯显隐与 hover 带
  SplashView.swift              原生启动 / 故障页（磨砂底 + 主题基色）
  WebPageController.swift       WKWebView 本体、注入、缩放、全屏镜像
  WebPageScripts.swift          注入脚本（三个桥 + 拖拽带 + 主题 + 首帧）
  WebPageBridges.swift          页面消息通道（含 get/set 桥的共用骨架）
  WebPageNavigation.swift       导航策略与内部 URL 判定
  WebPageDialogs.swift          JS 弹窗、权限、下载与面板呈现
  WebDiagnostics.swift          页面 console 日志
  ServiceController.swift       dsh 子进程、就绪探测、复用、退出
  ServiceCommand.swift          命令解析与 shell 引用
  PortProbe.swift               端口占用探测
  SettingsWindowController.swift
  MainMenu.swift
  Preferences.swift             设置项
  ServiceSession.swift          复用服务用的会话记录
  AppPaths.swift                日志与会话路径
  LogFile.swift                 日志文件的轮转与开写
  Layout.swift                  铺满父视图的约束助手
  TitleBarMode.swift            红绿灯档位
  WindowMetrics.swift           窗口圆角（启动页图标与之对齐）
  ColorHex.swift                #rrggbb ↔ NSColor、亮度判断
Resources/AppIcon.icns          图标
Resources/Info.plist            bundle 元数据与 ATS/隐私说明
build.sh                        编译 + 组装 + 安装
package.sh                      打 DMG / PKG 安装包（dist/，附 SHA-256）
```

## 实现说明

- **用 Web 运行时，而不是 Electron 桌面运行时**：DSH 页面把 `html[data-platform]` 当作「桌面壳」标志，会要求 `window.dshDesktop` 的原生键盘桥；WKWebView 没有这套桥，设了该属性反而会让 `dsh-client-ui-shortcuts` 启动失败。Orca 不设该属性，页面走浏览器路径。
- **无红绿灯窗口**：窗口保留 `.titled + .fullSizeContentView` 以维持阴影、圆角、缩放与全屏，只隐藏三个标准窗口按钮；`WKWebView` 子类在顶部拖拽区内把拖动转成 `performDrag`，点击先调 `super.mouseDown` 再决定，页面按钮照常响应。
- **拖拽区跟高**：注入脚本查找视口顶部、宽 ≥ 400、高 24–160 的 `<header>`，把实测高度上报给原生侧；找不到时用 40px 兜底。
- **透明 WebView**：`WKWebView.drawsBackground = false` + `underPageBackgroundColor = .clear`，页面按自己的浅/深色绘制。
- **主题**：页面把主题写在 `html[data-ds-theme-source]`，应用同步 `NSApp.appearance`，标题栏、菜单、原生对话框跟随页面明暗。
- **启动页底色**：页面通过 `window.__ORCA_PALETTE__.set('#rrggbb')` 把当前配色层的 base 交过来（`dsh-theme-rose-pine` 已接），应用存进 `splashBaseColor`，下次启动在磨砂玻璃**上面**铺这层颜色，并按亮度自动换深/浅文字。颜色必须由这层填充负责，不能让材质 tint 去混——`withinWindow` 的材质会盖自己的色罩，把 `#232136` 洗成 `#25272F`；填充无页面时完全不透明（像素即 base），有页面时留 14% 透光给磨砂（实测 `#232136` → `#232234`）。
- **文件选择**：注入 `__DSH_DIRECTORY_PICKER__`，用 `NSOpenPanel` 选择工作区目录。
- **下载与外链**：`WKDownload` + `NSSavePanel` 保存文件；`target=_blank` 与站外链接交给默认浏览器。
- **隐私授权**：`dsh` 子进程以 Orca 的身份访问文件，首次打开工作区时 macOS 会询问「文稿」文件夹权限，需要允许。重建后 ad-hoc 签名变化，系统可能再次询问；可在「系统设置 → 隐私与安全性 → 文件与文件夹」中调整。

## 已知限制

- Orca 自带一个 `dsh web` 实例。如果同时开着终端里的 `dsh web`（3080），两个实例共享 `~/.dsh` 存储，会话引用与工作区状态可能互相干扰；日常使用建议只保留 Orca。
- ad-hoc 签名，未公证；从源码重建即可，不需要绕过 Gatekeeper（本机构建不带隔离属性）。
- 与 `~/Documents/dsh/Orca-app`（8 月的 Electron/WebKit + launchd 版本）互不影响，旧工程原样保留。
