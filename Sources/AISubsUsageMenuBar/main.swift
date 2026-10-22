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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var openAI: OpenAIClient.Result?
    private var claudeAccounts: [AnthropicClient.Account] = []
    private var figmaAccounts: [FigmaClient.Account] = []
    private var openAIError: String?
    private var lastUpdated: Date?
    private var isLoading = false

    // While the menu is open, changes update it in place (rebuilding would
    // close it); it is rebuilt from scratch when it closes.
    private var menuIsOpen = false
    private weak var accountsMenu: NSMenu?
    private weak var refreshItem: NSMenuItem?
    private let sectionTag = 1 // the single item holding all account sections
    /// Accounts with a section in the menu as last built. While the menu is
    /// open its height must not change (macOS would leave the open row's
    /// highlight behind): hiding dims a section, un-hiding one that isn't
    /// there waits for the next open.
    private var builtSectionKeys: [String] = []

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
        if menuIsOpen, let menu = statusItem.menu {
            updateOpenMenu(menu)
        } else {
            statusItem.menu = buildMenu(loading: false)
        }
    }

    /// Open menu: swap the account sections, follow the Accounts ▸ order,
    /// refresh the "updated …" line. Items the user may be hovering (Display,
    /// Accounts and their submenus) stay in place so nothing collapses.
    private func updateOpenMenu(_ menu: NSMenu) {
        // All sections live in one item's view: swapping that view never
        // shifts the menu's items, so the hovered row stays right.
        if let sections = menu.items.first(where: { $0.tag == sectionTag }), let stack = sections.view {
            let fresh = sectionsView(loading: false, keeping: builtSectionKeys)
            if texts(in: fresh) != texts(in: stack) {
                // Same container, new rows: the menu keeps its item and just
                // resizes; a full redraw clears what the old rows left behind.
                stack.subviews.forEach { $0.removeFromSuperview() }
                fresh.subviews.forEach { stack.addSubview($0) }
                stack.setFrameSize(fresh.frame.size)
                menu.itemChanged(sections)
                stack.window?.contentView?.needsDisplay = true
                stack.window?.displayIfNeeded()
            }
        }
        refreshItem?.title = refreshTitle()
        guard let accountsMenu else { return }
        let keys = listedEntries().map(\.key)
        for item in accountsMenu.items {
            guard let key = item.representedObject as? String, let pos = keys.firstIndex(of: key) else { continue }
            for row in item.submenu?.items.compactMap({ $0.view as? ActionRowView }) ?? [] {
                if row.identifier == moveUpID { row.isEnabled = pos > 0 }
                if row.identifier == moveDownID { row.isEnabled = pos < keys.count - 1 }
            }
        }
    }

    /// Every label in a view tree, to tell whether the sections changed.
    private func texts(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + (view.alphaValue < 1 ? ["(dimmed)"] : []) + view.subviews.flatMap(texts)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu { menuIsOpen = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        menuIsOpen = false
        statusItem.menu = buildMenu(loading: isLoading && lastUpdated == nil)
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

    /// Account section rows at the top of the dropdown (stacked by sectionsView).
    /// `keeping`: open-menu update — exactly these accounts, hidden ones dimmed.
    private func sectionItems(loading: Bool, keeping: [String]? = nil) -> [NSMenuItem] {
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
        let shown = orderedEntries().filter { keeping?.contains($0.key) ?? !isHiddenFromDropdown($0.key) }
        if keeping == nil { builtSectionKeys = shown.map(\.key) }
        for e in shown {
            let first = menu.items.count
            defer {
                if isHiddenFromDropdown(e.key) { menu.items[first...].forEach { $0.view?.alphaValue = 0.35 } }
            }
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
        let items = menu.items
        menu.removeAllItems()
        return items
    }

    /// All section rows stacked in one view (one menu item).
    private func sectionsView(loading: Bool, keeping: [String]? = nil) -> NSView {
        // Detach each row from its temporary menu item before re-parenting it.
        let rows = sectionItems(loading: loading, keeping: keeping).compactMap { item -> NSView? in
            let view = item.view
            item.view = nil
            return view
        }
        let width = rows.map(\.frame.width).max() ?? 0
        let stack = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: rows.map(\.frame.height).reduce(0, +)))
        stack.autoresizingMask = [.width]
        var y: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: width, height: row.frame.height)
            row.autoresizingMask = [.width, .maxYMargin] // pinned to the top
            stack.addSubview(row)
            y += row.frame.height
        }
        return stack
    }

    private func buildMenu(loading: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let sections = NSMenuItem()
        sections.view = sectionsView(loading: loading)
        sections.tag = sectionTag
        menu.addItem(sections)
        menu.addItem(.separator())

        // Options
        menu.addItem(ActionRowView.item("Open at Login", isOn: SMAppService.mainApp.status == .enabled) { [weak self] row in
            self?.toggleLoginItem(row)
        })

        // Display options, each individually toggleable — same pattern as Accounts ▸.
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.addItem(settingRow("Show provider icons", \.showIcons))
        displayMenu.addItem(settingRow("Show % signs", \.showPercent))
        displayMenu.addItem(settingRow("Show empty accounts", \.showEmptyAccounts))
        displayMenu.addItem(settingRow("Wide separators", \.wideSeparators))
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        // Per-account visibility and order: each account has its own submenu
        // with one checkbox for the dropdown, one for the menubar, then
        // Move Up/Down (this list always shows every account, in user order).
        let accountsItem = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
        let accountsMenu = NSMenu()
        self.accountsMenu = accountsMenu
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
        refreshItem = refresh
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

    private let moveUpID = NSUserInterfaceItemIdentifier("moveUp")
    private let moveDownID = NSUserInterfaceItemIdentifier("moveDown")

    private func accountItem(title: String, key: String, canMoveUp: Bool, canMoveDown: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = key
        let submenu = NSMenu()
        submenu.addItem(ActionRowView.item("Show in dropdown", isOn: !isHiddenFromDropdown(key)) { [weak self] row in
            guard let self else { return }
            var hidden = hiddenFromDropdown
            toggle(key, in: &hidden)
            hiddenFromDropdown = hidden
            row.isOn = !hidden.contains(key)
            render()
        })
        submenu.addItem(ActionRowView.item("Show in menu bar", isOn: !isHiddenFromBar(key)) { [weak self] row in
            guard let self else { return }
            var hidden = hiddenFromBar
            toggle(key, in: &hidden)
            hiddenFromBar = hidden
            row.isOn = !hidden.contains(key)
            render()
        })
        submenu.addItem(.separator())
        let up = ActionRowView.item("Move Up") { [weak self] _ in self?.moveAccount(key, by: -1) }
        up.view?.identifier = moveUpID
        (up.view as? ActionRowView)?.isEnabled = canMoveUp
        submenu.addItem(up)
        let down = ActionRowView.item("Move Down") { [weak self] _ in self?.moveAccount(key, by: 1) }
        down.view?.identifier = moveDownID
        (down.view as? ActionRowView)?.isEnabled = canMoveDown
        submenu.addItem(down)
        item.submenu = submenu
        return item
    }

    /// Swaps with the neighbour in the Accounts ▸ list. Saved keys of accounts
    /// absent right now (failed fetch, logged out) keep their place at the end.
    /// In the open menu the two rows swap contents rather than positions:
    /// removing and re-inserting an item left a stale white "selected" title.
    private func moveAccount(_ key: String, by offset: Int) {
        guard let order = AccountOrder.moving(key, by: offset, in: listedEntries().map(\.key), saved: accountOrder)
        else { return }
        accountOrder = order
        if menuIsOpen, let accountsMenu,
           let i = accountsMenu.items.firstIndex(where: { $0.representedObject as? String == key }),
           accountsMenu.items.indices.contains(i + offset)
        {
            let a = accountsMenu.items[i], b = accountsMenu.items[i + offset]
            let (title, image, key, submenu) = (a.title, a.image, a.representedObject, a.submenu)
            let other = b.submenu
            a.submenu = nil // a menu can belong to one item at a time
            b.submenu = nil
            (a.title, a.image, a.representedObject, a.submenu) = (b.title, b.image, b.representedObject, other)
            (b.title, b.image, b.representedObject, b.submenu) = (title, image, key, submenu)
        }
        render()
    }

    /// Display ▸ checkbox bound to a setting; stays open after a click.
    private func settingRow(_ title: String, _ setting: ReferenceWritableKeyPath<AppDelegate, Bool>) -> NSMenuItem {
        ActionRowView.item(title, isOn: self[keyPath: setting]) { [weak self] row in
            guard let self else { return }
            self[keyPath: setting].toggle()
            row.isOn = self[keyPath: setting]
            render()
        }
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

    private func toggleLoginItem(_ row: ActionRowView) {
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
        row.isOn = SMAppService.mainApp.status == .enabled
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

/// Top-down layout for stacked menu rows.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
