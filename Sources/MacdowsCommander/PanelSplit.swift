import AppKit

/// The two panels side by side with a bar between them. Drag the bar left or right to give one panel more room;
/// a double click on it makes them equal again. The place is remembered for the next start.
final class PanelSplitView: NSView {
    static let defaultsKey = "panelSplit.v1"
    static let barWidth: CGFloat = 8
    /// Neither panel gets narrower than this share of the window, so its columns stay usable.
    static let limits: ClosedRange<CGFloat> = 0.15...0.85

    private let leftView: NSView
    private let rightView: NSView
    private let bar = SplitBar()
    private var leftWidth: NSLayoutConstraint!
    private let defaults: UserDefaults

    /// The left panel's share of the width without the bar.
    private(set) var ratio: CGFloat

    init(left: NSView, right: NSView, defaults: UserDefaults = .standard) {
        leftView = left
        rightView = right
        self.defaults = defaults
        let saved = defaults.object(forKey: Self.defaultsKey) as? Double
        ratio = Self.clamp(CGFloat(saved ?? 0.5))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for view in [left, right, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        bar.owner = self
        leftWidth = makeLeftWidth()
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            left.topAnchor.constraint(equalTo: topAnchor),
            left.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            bar.widthAnchor.constraint(equalToConstant: Self.barWidth),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            right.leadingAnchor.constraint(equalTo: bar.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.topAnchor.constraint(equalTo: topAnchor),
            right.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftWidth,
        ])
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, limits.lowerBound), limits.upperBound)
    }

    private func makeLeftWidth() -> NSLayoutConstraint {
        // left = (whole width - bar) * ratio
        let constraint = leftView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: ratio, constant: -Self.barWidth * ratio)
        constraint.priority = .defaultHigh
        return constraint
    }

    func setRatio(_ value: CGFloat, remember: Bool = true) {
        let clamped = Self.clamp(value)
        guard clamped != ratio else { return }
        ratio = clamped
        leftWidth.isActive = false
        leftWidth = makeLeftWidth()
        leftWidth.isActive = true
        if remember { defaults.set(Double(clamped), forKey: Self.defaultsKey) }
    }

    /// The bar was dragged: `x` is where the pointer is in this view.
    func drag(toX x: CGFloat) {
        let room = bounds.width - Self.barWidth
        guard room > 0 else { return }
        setRatio((x - Self.barWidth / 2) / room)
    }

    func reset() { setRatio(0.5) }
}

private final class SplitBar: NSView {
    weak var owner: PanelSplitView?
    private var isHovering = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(new)
        area = new
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func draw(_ dirtyRect: NSRect) {
        // A thin line in the middle, stronger under the pointer so it is clear this can be grabbed.
        (isHovering ? Theme.accent : Theme.border).setFill()
        let width: CGFloat = isHovering ? 3 : 1
        NSRect(x: bounds.midX - width / 2, y: 4, width: width, height: max(0, bounds.height - 8)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner?.reset() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let owner else { return }
        owner.drag(toX: owner.convert(event.locationInWindow, from: nil).x)
    }
}
