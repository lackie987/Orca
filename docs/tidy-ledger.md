# 整理台账（tidy ledger）

这份文件只有一个用途：**让下一次「整理」从上次的结论继续，不再重复发现同一批问题。**
动手前先读 §3——写在那张表里的项已经查过、已有结论，没有新证据就别再提。

## 维护规则

- **一条一行，合并优于追加**：结论被推翻时改写原行并更新日期，不新增一条平行记录。
- **每条必须带**：编号、范围、检查时间、结论、依据（文件:行）。没有依据的条目一律不写。
- **状态只有四种**：`不改`（查过，有意保持）／`已改`／`待办`（该改，未动）／`待定`（要人定口径）。
- **相对时间不写**（「最近」「上次」一律落到日期）。
- 结论全绿的条目满 30 天可整行删除；本轮全留，方便核对口径。

范围口径：`Orca` = `~/Documents/dsh/Orca`（Swift + docs）；`插件` = `~/.dotfiles/.dsh/plugins` 下 9 个自养插件，
`dsh-superagent`（`~/Documents/dsh/superagent-plugin`）未查，见 §6。npm 装的第三方插件不在范围。

---

## 1. 本轮批次

| 批次 | 时间 | 范围 | 覆盖程度 |
| --- | --- | --- | --- |
| B1 | 2026-11-04 | Orca 全部 Swift 源（8.5k 行，逐文件扫过 + 定点精读 6 个）＋ docs；9 个自养插件的 package.json / locale / 目录结构 / 关键 client 文件精读 3 个 | 结构层全覆盖；文案层抽样（壳的设置面板、菜单、警告全文；标题栏、首页图标、应用图标三处字典全文） |
| B2 | 2026-11-04 | 同上 + 落地：壳本地化（新 `ShellCopy.swift`，壳的文案全部收口）、设置面板重写、插件文案与 README 的 markdown 治理 | 壳的全部用户可见文案（菜单 44 条、设置面板 14 条、启动页 7 条、服务状态 11 条、弹窗 4 组）逐一走查并双语化；9 个插件 README + Orca README + 本台账做了 markdown 语法核对 |
| B3 | 2026-11-04 | 待办清零：两仓提交、9 个插件 `package.json` 审计、jscpd / swiftlint / knip 三个分析器各跑一次并记录结论 | 提交按主题拆开（dotfiles 4 个、Orca 2 个）；分析器结论见 §3.3 |

---

## 2. 已改（本轮真正动过的）

