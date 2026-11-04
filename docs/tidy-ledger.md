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
| C7 | 窗口四档标题栏的实现与默认值 | 2026-11-04 | 4 个 case 齐全，默认 `lightsOnly`，与 README「四档」一致 | `TitleBarMode.swift:9-19` |
| C8 | 图标预设数量 | 2026-11-04 | 6 个 id（`orca`、`dawn`、`main`、`moon`、`template`、`custom`），其中 dawn / main / moon 才算「随外观」的成品，`template`、`custom` 是动态来源；README「六个预设加自选图片」表述含糊但不算错 | `AppIcon.swift:24-27` |
| C9 | `__ORCA_APP_VERSION__` 与「Orca 版本：v{version}」是否会出现双 `v` | 2026-11-04 | 不会：注入值取自 `CFBundleShortVersionString`（当前 `1.1.0`，不带 `v`） | `WebPageScripts.swift:70,78`、`Resources/Info.plist:19-20` |
| C10 | README 的构建/打包参数与脚本是否一致 | 2026-11-04 | 一致：`--no-install`、`--no-pkg`、`--no-dmg`、`ORCA_INSTALL_DIR`、`ORCA_SIGN_IDENTITY` 都在脚本里 | `build.sh:1-20`、`package.sh:5-12` |
| C11 | README「当前只构建 arm64」 | 2026-11-04 | 属实：`swift build` 未传 `--arch`/`--triple`，只出宿主架构 | `build.sh:20-22` |

### 3.2 插件

| 编号 | 项 | 检查时间 | 结论 | 依据 |
| --- | --- | --- | --- | --- |
| P1 | 9 个插件的调试插桩（`console.log` / `debugger`） | 2026-11-04 | 零命中，无需清理 | 全插件 `src/` + 根 `client.js` 检索 |
| P2 | 面板文案为什么不在 `locale/*.json` | 2026-11-04 | 既定约定：宿主 `ctx.locale.register` 收的是字典对象，所以文案写在 `client.js` 的 `DICT` 里（zh/en 双份）；`locale/*.json` 只承担插件卡片的 title/description。不要把这些字典迁去 locale 文件，那样反而要改注册方式 | `dsh-orca-titlebar/client.js:56-73,265-269` |
| P3 | `require("@deepseek-ai/dsh-client-ui-primitives")` 出现在客户端 | 2026-11-04 | 三处都包在 `try/catch` 里并有自绘兜底（`LocalSegmented` / `dsh-ohm-fallback`），不违反「第三方插件不能 require 官方 UI 包」的硬约束，别再报成违规 | `dsh-orca-titlebar/client.js:25-33`、`dsh-orca-hero-mark/client.js:22-28` |
| P4 | 原生 `shown`（标准标题栏）在红绿灯控件里折叠成「常显」；`dsh-app-icon` 的 `.system` 折叠成「随主题」 | 2026-11-04 | 两处都是有意收敛，UI 不暴露那一档，注释已写明理由。报告「UI 够不到 shown / system」属于已知设计，不重复提 | `dsh-orca-titlebar/client.js:46-52`、`dsh-app-icon/client.js:9-12,237-238` |
| P5 | `dsh-patch/docs/official-ui/*` 像生成物 | 2026-11-04 | 是官方真值缓存，`npm run ui:extract` 重建，保留在库 | `docs/official-ui/README.md` |
| P6 | `dsh-patch/legacy/*.json`（4 个） | 2026-11-04 | 5 个已合并插件的历史状态快照，留档供迁移比对，不删 | `dsh-patch/legacy/` |
| P7 | `src/` 与 `lib/`、根 `client.js` 并存 | 2026-11-04 | 源码 + 发布产物，属正常形态（`dsh-icons`、`dsh-theme-rose-pine`、`dsh-patch` 各有自研构建），不算重复文件 | 各插件 `package.json` `exports` |
| P8 | `.DS_Store` 是否混进版本库 | 2026-11-04 | 没有：dotfiles 已忽略且 0 个被跟踪（`dsh-patch/snippets/.DS_Store` 也是未跟踪状态） | `~/.dotfiles/.gitignore:9,95`、`git ls-files` |

---

## 4. 待办（该改，尚未动）

按「先低风险后重构」排序；每项都带依据，动手时不必重新定位。已关闭的 T3、T4、T5、T6、T7、T10 见 §2
（M2 / M3 / M4 与 dsh-tidy 文件地图重写），这里不再保留。

