import AppKit
import ServiceManagement

// AppKit-only menubar app (builds with Command Line Tools — no SwiftUI macros).
// One section per account (Claude sessions, OpenAI, Figma plans), in the
// user's order (Accounts ▸ Move Up/Down; default Claude, OpenAI, Figma).
// Menubar shows every 5h value side by side, same order.

/// One account row, provider-agnostic, for ordering.
private enum Entry {
    case claude(AnthropicClient.Account)
    case openai
    case figma(FigmaClient.Account)

    var key: String {
        switch self {
        case .claude(let a): return a.key
        case .openai: return "openai"
        case .figma(let a): return a.key
        }
    }

    var provider: String {
        switch self {
        case .claude: return "claude"
        case .openai: return "openai"
        case .figma: return "figma"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var openAI: OpenAIClient.Result?
    private var claudeAccounts: [AnthropicClient.Account] = []
    private var figmaAccounts: [FigmaClient.Account] = []
    private var openAIError: String?
    private var lastUpdated: Date?
    private var isLoading = false

    private let showIconsKey = "showIcons"
    private let hiddenKey = "hiddenAccounts"
    private let hiddenFromBarKey = "hiddenFromBarAccounts"
    private let showPercentKey = "showPercent"
    private let showEmptyKey = "showEmptyAccounts"
    private let wideSeparatorsKey = "wideSeparators"
    private let orderKey = "accountOrder"
    private let legacyCompactKey = "compactMode" // pre-split, migrated once

    /// On by default (missing key counts as enabled).
    private var showIcons: Bool {
        get { UserDefaults.standard.object(forKey: showIconsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showIconsKey) }
    }

    /// Display levers (all on = classic mode; all off ≈ legacy compact).
    /// Each individually toggleable via Display ▸.
    private var showPercent: Bool {
        get { UserDefaults.standard.object(forKey: showPercentKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showPercentKey) }
    }

    private var showEmptyAccounts: Bool {
        get { UserDefaults.standard.object(forKey: showEmptyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showEmptyKey) }
    }

    private var wideSeparators: Bool {
        get { UserDefaults.standard.object(forKey: wideSeparatorsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: wideSeparatorsKey) }
    }

    /// Account keys ("claude:…", "openai", "figma:…") hidden from the dropdown
    /// sections via Accounts ▸. Independent of the menubar.
    private var hiddenFromDropdown: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: hiddenKey) }
    }

    /// Account keys hidden from the menubar via Accounts ▸. Independent of the dropdown.
    private var hiddenFromBar: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenFromBarKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: hiddenFromBarKey) }
    }

    private func isHiddenFromDropdown(_ key: String) -> Bool { hiddenFromDropdown.contains(key) }
    private func isHiddenFromBar(_ key: String) -> Bool { hiddenFromBar.contains(key) }

    private func toggle(_ key: String, in set: inout Set<String>) {
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
    }

    /// Account keys in user order (Accounts ▸ Move Up/Down), shared by the
    /// menubar, the dropdown sections and the Accounts list.
    private var accountOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: orderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: orderKey) }
    }

    /// Every account, saved order first; unknown (new) accounts keep the
    /// default Claude, OpenAI, Figma order after them.
    private func orderedEntries() -> [Entry] {
        let defaults = claudeAccounts.map(Entry.claude) + [.openai] + figmaAccounts.map(Entry.figma)
        return AccountOrder.sorted(defaults, key: \.key, saved: accountOrder)
    }

    /// Accounts ▸ list: OpenAI only once fetched (or failed).
    private func listedEntries() -> [Entry] {
        orderedEntries().filter { e in
            if case .openai = e { return openAI != nil || openAIError != nil }
            return true
        }
    }

    /// One-time: before the split, hiding an account hid it everywhere.
    private func migrateHiddenAccounts() {
        guard UserDefaults.standard.object(forKey: hiddenFromBarKey) == nil else { return }
        hiddenFromBar = hiddenFromDropdown
    }

    /// One-time: legacy Compact mode on → the three levers off.
    private func migrateLegacyCompact() {
        defer { UserDefaults.standard.removeObject(forKey: legacyCompactKey) }
        guard UserDefaults.standard.object(forKey: legacyCompactKey) as? Bool == true,
              UserDefaults.standard.object(forKey: showPercentKey) == nil
        else { return }
        showPercent = false
        showEmptyAccounts = false
        wideSeparators = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        migrateLegacyCompact()
        migrateHiddenAccounts()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        statusItem.menu = buildMenu(loading: true)
        refresh(full: true)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh(full: false)
        }
    }

    // MARK: - Fetch

    /// `full`: also re-read slow-changing account info (Claude org names and
    /// plans) — at startup and on manual Refresh, not on the 60 s timer.
    private func refresh(full: Bool) {
        guard !isLoading else { return }
        #if DEMO // local screenshot build only (scripts/capture, not in the repo)
        if DemoData.isEnabled {
            (claudeAccounts, openAI, figmaAccounts) = DemoData.accounts()
            openAIError = nil
            lastUpdated = Date()
            render()
            return
        }
        #endif
        isLoading = true
        Task { @MainActor in
            async let oTask: (OpenAIClient.Result?, String?) = {
                do { return (try await OpenAIClient.fetch(), nil) }
                catch { return (nil, error.localizedDescription) }
            }()
            async let cTask: [AnthropicClient.Account] = await AnthropicClient.fetchAll(refreshOrgs: full)
            async let fTask: [FigmaClient.Account] = await FigmaClient.fetchAll()
            let (oVal, oErr) = await oTask
            self.openAI = oVal
            self.openAIError = oVal == nil ? oErr : nil
            self.claudeAccounts = await cTask
            self.figmaAccounts = await fTask
            self.lastUpdated = Date()
            self.isLoading = false
            self.render()
        }
    }

    // MARK: - Menu

    private func render() {
        // Menubar shows one value per VISIBLE account, in user order.
        // Consecutive same-provider segments share one icon:
        // "F 0% 0%", not "F 0% F 0%".
        guard let btn = statusItem.button else { return }
        var tagged: [(String, NSImage?, String?)] = orderedEntries().filter { !isHiddenFromBar($0.key) }.map { e in
            let icon: NSImage?
            let buckets: [UsageBucket]?
            switch e {
            case .claude(let a): icon = ProviderIcons.claude(); buckets = a.result?.buckets
            case .openai: icon = ProviderIcons.openAI(); buckets = openAI?.buckets
            case .figma(let a): icon = ProviderIcons.figma(); buckets = a.result?.buckets
            }
            return (e.provider, showIcons ? icon : nil, menubarPercent(buckets).map { fmtPercent($0) })
        }
        if !showEmptyAccounts { tagged = tagged.filter { $0.2 != nil } }
        var prevProvider: String?
        let segs: [(NSImage?, String?)] = tagged.map { (provider, icon, text) in
            defer { prevProvider = provider }
            return (provider == prevProvider ? nil : icon, text)
        }
        btn.attributedTitle = joinSegments(segs)
        statusItem.menu = buildMenu(loading: false)
    }

    /// Menubar value: 5-hour bucket when present, otherwise whatever limit
    /// replaces it (weekly, monthly, …) — e.g. free plans with no 5h window.
    private func menubarPercent(_ buckets: [UsageBucket]?) -> Double? {
        guard let buckets else { return nil }
        if let w = buckets.first(where: {
            $0.id.hasSuffix("-5h") || $0.title == "5-hour" || $0.title.contains("(5h)")
        })?.percent { return w }
        return buckets.compactMap(\.percent).first
    }

    /// Without "%" when showPercent is off.
    private func fmtPercent(_ p: Double) -> String {
        showPercent ? String(format: "%.0f%%", p) : String(format: "%.0f", p)
    }

    /// Without dataless accounts when showEmptyAccounts is off;
    /// narrow single-space separators when wideSeparators is off.
    private func joinSegments(_ segs: [(NSImage?, String?)]) -> NSAttributedString {
        let items = showEmptyAccounts ? segs : segs.filter({ $0.1 != nil })
        guard !items.isEmpty else { return NSAttributedString(string: "—") }
        let joined = NSMutableAttributedString()
        for (i, s) in items.enumerated() {
            if i > 0 { joined.append(NSAttributedString(string: wideSeparators ? " · " : " ")) }
            joined.append(prefixed(s.0, s.1 ?? "—"))
        }
        return joined
    }

    /// "Refresh now · updated 5 seconds ago" — update time baked into one line.
    private func refreshTitle() -> String {
        if isLoading { return "Refreshing…" }
        guard let updated = lastUpdated else { return "Refresh now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Refresh now · updated \(f.localizedString(for: updated, relativeTo: Date()))"
    }

    private func buildMenu(loading: Bool) -> NSMenu {
        let menu = NSMenu()

        // Providers with no account yet (first load) get a placeholder section.
        if claudeAccounts.isEmpty {
            menu.addItem(header("Claude", provider: "claude"))
            menu.addItem(info(loading ? "Loading…" : "No Claude login found — open Claude Desktop."))
        }
        if figmaAccounts.isEmpty {
            menu.addItem(header("Figma", provider: "figma"))
            menu.addItem(info(loading ? "Loading…" : "No Figma login found — open Figma Desktop."))
        }

        // One section per account in user order, headed by its provider icon
        // and name (no separators between sections). Hidden accounts simply
        // have no section (still listed in Accounts ▸).
        for e in orderedEntries() where !isHiddenFromDropdown(e.key) {
            menu.addItem(header(entryTitle(e), provider: e.provider))
            switch e {
            case .claude(let a):
                if let buckets = a.result?.buckets, !buckets.isEmpty {
                    for b in buckets { menu.addItem(bucketItem(b)) }
                    if let e = a.result?.extraUsageText { menu.addItem(info(e)) }
                    if let s = a.result?.spendText { menu.addItem(info(s)) }
                } else if let err = a.error {
                    menu.addItem(info(err))
                } else {
                    menu.addItem(info("Connected — no usage windows reported."))
                }
            case .openai:
                if loading && openAI == nil {
                    menu.addItem(info("Loading…"))
                } else if let buckets = openAI?.buckets, !buckets.isEmpty {
                    for b in buckets { menu.addItem(bucketItem(b)) }
                    if let t = openAI?.creditsText { menu.addItem(info(t)) }
                    if let n = openAI?.resetCredits, n > 0 { menu.addItem(info("Banked resets: \(n)")) }
                } else if let err = openAIError {
                    menu.addItem(info(err))
                } else {
                    // Fetch worked but the plan reports no windows (e.g. free plan):
                    // show credits/monthly info instead of a login error.
                    if let t = openAI?.creditsText { menu.addItem(info(t)) }
                    menu.addItem(info("Plan \(openAI?.plan.map(Formatters.planName) ?? "?") — no usage windows reported."))
                }
            case .figma(let a):
                if let buckets = a.result?.buckets, !buckets.isEmpty {
                    for b in buckets { menu.addItem(bucketItem(b)) }
                } else if let err = a.error {
                    menu.addItem(info(err))
                } else {
                    menu.addItem(info("Connected — no usage windows reported."))
                }
            }
        }
        menu.addItem(.separator())

        // Options
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        // Display options, each individually toggleable — same pattern as Accounts ▸.
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let icons = NSMenuItem(title: "Show provider icons", action: #selector(toggleIcons), keyEquivalent: "")
        icons.target = self
        icons.state = showIcons ? .on : .off
        displayMenu.addItem(icons)

        let percent = NSMenuItem(title: "Show % signs", action: #selector(togglePercent), keyEquivalent: "")
        percent.target = self
        percent.state = showPercent ? .on : .off
        displayMenu.addItem(percent)

        let empty = NSMenuItem(title: "Show empty accounts", action: #selector(toggleEmpty), keyEquivalent: "")
        empty.target = self
        empty.state = showEmptyAccounts ? .on : .off
        displayMenu.addItem(empty)

        let separators = NSMenuItem(title: "Wide separators", action: #selector(toggleSeparators), keyEquivalent: "")
        separators.target = self
        separators.state = wideSeparators ? .on : .off
        displayMenu.addItem(separators)
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        // Per-account visibility and order: each account has its own submenu
        // with one checkbox for the dropdown, one for the menubar, then
        // Move Up/Down (this list always shows every account, in user order).
        let accountsItem = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
        let accountsMenu = NSMenu()
        let listed = listedEntries()
        for (i, e) in listed.enumerated() {
            let item = accountItem(title: entryTitle(e), key: e.key,
                                   canMoveUp: i > 0, canMoveDown: i < listed.count - 1)
            item.image = ProviderIcons.menuIcon(e.provider)
            accountsMenu.addItem(item)
        }
        accountsItem.submenu = accountsMenu
        menu.addItem(accountsItem)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: refreshTitle(), action: #selector(doRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(doQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// Account name without provider prefix — the icon says which provider.
    private func entryTitle(_ e: Entry) -> String {
        switch e {
        case .claude(let a): return a.displayName
        case .openai: return (openAI?.email ?? "OpenAI") + planSuffix(openAI?.plan)
        case .figma(let a): return a.displayName
        }
    }

    // Dropdown rows are custom views: a disabled NSMenuItem renders dimmed and
    // an enabled one highlights on hover — views stay full-contrast and inert.

    private func header(_ s: String, provider: String) -> NSMenuItem {
        rowItem(s, icon: ProviderIcons.menuIcon(provider), bold: true)
    }

    private func info(_ s: String) -> NSMenuItem { rowItem(s) }

    /// "Session: 35% · 11m · detail" — the countdown is the time to reset.
    private func bucketItem(_ b: UsageBucket) -> NSMenuItem {
        let parts = [Formatters.percent(b.percent)]
            + [b.resetsAt.map { Formatters.countdown(to: $0) }, b.detail].compactMap { $0 }
        return rowItem("\(b.title): " + parts.joined(separator: " · "))
    }

    private func rowItem(_ text: String, icon: NSImage? = nil, bold: Bool = false) -> NSMenuItem {
        let size = NSFont.menuFont(ofSize: 0).pointSize
        let label = NSTextField(labelWithString: text)
        label.font = bold ? .boldSystemFont(ofSize: size) : .menuFont(ofSize: size)
        label.textColor = .labelColor
        label.sizeToFit()
        let textX: CGFloat = 38
        let pad: CGFloat = bold ? 6 : 2 // headers get air above, replacing separators
        let height = ceil(label.frame.height) + pad + 2
        let view = NSView(frame: NSRect(x: 0, y: 0, width: textX + ceil(label.frame.width) + 16, height: height))
        view.autoresizingMask = [.width]
        label.frame.origin = NSPoint(x: textX, y: 2)
        view.addSubview(label)
        if let icon {
            let iv = NSImageView(frame: NSRect(x: 14, y: 2 + (label.frame.height - 16) / 2, width: 16, height: 16))
            iv.image = icon
            if icon.isTemplate { iv.contentTintColor = .labelColor }
            view.addSubview(iv)
        }
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func planSuffix(_ plan: String?) -> String {
        guard let plan, !plan.isEmpty else { return "" }
        return " (\(Formatters.planName(plan)))"
    }

    private func accountItem(title: String, key: String, canMoveUp: Bool, canMoveDown: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false // Move Up/Down greyed at the ends
        submenu.addItem(surfaceToggle("Show in dropdown", key: key,
                                      action: #selector(toggleDropdownAccount),
                                      shown: !isHiddenFromDropdown(key)))
        submenu.addItem(surfaceToggle("Show in menu bar", key: key,
                                      action: #selector(toggleBarAccount),
                                      shown: !isHiddenFromBar(key)))
        submenu.addItem(.separator())
        submenu.addItem(moveItem("Move Up", key: key, action: #selector(moveAccountUp), enabled: canMoveUp))
        submenu.addItem(moveItem("Move Down", key: key, action: #selector(moveAccountDown), enabled: canMoveDown))
        item.submenu = submenu
        return item
    }

    private func moveItem(_ title: String, key: String, action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = key
        item.isEnabled = enabled
        return item
    }

    @objc private func moveAccountUp(_ sender: NSMenuItem) { moveAccount(sender, by: -1) }
    @objc private func moveAccountDown(_ sender: NSMenuItem) { moveAccount(sender, by: 1) }

    /// Swaps with the neighbour in the Accounts ▸ list. Saved keys of accounts
    /// absent right now (failed fetch, logged out) keep their place at the end.
    private func moveAccount(_ sender: NSMenuItem, by offset: Int) {
        guard let key = sender.representedObject as? String,
              let order = AccountOrder.moving(key, by: offset, in: listedEntries().map(\.key), saved: accountOrder)
        else { return }
        accountOrder = order
        render()
    }

    private func surfaceToggle(_ title: String, key: String, action: Selector, shown: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = shown ? .on : .off
        item.representedObject = key
        return item
    }

    @objc private func toggleDropdownAccount(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var hidden = hiddenFromDropdown
        toggle(key, in: &hidden)
        hiddenFromDropdown = hidden
        render()
    }

    @objc private func toggleBarAccount(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var hidden = hiddenFromBar
        toggle(key, in: &hidden)
        hiddenFromBar = hidden
        render()
    }

    /// " [icon] text" for menubar buttons (white pre-rendered glyphs).
    /// Attachment height fixed, width follows the icon aspect.
    /// Nil icon = plain text.
    private func prefixed(_ icon: NSImage?, _ text: String) -> NSMutableAttributedString {
        guard let icon else { return NSMutableAttributedString(string: text) }
        let out = NSMutableAttributedString()
        let att = NSTextAttachment()
        att.image = icon
        let h: CGFloat = 13
        let aspect = (icon.size.width > 0 && icon.size.height > 0)
            ? icon.size.width / icon.size.height : 1
        att.bounds = CGRect(x: 0, y: -2, width: h * aspect, height: h)
        out.append(NSAttributedString(attachment: att))
        out.append(NSAttributedString(string: " " + text))
        return out
    }

    @objc private func doRefresh() { refresh(full: true) }
    @objc private func doQuit() { NSApplication.shared.terminate(nil) }

    @objc private func toggleIcons() {
        showIcons.toggle()
        render()
    }

    @objc private func togglePercent() {
        showPercent.toggle()
        render()
    }

    @objc private func toggleEmpty() {
        showEmptyAccounts.toggle()
        render()
    }

    @objc private func toggleSeparators() {
        wideSeparators.toggle()
        render()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Keep the menu truthful on failure (e.g. ad-hoc signature rejected).
            NSSound.beep()
        }
        render()
    }
}

if CommandLine.arguments.contains("--test") {
    // Headless check: fetch all providers, print redacted summary, exit.
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let o = try await OpenAIClient.fetch()
            print("OPENAI plan=\(o.plan ?? "?") " + o.buckets.map { "\($0.title)=\(Formatters.percent($0.percent))" }.joined(separator: " "))
        } catch { print("OPENAI FAILED: \(error.localizedDescription)") }
        for a in await AnthropicClient.fetchAll() {
            if let r = a.result {
                print("CLAUDE [\(a.displayName)] " + r.buckets.map { "\($0.title)=\(Formatters.percent($0.percent)) reset=\(Formatters.countdown(to: $0.resetsAt))" }.joined(separator: " | "))
            } else {
                print("CLAUDE [\(a.displayName)] FAILED: \(a.error ?? "?")")
            }
        }
        for a in await FigmaClient.fetchAll() {
            if let r = a.result {
                print("FIGMA [\(a.displayName)] " + r.buckets.map { "\($0.title)=\(Formatters.percent($0.percent)) reset=\(Formatters.countdown(to: $0.resetsAt))" }.joined(separator: " | "))
            } else {
                print("FIGMA [\(a.displayName)] FAILED: \(a.error ?? "?")")
            }
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