| 编号 | 范围 | 改了什么 | 检查时间 | 结果 | 依据 |
| --- | --- | --- | --- | --- | --- |
| M1 | dsh-orca-titlebar | 设置行说明与插件卡片描述：「控制Orca的红绿灯显示情况」→「控制 Orca 红绿灯何时显示」（补中英间距、把「显示情况」换成控件实际控制的「何时显示」）；英文同步为 `Controls when Orca's traffic lights show.` | 2026-11-04 | 已改，`node --check` ＋ JSON 解析通过；需重开 Orca 才生效 | `client.js:59,67`、`locale/zh.json:4`、`locale/en.json:4` |
| M2 | Orca 壳（本地化） | 新增 `Sources/Orca/ShellCopy.swift`：`ShellLanguage`（zh 默认 / en）+ 按面分组的双份文案表，插值句子以模板 + 函数形式暴露。菜单、设置面板、启动页、服务状态与失败原因、退出确认/检查器/下载失败三类弹窗全部改走该表；`Preferences.language` 持久化（键 `shellLanguage`，默认 `zh`）。对应关闭 T3、T4 | 2026-11-04 | 已改，`swift build` 通过；语言切换在设置面板保存时生效，菜单与启动页立即重建 | 新增 `ShellCopy.swift`；`Preferences.swift`（language / copy）；`MainMenu.swift`、`SettingsWindowController.swift`、`SplashView.swift`、`ServiceController.swift`、`MainWindowController.swift`、`InspectorController.swift`、`WebPageDialogs.swift`、`JavaScriptPanels.swift`、`AppDelegate.swift` |
| M3 | Orca 设置面板（结构） | 拆开 114 行的 `build()`：`verticalStack` / `makeHeader` / `makeServiceRows` / `makeSwitches` / `makeLanguageRow` / `makeButtons` / `makeDivider` / `makeHint` / `fieldLabel` / `fieldRow`，最长不过 30 行；标签列宽 90 提为 `labelColumnWidth`（顺手放宽到 96，容纳「dsh 命令」与英文标签）。对应关闭 T5、T6 | 2026-11-04 | 已改，编译通过；面板高度 440 → 500 以容纳语言行 | `SettingsWindowController.swift` 全文 |
| M4 | Orca（重复代码） | `ColorHex` 两处按 0–255 通道构造 `NSColor` 的代码收成私有 `srgb(red:green:blue:)`，`color()` 与 `fromCSS()` 共用。对应关闭 T7 | 2026-11-04 | 已改，编译通过 | `ColorHex.swift:6-50` |
| M5 | dsh-orca-hero-mark | 中文命名从「初始页图标」改为「首页图标」，并统一该插件里对那张页面的称呼（README、package.json、locale、`client.js`、`cordis.patch.yml` 共 10 处）；「初始页前的鲸鱼图标」一并改为「首页的鲸鱼图标」。英文保持 `Hero Mark`（DSH 槽位原名）。对应关闭 Q3 | 2026-11-04 | 已改，`node --check` ＋ JSON 通过；需重开 Orca 才生效 | `client.js:39`、`locale/zh.json:3-4`、`package.json:5`、`README.md`、`cordis.patch.yml:1` |
| M6 | 文档（markdown 滥用） | 定规则：加粗只留在列表项标签或句首；句中强调、表格单元格里的加粗、UI 路径上的加粗一律拆掉。顺带修掉去粗体后残留的「在 设置 → 通用 里」空格，以及本台账里把 `dawn` / `main` / `moon` 用竖线连写、撑破表格单元格的写法。9 个插件 README + Orca README + 本台账的表格列数与标题层级全部校验一致 | 2026-11-04 | 已改，加粗 span 数：dsh-app-icon 29 → 13、dsh-theme-rose-pine 33 → 10、dsh-balance-pill 19 → 15、dsh-orca-titlebar 2 → 0、dsh-orca-hero-mark 保持 1（唯一的列表标签）；脚本只碰正文，代码块与行内代码原样 | 8 个 README + 本台账 |
| M7 | 两仓提交 | dotfiles 四个 commit：`cd326e2` 五插件并入 dsh-patch + 图标引擎拆到 dsh-icons（260 文件，+28.6k / −25.3k）、`79a8a67` dsh-skill-manager 入库（5 文件）、`a992d5f` 插件软引用官方 UI 包 + 自绘兜底（app-icon 到 1.0.1、hero-mark 卸载时移走自己的样式表）、`bfce87b` 文案与 README。Orca 两个 commit：`56f6081` 代码（语言切换 + 此前未提交的启动/图标链路收尾，32 文件）、`3b9a734` 文档（台账 + README + 截图）。dotfiles 里的 `dsh-commandcode-provider` 是独立仓库（自带 origin 与 tag），没有并入 | 2026-11-04 | 已改，两仓 `git status` 干净（只剩那个独立仓库自己的改动未动） | `git log` 两仓 |
| M8 | Orca 红绿灯旧代码 | 删掉 `WindowChrome` 里整块注释的首版 `fade`（0.18s，`/* … */` 12 行）。它被 `setLightsHidden` + `dissolve`（进场）与 `fadeOutLights`（退场逐帧步进）取代，注释里留下的只有一个时长数字；「为什么退场不能用 `animator().alphaValue`」已写在 `fadeOutLights` 的注释里，代码本体可从 `56f6081^` 取回。同时把退场时长与 `dissolve` 默认值两处 0.35 合成 `lightsFadeDuration`，`dissolve` / `showLights` 的注释按现状改写（退场早已不共用 dissolve），`TitleBarMode` 去掉没人消费的 `CaseIterable` | 2026-11-04 | 已改，`swift build` 通过；`rg "0\.18\|lightsFadeOutDuration\|static func fade"` 只剩注释里那句历史说明 | `WindowChrome.swift`（`lightsFadeDuration`、`dissolve`、`fadeOutLights`）、`TitleBarMode.swift:9` |
| M9 | Orca 红绿灯（`shown` 档） | 曾按「三档已覆盖所有布局」删掉第四档，随后按需求恢复为**占位**：`case shown` 回来了，但它不再绘制标准标题栏，`WindowChrome.apply` 里与 `lightsOnly` 共用分支；只服务旧实现的 `usesWebTitleStrip`、`restoreLightsBaseline()`、`setChrome` 的 `transparent` 参数**没有**跟着回来。README 与插件注释按「占位」口径重写 | 2026-11-04 | 已改（最终态：三档可用 + 一个占位档），`swift build` 通过 | `TitleBarMode.swift:13-21`、`WindowChrome.swift:40-45`、`README.md:109-114`、`dsh-orca-titlebar/client.js:46-53` |