| 编号 | 范围 | 事项 | 检查时间 | 状态 | 依据 |
| --- | --- | --- | --- | --- | --- |
| T1 | Orca + dotfiles | 两仓都停在半提交状态：Orca 28 个改动 + 2 个新文件未提交；dotfiles 里 `dsh-bridge`/`dsh-copycode`/`dsh-custom-code` 的删除未提交，`dsh-orca-titlebar`（自绘分段控件兜底）、`dsh-app-icon`、`dsh-balance-pill` 也各带未提交改动，而 `dsh-patch` README 已写「五个原插件已删除」——文档超前于仓库。建议按主题分批提交（本轮 M1–M6 都叠在这些未提交改动上） | 2026-11-04 | 待办 | `git status` 两仓 |
| T2 | 插件 | `dsh-icons`、`dsh-skill-manager`、`dsh-commandcode-provider` 三个目录 0 个被跟踪文件，`dsh-patch` 另有 40 条未跟踪 —— 等于这三个插件没有版本备份 | 2026-11-04 | 待办 | `git ls-files` 逐目录统计 |
| T8 | 插件 | `package.json` 形态三种：`main` 有 `index.js` / `./lib/index.js` / `src/index.js`；`exports` 有 `{".":{"default":…}}` 与裸字符串（`dsh-skill-manager`）；`dsh.client` 有的缺 `platform`/`immediately`（`dsh-patch`、`dsh-skill-manager`）。改这个要 `pnpm install` + 重启，先定一套标准再统一 | 2026-11-04 | 待办 | 9 个 `package.json` |
| T9 | dsh-patch | README 明确写「主按钮带 `title`，rose-pine 渲染成 title-tip、换主题回落系统 tooltip」——与「按钮不要原生 title 悬停提示」的既有偏好存在张力。若主按钮是纯图标则 `title` 可接受（但更好是 `aria-label` + 自绘提示），需确认口径 | 2026-11-04 | 待办 | `dsh-patch/README.md`（菜单小节） |
| T11 | 全范围 | 未跑重型分析器（jscpd / knip / madge）。插件是自研单 bundle 构建、导出名被宿主字符串消费，误报密度高；Orca 是 Swift，更适合 swiftlint。要做就分开做：插件先 knip 只看 `src/`，Orca 先 swiftlint | 2026-11-04 | 待办（未执行） | — |
| T12 | Orca 设置面板 | 英文界面只过了编译，没在真机上量过：`labelColumnWidth` 96 是照中文标签调的，英文最长标签是 `Keep the local service running after Orca quits`（这行是 checkbox，不受列宽影响）与 `dsh command`（短），风险在语言行 hint 的换行与面板高度 500 是否够 | 2026-11-04 | 待办（需起 Orca 实测） | `SettingsWindowController.swift`（`Self.labelColumnWidth`、`contentRect`） |

---

## 5. 待定（要你定口径，定了就迁去 §3 或 §4）

| 编号 | 问题 | 检查时间 | 现状 | 依据 |
| --- | --- | --- | --- | --- |
| Q2 | 红绿灯那一行的标题：插件卡片叫「Orca 红绿灯」，设置行里只有「红绿灯」。同一功能两个名，页面内看不出「红绿灯」属于谁 | 2026-11-04 | 两处不同名 | `locale/zh.json:3` vs `client.js:58` |
| Q4 | `dsh-app-icon` 的 hint「选择要使用的图标」：同一行还有第二个下拉（跟随），hint 只说了图标这一维。但「跟随」只是这一行的一种情况，硬塞进 hint 也怪。候选（未落地）：① hint 说结果——「换好后 Dock、访达和启动页一起更新」；② hint 说来源——「内置图标或自己的图片」；③ 两个下拉合成一个设置项，标题改「图标与跟随」，各自的下拉标签自己说明；④ 直接删掉 hint，让两个下拉的标签承担说明（官方设置页多数行没有第二行） | 2026-11-04 | 未定，代码里仍是原文案 | `dsh-app-icon/client.js:79` |

已关闭：Q1（壳的界面语言）→ 见 §2 M2，默认中文 + 设置面板可切 English，README 已写明；
Q3（「初始页图标」名大于实）→ 见 §2 M5，改名「首页图标」。

---

## 6. 未覆盖（下一轮从这里开工，别假装查过）

- Orca：`WebPageScripts*.swift` 注入脚本里的开关名与提示（`WebPageScriptsDesktop` 的 `status: 'ready'` 一类是宿主契约，不是文案）、`GlobalHotkeys` / `ElectronShortcuts` 的键位表、`Preferences` 键名与 README 用词的一致性。
- 插件：`dsh-balance-pill`、`dsh-icons`、`dsh-skill-manager`、`dsh-theme-rose-pine`、`dsh-commandcode-provider` 的 `DICT` 全文与各自 README 的贴合度（本轮只处理了 README 的 markdown 语法）；`dsh-patch/src/client/tweaks*.ts`（3.7k 行）只看了目录与 README。
- `dsh-superagent`（`~/Documents/dsh/superagent-plugin`）整包未看。
- 运行态验证：本轮只做静态检查与 `swift build`，没有起 Orca 看真实界面（中英文两种语言下的截断、换行、面板高度都未实测）。
