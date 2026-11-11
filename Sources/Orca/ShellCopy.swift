import Foundation

/// The two languages the shell itself can speak.
///
/// The page has its own locale and this enum deliberately does not touch it: it only governs the
/// strings Orca draws — menu bar, settings panel, startup surface, and the alerts the shell raises.
/// `zh` is the default, matching the product's primary audience; `en` is opt-in from the settings
/// panel.
enum ShellLanguage: String, CaseIterable {
    case zh
    case en

    /// Each language names itself in the settings panel's selector.
    var displayName: String {
        switch self {
        case .zh: "中文"
        case .en: "English"
        }
    }

    /// Parses the persisted value, falling back to the default for anything unknown.
    static func parse(_ value: String?) -> ShellLanguage {
        guard let value, let language = ShellLanguage(rawValue: value) else { return .zh }
        return language
    }
}

/// Every string the shell draws, grouped by surface.
///
/// Two whole tables instead of a keyed lookup: a missing translation then fails to compile rather
/// than silently falling back to the other language. Sentences that carry a value keep their
/// template private and expose a small function, so no caller ever assembles copy from fragments.
///
/// NOTE: the tables are kept as a single embedded JSON blob per language and parsed at runtime
/// instead of as `static let` string fields. Under `-O`, Swift/LLVM's constant folding silently
/// drops a non-deterministic subset of the string literals in a large constant struct (a known
/// optimizer bug); routing every string through one blob that is handed to `JSONSerialization`
/// (a Foundation call the compiler cannot look into) keeps them all present in the release binary.
struct ShellCopy {
    let menu: MenuCopy
    let settings: SettingsCopy
    let splash: SplashCopy
    let service: ServiceCopy
    let alert: AlertCopy
    let common: CommonCopy

    static func of(_ language: ShellLanguage) -> ShellCopy {
        switch language {
        case .zh: parse(zhBlob)
        case .en: parse(enBlob)
        }
    }

    // MARK: - Menu bar

    struct MenuCopy {
        let about: String
        let settings: String
        let services: String
        let hide: String
        let hideOthers: String
        let showAll: String
        let quit: String

        let file: String
        let closeWindow: String
        let openInBrowser: String
        let copyAccessLink: String

        let edit: String
        let undo: String
        let redo: String
        let cut: String
        let copy: String
        let paste: String
        let selectAll: String

        let view: String
        let reload: String
        let reloadFromServer: String
        let actualSize: String
        let zoomIn: String
        let zoomOut: String
        let enterFullScreen: String
        let developerTools: String
        let selectElement: String
        let showConsole: String

        let service: String
        let restartService: String
        let stopService: String
        let showServiceLog: String
        let superagent: String

        let window: String
        let minimize: String
        let zoom: String
        let bringAllToFront: String

        let help: String
        let projectPage: String
    }

    // MARK: - Settings panel

    struct SettingsCopy {
        let title: String
        let port: String
        let portHint: String
        let profile: String
        let profileHint: String
        let command: String
        let commandHint: String
        let keepAlive: String
        let inputAssistance: String
        let inputAssistanceHint: String
        let language: String
        let languageHint: String
        let restartHint: String
        let invalidTitle: String
        let portError: String
        let emptyError: String
        let save: String
    }

    // MARK: - Startup surface

    struct SplashCopy {
        let preparing: String
        let tryAgain: String
        let serviceLog: String
        let unavailable: String
        let pageFailed: String
        let stopped: String
        let stoppedDetail: String
        let pageFailedDetailFormat: String
        let webProcessLostDetail: String

        /// "…🡒 reason. Retry, or open the service log for the full report."
        func pageFailedDetail(_ reason: String) -> String {
            String(format: pageFailedDetailFormat, reason)
        }
    }

    // MARK: - Service progress and failures

    struct ServiceCopy {
        let restarting: String
        let reconnecting: String
        let loadingWorkspace: String
        let starting: String
        let freeingPortFormat: String
        let startingOnPortFormat: String
        let commandMissingFormat: String
        let launchFailedFormat: String
        let exitedFormat: String
        let didNotStartFormat: String
        let portHeldFormat: String
        let previousStopped: String

        func freeingPort(_ port: Int) -> String {
            String(format: freeingPortFormat, port)
        }

        func starting(port: Int) -> String {
            String(format: startingOnPortFormat, port)
        }

        func commandMissing(_ command: String) -> String {
            String(format: commandMissingFormat, command)
        }

        func launchFailed(_ command: String) -> String {
            String(format: launchFailedFormat, command)
        }

        func exited(status: Int32) -> String {
            String(format: exitedFormat, Int(status))
        }

        func didNotStart(seconds: Int) -> String {
            String(format: didNotStartFormat, seconds)
        }

        func portHeld(by owner: String, port: Int) -> String {
            String(format: portHeldFormat, owner, port)
        }
    }