| M10 | Orca 版本 | `CFBundleShortVersionString` 1.1.0 → 1.2.0、`CFBundleVersion` 2 → 3：自 `2b0ac5b`（1.1.0）以来 22 个提交、50 个文件，且含新增能力（壳的界面语言可切换、orca-icon-sync 与图标成品交接），按「有新增能力走次版本号」定 1.2.0 | 2026-11-06 | 已改，`plutil -lint` 通过；装进 `/Applications` 后需重开 Orca 才看得到新版本号 | `Resources/Info.plist:19-22`、`git rev-list --count 2b0ac5b..HEAD` |

---

## 3. 已检查 · 不改（别再重复整理）

### 3.1 Orca 代码

| 编号 | 项 | 检查时间 | 结论 | 依据 |
| --- | --- | --- | --- | --- |
| C1 | 全仓 `TODO` / `FIXME` / `HACK` / `XXX` | 2026-11-04 | 零命中，不需要清理 | `Sources/**/*.swift` 全量检索 |
| C2 | 整行注释掉的死代码（`// let/var/func/if…`） | 2026-11-04 | 零命中；本仓因此不必留「注释保留」的存量 | 同上，正则检索 |
| C3 | `dist/`（21 MB）、`build/`、`.build/`、`storage-backup/` 出现在磁盘上 | 2026-11-04 | 构建/备份产物，四条都已被 `.gitignore` 覆盖，不要当死文件删 | `.gitignore:1-5` |
| C4 | `Resources/Icons/png_*.png`、`svg_*.png` | 2026-11-04 | 图标处理中间产物，已忽略；保留可复现合成结果 | `.gitignore:7-9` |
| C5 | `LaunchTrace.swift`、`SuperagentWindowController.swift` 未纳入 git | 2026-11-04 | 不是死文件：分别被启动阶段打点与 Service 菜单引用 | `MainWindowController.swift:80,453,456,505`、`WebPageNavigation.swift:82,86`、`AppDelegate.swift:12,161` |
| C6 | `ThemeColor.swift` 与 `ColorHex.swift` 是否重复 | 2026-11-04 | 不重复也不该合并：前者推导启动底色，后者只做 hex ↔ NSColor 互转 | 两个文件全文 |
| C7 | 标题栏档位与默认值 | 2026-11-04 | 三档可用（`hidden` / `hover` / `lightsOnly`），默认 `lightsOnly`，与 README 一致；`shown` 是占位档，渲染同 `lightsOnly`（见 P12） | `TitleBarMode.swift:13-21` |
| C8 | 图标预设数量 | 2026-11-04 | 6 个 id（`orca`、`dawn`、`main`、`moon`、`template`、`custom`），其中 dawn / main / moon 才算「随外观」的成品，`template`、`custom` 是动态来源；README「六个预设加自选图片」表述含糊但不算错 | `AppIcon.swift:24-27` |
| C9 | `__ORCA_APP_VERSION__` 与「Orca 版本：v{version}」是否会出现双 `v` | 2026-11-06 | 不会：注入值取自 `CFBundleShortVersionString`（当前 `1.2.0`，不带 `v`） | `WebPageScripts.swift:70,78`、`Resources/Info.plist:19-22` |
| C10 | README 的构建/打包参数与脚本是否一致 | 2026-11-04 | 一致：`--no-install`、`--no-pkg`、`--no-dmg`、`ORCA_INSTALL_DIR`、`ORCA_SIGN_IDENTITY` 都在脚本里 | `build.sh:1-20`、`package.sh:5-12` |
| C11 | README「当前只构建 arm64」 | 2026-11-04 | 属实：`swift build` 未传 `--arch`/`--triple`，只出宿主架构 | `build.sh:20-22` |

