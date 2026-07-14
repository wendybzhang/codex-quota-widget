import AppKit

final class TouchBarController: NSObject, NSTouchBarDelegate {
    private static let itemIdentifier = NSTouchBarItem.Identifier("com.wendy.codex-quota-widget.quota")
    private static let trayIdentifier = "com.wendy.codex-quota-widget"

    private let touchBar = NSTouchBar()
    private let quotaView = TouchBarQuotaView()

    private var isUserHidden = false
    private(set) var isPresented = false
    private var lastSnapshot: QuotaSnapshot?
    private var language: WidgetLanguage = .english

    override init() {
        super.init()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [Self.itemIdentifier]
    }

    func codexDidLaunch() {
        isUserHidden = false
    }

    func codexDidExit() {
        dismiss()
        isUserHidden = false
        lastSnapshot = nil
    }

    func show(snapshot: QuotaSnapshot?) {
        if let snapshot {
            lastSnapshot = snapshot
        }
        quotaView.render(snapshot: snapshot ?? lastSnapshot, language: language)

        guard !isUserHidden else {
            return
        }
        present()
    }

    func showAgain() {
        isUserHidden = false
        quotaView.render(snapshot: lastSnapshot, language: language)
        isPresented = false
        present()
    }

    func setLanguage(_ language: WidgetLanguage) {
        self.language = language
        quotaView.render(snapshot: lastSnapshot, language: language)
    }

    func hideForCurrentCodexRun() {
        isUserHidden = true
        dismiss()
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.itemIdentifier else {
            return nil
        }

        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = quotaView
        return item
    }

    private func present() {
        guard !isPresented else {
            return
        }

        let selectors = [
            "presentSystemModalTouchBar:systemTrayItemIdentifier:",
            "presentSystemModalFunctionBar:systemTrayItemIdentifier:",
        ]

        guard performTouchBarClassSelector(selectors, first: touchBar, second: Self.trayIdentifier as NSString) else {
            return
        }
        isPresented = true
    }

    private func dismiss() {
        guard isPresented else {
            return
        }

        let selectors = [
            "dismissSystemModalTouchBar:",
            "dismissSystemModalFunctionBar:",
        ]

        _ = performTouchBarClassSelector(selectors, first: touchBar, second: nil)
        isPresented = false
    }

    private func performTouchBarClassSelector(_ selectorNames: [String], first: Any, second: Any?) -> Bool {
        for selectorName in selectorNames {
            let selector = NSSelectorFromString(selectorName)
            let target = NSTouchBar.self as AnyObject
            guard target.responds(to: selector) else {
                continue
            }

            if let second {
                _ = target.perform(selector, with: first, with: second)
            } else {
                _ = target.perform(selector, with: first)
            }
            return true
        }
        return false
    }
}

private final class TouchBarQuotaView: NSView {
    private let fiveHourRow = TouchBarQuotaRow()
    private let sevenDayRow = TouchBarQuotaRow()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 650, height: 30))
        setupViews()
        render(snapshot: nil, language: .english)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(snapshot: QuotaSnapshot?, language: WidgetLanguage) {
        let windows = snapshot.map(normalizedWindows(from:)) ?? (fiveHour: nil, sevenDay: nil)
        fiveHourRow.isHidden = windows.fiveHour == nil
        sevenDayRow.isHidden = windows.sevenDay == nil
        fiveHourRow.render(label: "5h", quota: windows.fiveHour, resetStyle: .time, language: language)
        sevenDayRow.render(label: "7D", quota: windows.sevenDay, resetStyle: .date, language: language)
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor

        let titleLabel = NSTextField(labelWithString: "Codex")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let rows = NSStackView(views: [fiveHourRow, sevenDayRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        rows.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, rows])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            titleLabel.widthAnchor.constraint(equalToConstant: 46),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func normalizedWindows(from snapshot: QuotaSnapshot) -> (fiveHour: WindowQuota?, sevenDay: WindowQuota?) {
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        let fiveHour = windows.first { $0.label == "5h" }
        let sevenDay = windows.first { $0.label == "7d" }
        return (fiveHour, sevenDay)
    }
}