    // MARK: - Alerts

    struct AlertCopy {
        let sessionsTitleSingle: String
        let sessionsTitleManyFormat: String
        let sessionsBodySingle: String
        let sessionsBodyManyFormat: String
        let closeAnyway: String
        let inspectorTitle: String
        let inspectorBody: String
        let downloadFailed: String

        /// Singular and plural are separate sentences: "1 sessions" reads wrong in both languages.
        func sessionsTitle(count: Int) -> String {
            count == 1 ? sessionsTitleSingle : String(format: sessionsTitleManyFormat, count)
        }

        func sessionsBody(count: Int) -> String {
            count == 1 ? sessionsBodySingle : String(format: sessionsBodyManyFormat, count)
        }
    }

    struct CommonCopy {
        let ok: String
        let cancel: String
    }
}

// MARK: - Embedded copy tables

extension ShellCopy {
    /// Chinese copy table, embedded as one JSON blob. See the struct doc comment for why this is a
    /// single runtime-parsed blob rather than `static let` string fields.
    private static let zhBlob = #"""
    {"menu":{"about":"关于 Orca","settings":"Orca 设置…","services":"服务","hide":"隐藏 Orca","hideOthers":"隐藏其他","showAll":"全部显示","quit":"退出 Orca","file":"文件","closeWindow":"关闭窗口","openInBrowser":"在浏览器中打开","copyAccessLink":"复制访问链接","edit":"编辑","undo":"撤销","redo":"重做","cut":"剪切","copy":"拷贝","paste":"粘贴","selectAll":"全选","view":"显示","reload":"重新载入","reloadFromServer":"从服务器重新载入","actualSize":"实际大小","zoomIn":"放大","zoomOut":"缩小","enterFullScreen":"进入全屏幕","developerTools":"开发者工具","selectElement":"选取检查元素","showConsole":"显示控制台","service":"服务","restartService":"重启本地服务","stopService":"停止本地服务","showServiceLog":"显示服务日志","superagent":"Superagent 面板","window":"窗口","minimize":"最小化","zoom":"缩放","bringAllToFront":"前置全部窗口","help":"帮助","projectPage":"GitHub 上的 DeepSeek Harness"},"settings":{"title":"Orca 设置","port":"端口","portHint":"0 表示自动选择空闲端口","profile":"配置","profileHint":"启动时加载的 dsh 配置","command":"dsh 命令","commandHint":"PATH 中的命令名，或绝对路径","keepAlive":"退出 Orca 后保留本地服务","inputAssistance":"关闭输入辅助","inputAssistanceHint":"在页面的输入框和编辑器中关闭 macOS 的自动纠错、自动补全、拼写检查与首字母大写。","language":"界面语言","languageHint":"只影响 Orca 自己的菜单和面板，页面语言由 DSH 决定。","restartHint":"改动端口、配置或命令会重启本地服务。","invalidTitle":"请检查设置","portError":"端口需在 0 到 65535 之间。","emptyError":"配置和 dsh 命令不能为空。","save":"保存"},"splash":{"preparing":"正在准备本地服务…","tryAgain":"重试","serviceLog":"服务日志","unavailable":"本地服务不可用","pageFailed":"页面没有载入","stopped":"本地服务已停止","stoppedDetail":"随时可以重新启动。","pageFailedDetailFormat":"%@。重试，或打开服务日志查看完整报告。","webProcessLostDetail":"页面的渲染进程反复退出。重试，或打开服务日志查看完整报告。"},"service":{"restarting":"正在重启本地服务…","reconnecting":"正在重新连接本地服务…","loadingWorkspace":"正在载入工作区…","starting":"正在启动本地服务…","freeingPortFormat":"正在释放端口 %ld…","startingOnPortFormat":"正在启动本地服务（端口 %ld）…","commandMissingFormat":"Orca 找不到“%@”。请在 Orca 设置（⌥⌘,）里填写它的路径。","launchFailedFormat":"Orca 无法启动“%@”。请在 Orca 设置（⌥⌘,）里检查命令。","exitedFormat":"本地服务已退出（状态码 %ld）。","didNotStartFormat":"本地服务未能在 %ld 秒内启动。","portHeldFormat":"%@ 正占用端口 %ld，因此插件从默认配置启动。","previousStopped":"上次启动的本地服务已停止响应。重新启动即可重新连接。"},"alert":{"sessionsTitleSingle":"还有会话在运行","sessionsTitleManyFormat":"还有 %ld 个会话在运行","sessionsBodySingle":"有会话正在执行本轮回复。现在关闭会中断它，包括尚未返回的工具调用。","sessionsBodyManyFormat":"有 %ld 个会话正在执行本轮回复。现在关闭会中断它们，包括尚未返回的工具调用。","closeAnyway":"仍然关闭","inspectorTitle":"Web 检查器没有打开","inspectorBody":"WebKit 只为可调试的进程构建检查器。这份 Orca 缺少 com.apple.security.get-task-allow 权利，所以检查器不起作用。\n\n用 ./build.sh 重新构建：它会用 Resources/Orca.entitlements 签名，其中带着这项权利。","downloadFailed":"下载失败"},"common":{"ok":"好","cancel":"取消"}}
    """#

    /// English copy table, embedded as one JSON blob.
    private static let enBlob = #"""
    {"menu":{"about":"About Orca","settings":"Orca Settings…","services":"Services","hide":"Hide Orca","hideOthers":"Hide Others","showAll":"Show All","quit":"Quit Orca","file":"File","closeWindow":"Close Window","openInBrowser":"Open in Browser","copyAccessLink":"Copy Access Link","edit":"Edit","undo":"Undo","redo":"Redo","cut":"Cut","copy":"Copy","paste":"Paste","selectAll":"Select All","view":"View","reload":"Reload","reloadFromServer":"Reload from Server","actualSize":"Actual Size","zoomIn":"Zoom In","zoomOut":"Zoom Out","enterFullScreen":"Enter Full Screen","developerTools":"Developer Tools","selectElement":"Select Element for Inspection","showConsole":"Show Console","service":"Service","restartService":"Restart Local Service","stopService":"Stop Local Service","showServiceLog":"Show Service Log","superagent":"Superagent Panel","window":"Window","minimize":"Minimize","zoom":"Zoom","bringAllToFront":"Bring All to Front","help":"Help","projectPage":"DeepSeek Harness on GitHub"},"settings":{"title":"Orca Settings","port":"Port","portHint":"0 picks a free port automatically","profile":"Profile","profileHint":"dsh profile to boot","command":"dsh command","commandHint":"Command name on PATH, or an absolute path","keepAlive":"Keep the local service running after Orca quits","inputAssistance":"Turn off input assistance","inputAssistanceHint":"Turns off macOS autocorrect, autocomplete, spellcheck, and auto-capitalization in the page's text fields and editors.","language":"Language","languageHint":"Affects only Orca's own menus and panels; the page keeps its own language.","restartHint":"Changes to the port, profile, or command restart the local service.","invalidTitle":"Check the settings","portError":"Enter a port between 0 and 65535.","emptyError":"The profile and the dsh command cannot be empty.","save":"Save"},"splash":{"preparing":"Preparing the local service…","tryAgain":"Try Again","serviceLog":"Service Log","unavailable":"The local service is unavailable","pageFailed":"The page did not load","stopped":"The local service is stopped","stoppedDetail":"Restart it whenever you are ready.","pageFailedDetailFormat":"%@. Retry, or open the service log for the full report.","webProcessLostDetail":"The page’s web process kept exiting. Retry, or open the service log for the full report."},"service":{"restarting":"Restarting the local service…","reconnecting":"Reconnecting to the local service…","loadingWorkspace":"Loading the workspace…","starting":"Starting the local service…","freeingPortFormat":"Freeing port %ld…","startingOnPortFormat":"Starting the local service on port %ld…","commandMissingFormat":"Orca can’t find “%@”. Set its path in Orca Settings (⌥⌘,).","launchFailedFormat":"Orca can’t launch “%@”. Check the command in Orca Settings (⌥⌘,).","exitedFormat":"The local service exited with status %ld.","didNotStartFormat":"The local service did not start within %ld seconds.","portHeldFormat":"%@ holds port %ld, so plugins start from their defaults.","previousStopped":"The local service from the previous launch stopped answering. Start it again to reconnect."},"alert":{"sessionsTitleSingle":"A session is still running","sessionsTitleManyFormat":"%ld sessions are still running","sessionsBodySingle":"A turn is executing. Closing now cuts it short, including any tool call still in flight.","sessionsBodyManyFormat":"%ld sessions are executing a turn. Closing now cuts them short, including any tool call still in flight.","closeAnyway":"Close Anyway","inspectorTitle":"Web Inspector did not open","inspectorBody":"WebKit only builds its inspector for a debuggable process. This copy of Orca is missing the com.apple.security.get-task-allow entitlement, so the inspector is a no-op.\n\nRebuild with ./build.sh — it signs the app with Resources/Orca.entitlements, which carries that entitlement.","downloadFailed":"Download failed"},"common":{"ok":"OK","cancel":"Cancel"}}
    """#

    /// Parses one embedded blob into a fully-populated `ShellCopy`.
    private static func parse(_ blob: String) -> ShellCopy {
        let raw = try! JSONSerialization.jsonObject(with: Data(blob.utf8)) as! [String: [String: String]]
        let menu = MenuCopy(from: raw["menu"]!)
        let settings = SettingsCopy(from: raw["settings"]!)
        let splash = SplashCopy(from: raw["splash"]!)
        let service = ServiceCopy(from: raw["service"]!)
        let alert = AlertCopy(from: raw["alert"]!)
        let common = CommonCopy(from: raw["common"]!)
        return ShellCopy(
            menu: menu, settings: settings, splash: splash,
            service: service, alert: alert, common: common
        )
    }
}

extension ShellCopy.MenuCopy {
    init(from dict: [String: String]) {
        about = dict["about"]!
        settings = dict["settings"]!
        services = dict["services"]!
        hide = dict["hide"]!
        hideOthers = dict["hideOthers"]!
        showAll = dict["showAll"]!
        quit = dict["quit"]!
        file = dict["file"]!
        closeWindow = dict["closeWindow"]!
        openInBrowser = dict["openInBrowser"]!
        copyAccessLink = dict["copyAccessLink"]!
        edit = dict["edit"]!
        undo = dict["undo"]!
        redo = dict["redo"]!
        cut = dict["cut"]!
        copy = dict["copy"]!
        paste = dict["paste"]!
        selectAll = dict["selectAll"]!
        view = dict["view"]!
        reload = dict["reload"]!
        reloadFromServer = dict["reloadFromServer"]!
        actualSize = dict["actualSize"]!
        zoomIn = dict["zoomIn"]!
        zoomOut = dict["zoomOut"]!
        enterFullScreen = dict["enterFullScreen"]!
        developerTools = dict["developerTools"]!
        selectElement = dict["selectElement"]!
        showConsole = dict["showConsole"]!
        service = dict["service"]!
        restartService = dict["restartService"]!
        stopService = dict["stopService"]!
        showServiceLog = dict["showServiceLog"]!
        superagent = dict["superagent"]!
        window = dict["window"]!
        minimize = dict["minimize"]!
        zoom = dict["zoom"]!
        bringAllToFront = dict["bringAllToFront"]!
        help = dict["help"]!
        projectPage = dict["projectPage"]!
    }
}

extension ShellCopy.SettingsCopy {
    init(from dict: [String: String]) {
        title = dict["title"]!
        port = dict["port"]!
        portHint = dict["portHint"]!
        profile = dict["profile"]!
        profileHint = dict["profileHint"]!
        command = dict["command"]!
        commandHint = dict["commandHint"]!
        keepAlive = dict["keepAlive"]!
        inputAssistance = dict["inputAssistance"]!
        inputAssistanceHint = dict["inputAssistanceHint"]!
        language = dict["language"]!
        languageHint = dict["languageHint"]!
        restartHint = dict["restartHint"]!
        invalidTitle = dict["invalidTitle"]!
        portError = dict["portError"]!
        emptyError = dict["emptyError"]!
        save = dict["save"]!
    }
}

extension ShellCopy.SplashCopy {
    init(from dict: [String: String]) {
        preparing = dict["preparing"]!
        tryAgain = dict["tryAgain"]!
        serviceLog = dict["serviceLog"]!
        unavailable = dict["unavailable"]!
        pageFailed = dict["pageFailed"]!
        stopped = dict["stopped"]!
        stoppedDetail = dict["stoppedDetail"]!
        pageFailedDetailFormat = dict["pageFailedDetailFormat"]!
        webProcessLostDetail = dict["webProcessLostDetail"]!
    }
}

extension ShellCopy.ServiceCopy {
    init(from dict: [String: String]) {
        restarting = dict["restarting"]!
        reconnecting = dict["reconnecting"]!
        loadingWorkspace = dict["loadingWorkspace"]!
        starting = dict["starting"]!
        freeingPortFormat = dict["freeingPortFormat"]!
        startingOnPortFormat = dict["startingOnPortFormat"]!
        commandMissingFormat = dict["commandMissingFormat"]!
        launchFailedFormat = dict["launchFailedFormat"]!
        exitedFormat = dict["exitedFormat"]!
        didNotStartFormat = dict["didNotStartFormat"]!
        portHeldFormat = dict["portHeldFormat"]!
        previousStopped = dict["previousStopped"]!
    }
}

extension ShellCopy.AlertCopy {
    init(from dict: [String: String]) {
        sessionsTitleSingle = dict["sessionsTitleSingle"]!
        sessionsTitleManyFormat = dict["sessionsTitleManyFormat"]!
        sessionsBodySingle = dict["sessionsBodySingle"]!
        sessionsBodyManyFormat = dict["sessionsBodyManyFormat"]!
        closeAnyway = dict["closeAnyway"]!
        inspectorTitle = dict["inspectorTitle"]!
        inspectorBody = dict["inspectorBody"]!
        downloadFailed = dict["downloadFailed"]!
    }
}

extension ShellCopy.CommonCopy {
    init(from dict: [String: String]) {
        ok = dict["ok"]!
        cancel = dict["cancel"]!
    }
}