### 3.2 插件

| 编号 | 项 | 检查时间 | 结论 | 依据 |
| --- | --- | --- | --- | --- |
| P1 | 9 个插件的调试插桩（`console.log` / `debugger`） | 2026-11-04 | 零命中，无需清理 | 全插件 `src/` + 根 `client.js` 检索 |
| P2 | 面板文案为什么不在 `locale/*.json` | 2026-11-04 | 既定约定：宿主 `ctx.locale.register` 收的是字典对象，所以文案写在 `client.js` 的 `DICT` 里（zh/en 双份）；`locale/*.json` 只承担插件卡片的 title/description。不要把这些字典迁去 locale 文件，那样反而要改注册方式 | `dsh-orca-titlebar/client.js:56-73,265-269` |
| P3 | `require("@deepseek-ai/dsh-client-ui-primitives")` 出现在客户端 | 2026-11-04 | 三处都包在 `try/catch` 里并有自绘兜底（`LocalSegmented` / `dsh-ohm-fallback`），不违反「第三方插件不能 require 官方 UI 包」的硬约束，别再报成违规 | `dsh-orca-titlebar/client.js:25-33`、`dsh-orca-hero-mark/client.js:22-28` |
| P4 | `dsh-app-icon` 的 `.system` 跟随档在 UI 里折叠成「随主题」 | 2026-11-04 | 有意收敛：UI 不暴露那一档，注释已写明理由。报告「UI 够不到 system」属于已知设计，不重复提（红绿灯侧对应的是 `shown` 占位档，见 P12） | `dsh-app-icon/client.js:9-12,237-238` |
| P5 | `dsh-patch/docs/official-ui/*` 像生成物 | 2026-11-04 | 是官方真值缓存，`npm run ui:extract` 重建，保留在库 | `docs/official-ui/README.md` |
| P6 | `dsh-patch/legacy/*.json`（4 个） | 2026-11-04 | 5 个已合并插件的历史状态快照，留档供迁移比对，不删 | `dsh-patch/legacy/` |
| P7 | `src/` 与 `lib/`、根 `client.js` 并存 | 2026-11-04 | 源码 + 发布产物，属正常形态（`dsh-icons`、`dsh-theme-rose-pine`、`dsh-patch` 各有自研构建），不算重复文件 | 各插件 `package.json` `exports` |
| P8 | `.DS_Store` 是否混进版本库 | 2026-11-04 | 没有：dotfiles 已忽略且 0 个被跟踪（`dsh-patch/snippets/.DS_Store` 也是未跟踪状态） | `~/.dotfiles/.gitignore:9,95`、`git ls-files` |
| P9 | 9 个插件 `package.json` 三种形态（`main` 有 `index.js` / `lib/index.js` / `src/index.js`，`exports` 有对象与裸字符串两种写法，`dsh.client` 有的缺 `platform` / `immediately`） | 2026-11-04 | 逐一核过：**所有 `main` / `exports` 指向的文件都存在**（唯一的「缺失」是 `./locale/*.json` 这条 glob 通配，不是文件）；三种 `main` 分别对应「无构建 / 自研构建 / src 即产物」三种合法形态；`platform` 与 `immediately` 缺省时宿主按默认走，`dsh-patch` 与 `dsh-skill-manager` 今天在跑的 profile 里就是这两项都缺的状态，改动只会换来一次 `pnpm install` + 重启和加载时机的风险。**统一纯属装饰，不做** | 逐插件审计脚本输出；`~/.dotfiles/.dsh/profiles/web/package.json` |
| P10 | `dsh-patch` 的 open-in-app 主按钮同时带 `title` 与 `aria-label`（值相同） | 2026-11-04 | 有意：主按钮是纯图标，`title` 是 rose-pine 自绘气泡提示的**输入源**（无主题时才回落系统 tooltip），`aria-label` 负责无障碍。删 `title` 会把气泡一起删掉，不是「又一处原生 title 滥用」 | `src/client/dropdown.ts:513-516`、`README.md`（菜单小节） |
| P11 | `ElectronShortcuts.swift` 整文件都是注释（81 行，零可执行代码） | 2026-11-04 | 有意留档，不是忘删：README 第 148 行写明「Electron 默认菜单的对照表保留在 `ElectronShortcuts.swift`，当前仅作决策记录，没有消费者」。它记的是「Electron 默认组合 ↔ Orca 动作 ↔ 哪两处故意不一致（`forceReload` 归服务重启、开发者工具走 F12）」。别再当死文件清掉；真要清，先把这张表挪进 docs 再删文件 | `Sources/Orca/ElectronShortcuts.swift:1-11,12-81`、`README.md:148` |
| P12 | `TitleBarMode.shown`（第四档） | 2026-11-04 | 保留为占位档，壳与插件都不要再给它加 UI 或布局：语义上它是「标准标题栏」，而壳不画系统标题栏（页面标题条就是标题行）。`WindowChrome.apply` 里它与 `lightsOnly` 共用分支，只是为了让旧偏好里的 `"shown"` 不跳变。删掉它没有收益（要改持久化值解析），实现它则违背窗口设计 | `TitleBarMode.swift:13-21`、`WindowChrome.swift:40-45`、`README.md:109-114`、`dsh-orca-titlebar/client.js:46-53` |
| P13 | 红绿灯那一行的标题：插件卡片叫「Orca 红绿灯」，设置行里只有「红绿灯」 | 2026-11-04 | 不改，有意：设置行本身就在「Orca 设置」里，行内再带产品名是重复；卡片是插件列表，才需要说明归属。两个名字分别在各自上下文里最短且无歧义 | `locale/zh.json:3`（卡片）vs `client.js:58`（行） |
| P14 | `dsh-app-icon` 的 hint「选择要使用的图标」只说图标这一维，同行的第二个下拉（跟随）没被提及 | 2026-11-04 | 不改，没必要：hint 只负责「这一行在选什么」，跟随由第二个下拉自己的标签承担；把一种情况写进总述反而让 hint 变成没说完的清单。四个候选方案（说结果 / 说来源 / 合并成一项 / 删掉 hint）一并作废，不再提 | `dsh-app-icon/client.js:79` |
| P15 | Dock 磁贴换图标后「落后一拍」（尤其退出 Orca 后翻系统浅色/深色） | 2026-11-04 | 不是 bug，是 macOS 的图标缓存：Dock 画的是 LaunchServices 按 bundle id 缓存的位图，运行中改 `applicationIconImage` 实时生效，进程退出后没人再推快照，只能等下次启动或重启 Dock。不要再为它加刷新手段（重设图标、抖 bundle 时间戳、kill Dock），那只是追缓存时机；一致的路径是写 bundle 的 `AppIcon.icns` + 下次启动读它，已在。这条已写进插件的 README 开头 | `dsh-app-icon/README.md:5-12`、`AppIconInstaller.swift:54-58` |

