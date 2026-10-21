import AppKit

/// Clickable menu row that keeps the menu open: a standard NSMenuItem closes
/// the whole menu when chosen, a view-based one doesn't. Drawn like a system
/// item (checkmark column, title, rounded highlight while hovered); metrics
/// match the standard rows around it.
final class ActionRowView: NSView {
    var title: String { didSet { needsDisplay = true } }
    /// nil = plain action row (no checkmark column content).
    var isOn: Bool? { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    private let onClick: (ActionRowView) -> Void

    private static let height: CGFloat = 24
    private static let checkX: CGFloat = 12
    private static let textX: CGFloat = 30
    private static var font: NSFont { .menuFont(ofSize: 0) }

    init(title: String, isOn: Bool?, onClick: @escaping (ActionRowView) -> Void) {
        self.title = title
        self.isOn = isOn
        self.onClick = onClick
        let width = Self.textX + ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 24
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Menu item hosting this row.
    static func item(_ title: String, isOn: Bool? = nil, onClick: @escaping (ActionRowView) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = ActionRowView(title: title, isOn: isOn, onClick: onClick)
        return item
    }

    // The menu doesn't report hover to view-based items: track it here.
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var highlighted: Bool { isEnabled && hovered }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovered = false // menu reopened: no stale highlight
    }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 7, yRadius: 7).fill()
        }
        let color: NSColor = !isEnabled ? .tertiaryLabelColor : highlighted ? .selectedMenuItemTextColor : .labelColor
        if isOn == true,
           let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "On")?
               .withSymbolConfiguration(.init(pointSize: Self.font.pointSize - 2, weight: .semibold))
        {
            let tinted = NSImage(size: check.size, flipped: false) { r in
                check.draw(in: r)
                color.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(at: NSPoint(x: Self.checkX, y: (bounds.height - check.size.height) / 2),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: Self.textX, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        onClick(self)
    }
}
