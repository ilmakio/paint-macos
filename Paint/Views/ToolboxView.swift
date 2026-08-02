import AppKit

/// The classic 2 × 8 toolbox.
final class ToolboxView: NSView {
    var onSelect: ((ToolKind) -> Void)?

    private let columns = 2
    private let cellWidth: CGFloat = 44
    private let cellHeight: CGFloat = 38
    private let gap: CGFloat = 2

    private var buttons: [ToolButton] = []

    init() {
        super.init(frame: .zero)
        for kind in ToolKind.allCases {
            let button = ToolButton(kind: kind)
            button.target = self
            button.action = #selector(pick(_:))
            addSubview(button)
            buttons.append(button)
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let rows = CGFloat((ToolKind.allCases.count + columns - 1) / columns)
        return NSSize(width: CGFloat(columns) * cellWidth + CGFloat(columns - 1) * gap,
                      height: rows * cellHeight + (rows - 1) * gap)
    }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            let row = index / columns
            let column = index % columns
            button.frame = NSRect(x: CGFloat(column) * (cellWidth + gap),
                                  y: CGFloat(row) * (cellHeight + gap),
                                  width: cellWidth, height: cellHeight)
        }
    }

    func refresh() {
        let current = PaintSettings.shared.tool
        for button in buttons { button.isSelected = button.kind == current }
    }

    @objc private func pick(_ sender: ToolButton) {
        PaintSettings.shared.tool = sender.kind
        onSelect?(sender.kind)
    }
}