### 3.3 分析器（跑过，结论明确）

| 编号 | 项 | 检查时间 | 结论 | 依据 |
| --- | --- | --- | --- | --- |
| A1 | 插件重复度（jscpd） | 2026-11-04 | `dsh-patch/src` 128 个文件 / 23497 行，重复率 **0.09%**（唯一一处：`client/host-open.ts` 与 `client/custom-code/host-open.ts` 共 22 行，189 token）。两份语义不同——共享版还管「复制到剪贴板」，custom-code 版只「真打开」——**不合并**，合并等于给两条路径做行为求交 | `npx jscpd@3 --min-tokens 120 --format typescript src`（v4 会扫到 0 个文件，用 v3） |
| A2 | Orca 的 swiftlint | 2026-11-04 | **跑不起来**：swiftlint 0.65.1 加载 `sourcekitdInProc.framework` 失败（Homebrew 装的二进制与本机 CommandLineTools / Xcode 26 工具链不匹配），与代码无关。要用得先修工具链，或在 Xcode 里跑 | `swiftlint lint` 报 `Loading sourcekitdInProc.framework ... failed` |
| A3 | knip / 未用导出 | 2026-11-04 | 未跑：本机没有，`npx` 装一份对这个仓库意义有限——插件是自研单 bundle，导出名被宿主的字符串消费，误报密度高。真要做得先写一份 `knip.json` 白名单，投入产出比不高 | `which knip` 为空 |