private final class TouchBarQuotaRow: NSView {
    private let nameLabel = NSTextField(labelWithString: "--")
    private let barView = SegmentedQuotaBarView()
    private let percentLabel = NSTextField(labelWithString: "--%")
    private let resetLabel = NSTextField(labelWithString: "--")

    init() {
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(label: String, quota: WindowQuota?, resetStyle: ResetStyle, language: WidgetLanguage) {
        nameLabel.stringValue = label
        let remaining = quota?.remainingPercent
        let roundedPercent = remaining.map { Int($0.rounded()) }
        percentLabel.stringValue = roundedPercent.map { "\($0)%" } ?? "--%"
        resetLabel.stringValue = TouchBarQuotaFormatter.resetText(quota?.resetsAt, style: resetStyle, language: language)
        barView.render(remainingPercent: remaining)
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        [nameLabel, percentLabel, resetLabel].forEach { label in
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = NSColor.white.withAlphaComponent(0.9)
            label.lineBreakMode = .byClipping
            label.translatesAutoresizingMaskIntoConstraints = false
        }

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        resetLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        resetLabel.textColor = NSColor.white.withAlphaComponent(0.7)

        let stack = NSStackView(views: [nameLabel, barView, percentLabel, resetLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            nameLabel.widthAnchor.constraint(equalToConstant: 24),
            barView.widthAnchor.constraint(equalToConstant: 210),
            barView.heightAnchor.constraint(equalToConstant: 8),
            percentLabel.widthAnchor.constraint(equalToConstant: 46),
            resetLabel.widthAnchor.constraint(equalToConstant: 98),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

private final class SegmentedQuotaBarView: NSView {
    private let segmentCount = 14
    private var activeSegments = 0
    private var activeColor = WidgetColors.mutedColor

    func render(remainingPercent: Double?) {
        let remaining = remainingPercent ?? 0
        activeSegments = Int((remaining / 100 * Double(segmentCount)).rounded())
        activeSegments = min(max(activeSegments, 0), segmentCount)
        activeColor = remainingPercent == nil ? WidgetColors.mutedColor : WidgetColors.color(for: remaining)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let gap: CGFloat = 4
        let segmentWidth = (bounds.width - CGFloat(segmentCount - 1) * gap) / CGFloat(segmentCount)
        let segmentHeight = bounds.height

        for index in 0..<segmentCount {
            let rect = NSRect(
                x: CGFloat(index) * (segmentWidth + gap),
                y: 0,
                width: segmentWidth,
                height: segmentHeight
            )

            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            let color = index < activeSegments
                ? activeColor
                : NSColor.white.withAlphaComponent(0.18)
            color.setFill()
            path.fill()
        }
    }
}

private enum ResetStyle {
    case time
    case date
}

private enum TouchBarQuotaFormatter {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    static func resetText(_ date: Date?, style: ResetStyle, language _: WidgetLanguage) -> String {
        guard let date else {
            return "-- · --"
        }

        switch style {
        case .time:
            let time = timeFormatter.string(from: date)
            return "\(time) · \(countdownText(until: date, style: .time))"
        case .date:
            let dateText = dateFormatter.string(from: date)
            return "\(dateText) · \(countdownText(until: date, style: .date))"
        }
    }

    private static func countdownText(until date: Date, style: ResetStyle) -> String {
        let remainingSeconds = max(0, Int(date.timeIntervalSinceNow))
        let days = remainingSeconds / 86_400
        let hours = (remainingSeconds % 86_400) / 3_600
        let minutes = (remainingSeconds % 3_600) / 60

        switch style {
        case .time:
            if hours > 0 {
                return "\(hours)h\(minutes)m"
            }
            return "\(max(minutes, 0))m"
        case .date:
            if days > 0 {
                return "\(days)d\(hours)h"
            }
            if hours > 0 {
                return "\(hours)h\(minutes)m"
            }
            return "\(max(minutes, 0))m"
        }
    }
}