---

## 4. 待办（该改，尚未动）

按「先低风险后重构」排序；每项都带依据，动手时不必重新定位。已关闭的项与去向：

- T3 / T4 / T5 / T6 / T7 / T10 → §2 的 M2 / M3 / M4，以及 dsh-tidy 文件地图重写；
- T1 / T2 → §2 的 M7（两仓已提交，dotfiles 四个 commit、Orca 两个）；
- T8 / T9 → §3 的 P9 / P10（核完是「有意，不做」）；
- T11 → §3.3（jscpd 0.09%，swiftlint 工具链坏了，knip 未装）。

| 编号 | 范围 | 事项 | 检查时间 | 状态 | 依据 |
| --- | --- | --- | --- | --- | --- |
| T12 | Orca 设置面板 | 英文界面只过了编译，没在真机上量过：`labelColumnWidth` 96 是照中文标签调的，英文最长的几个标签是 checkbox 的整句（不受列宽影响），风险在语言行 hint 的换行与面板高度 500 是否够。**Orca 正开着（pid 77901 + dsh 子进程），装新构建要重开，这步留给你** | 2026-11-04 | 待办（需你重开 Orca 后看） | `SettingsWindowController.swift`（`Self.labelColumnWidth`、`contentRect`） |

---

## 5. 待定（要你定口径，定了就迁去 §3 或 §4）

暂无。上一轮的两条都已经判完并归档：Q2（红绿灯那行的标题）与 Q4（应用图标的 hint）都是
「不需要改」，理由见 §3 的 P13 / P14——它们不是被搁置，是已有结论。以后真有分歧再在这里重开一行。

已关闭：Q1（壳的界面语言）→ 见 §2 M2，默认中文 + 设置面板可切 English，README 已写明；
Q3（「初始页图标」名大于实）→ 见 §2 M5，改名「首页图标」。

---

## 6. 未覆盖（下一轮从这里开工，别假装查过）

- Orca：`WebPageScripts*.swift` 注入脚本里的开关名与提示（`WebPageScriptsDesktop` 的 `status: 'ready'` 一类是宿主契约，不是文案）、`GlobalHotkeys` / `ElectronShortcuts` 的键位表、`Preferences` 键名与 README 用词的一致性。
- 插件：`dsh-balance-pill`、`dsh-icons`、`dsh-skill-manager`、`dsh-theme-rose-pine`、`dsh-commandcode-provider` 的 `DICT` 全文与各自 README 的贴合度（本轮只处理了 README 的 markdown 语法）；`dsh-patch/src/client/tweaks*.ts`（3.7k 行）只看了目录与 README。
- `dsh-superagent`（`~/Documents/dsh/superagent-plugin`）整包未看。
- 运行态验证：本轮只做静态检查与 `swift build`，没有起 Orca 看真实界面（中英文两种语言下的截断、换行、面板高度都未实测）。
