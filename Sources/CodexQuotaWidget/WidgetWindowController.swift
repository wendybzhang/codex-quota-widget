import AppKit

final class WidgetWindowController: NSObject, NSWindowDelegate {
    let window: NSPanel
    var onRequestRefresh: (() -> Void)?
    var onShowTouchBar: (() -> Void)?
    var onOpenTouchBarSettings: (() -> Void)?
    var onToggleLanguage: (() -> WidgetLanguage)?
    var currentLanguage: (() -> WidgetLanguage)?

    private let stateStore: WidgetStateStore
    private let contentView = WidgetContentView()
    private var isExpanded = false
    private var hasPlacedWindow = false

    init(stateStore: WidgetStateStore) {
        self.stateStore = stateStore
        self.window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 154, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        setupWindow()
        setupContent()
        restoreInitialPlacement()
    }

    func show(snapshot: QuotaSnapshot?) {
        update(snapshot: snapshot)
        if !hasPlacedWindow {
            restoreInitialPlacement()
        }
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    func hide() {
        window.orderOut(nil)
    }

    func toggleExpanded() {
        isExpanded.toggle()
        applySize()
    }

    func update(snapshot: QuotaSnapshot?) {
        contentView.render(snapshot: snapshot)
    }

    func windowDidMove(_ notification: Notification) {
        let frame = window.frame
        stateStore.save(WidgetState(originX: frame.origin.x, originY: frame.origin.y))
    }

    private func setupWindow() {
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func setupContent() {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.onToggleExpanded = { [weak self] in
            self?.toggleExpanded()
        }
        contentView.onRequestRefresh = { [weak self] in
            self?.onRequestRefresh?()
        }
        contentView.onShowTouchBar = { [weak self] in
            self?.onShowTouchBar?()
        }
        contentView.onOpenTouchBarSettings = { [weak self] in
            self?.onOpenTouchBarSettings?()
        }
        contentView.onToggleLanguage = { [weak self] in
            self?.onToggleLanguage?() ?? .english
        }
        contentView.currentLanguage = { [weak self] in
            self?.currentLanguage?() ?? .english
        }
        window.contentView = contentView

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])

        applySize()
    }

    private func restoreInitialPlacement() {
        let state = stateStore.load()
        if let x = state.originX, let y = state.originY {
            window.setFrameOrigin(clampedOrigin(for: NSPoint(x: x, y: y), size: currentSize))
        } else {
            let frame = defaultFrame(for: currentSize)
            window.setFrame(frame, display: false)
        }
        hasPlacedWindow = true
    }

    private var currentSize: NSSize {
        isExpanded ? NSSize(width: 228, height: 118) : NSSize(width: 154, height: 32)
    }

    private func applySize() {
        contentView.setExpanded(isExpanded)
        let newSize = currentSize
        var frame = window.frame
        let deltaHeight = newSize.height - frame.size.height
        frame.origin.y -= deltaHeight
        frame.size = newSize
        frame.origin = clampedOrigin(for: frame.origin, size: frame.size)
        window.setFrame(frame, display: true, animate: true)
    }

    private func defaultFrame(for size: NSSize) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let x = visible.maxX - size.width - 18
        let y = visible.maxY - size.height - 26
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func clampedOrigin(for origin: NSPoint, size: NSSize) -> NSPoint {
        let screen = screenContaining(point: origin) ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame

        let minX = visible.minX + 8
        let maxX = visible.maxX - size.width - 8
        let minY = visible.minY + 8
        let maxY = visible.maxY - size.height - 8

        return NSPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

private final class WidgetContentView: NSView {
    var onToggleExpanded: (() -> Void)?
    var onRequestRefresh: (() -> Void)?
    var onShowTouchBar: (() -> Void)?
    var onOpenTouchBarSettings: (() -> Void)?
    var onToggleLanguage: (() -> WidgetLanguage)?
    var currentLanguage: (() -> WidgetLanguage)?
    private var mouseDownWindowOrigin: NSPoint?
    private var suppressNextMouseUp = false

    private let summaryStack = NSStackView()
    private let primarySummaryView = SummaryQuotaView(title: "5h")
    private let secondarySummaryView = SummaryQuotaView(title: "7d")
    private let detailStack = NSStackView()
    private let fiveHourLabel = NSTextField(labelWithString: "5h: --")
    private let sevenDayLabel = NSTextField(labelWithString: "7d: --")
    private let resetLabel = NSTextField(labelWithString: "重置: --")
    private let freshnessLabel = NSTextField(labelWithString: "最新日志: --")
    private let planLabel = NSTextField(labelWithString: "套餐: --")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    func render(snapshot: QuotaSnapshot?) {
        layer?.backgroundColor = WidgetColors.backgroundColor.cgColor

        if let snapshot {
            let windows = normalizedWindows(from: snapshot)
            let fiveHour = windows.fiveHour
            let sevenDay = windows.sevenDay
            primarySummaryView.isHidden = fiveHour == nil
            secondarySummaryView.isHidden = sevenDay == nil

            primarySummaryView.render(
                label: "5h",
                remainingPercent: fiveHour.map { Int($0.remainingPercent.rounded()) },
                color: WidgetColors.color(for: fiveHour?.remainingPercent)
            )
            primarySummaryView.toolTip = fiveHour.map {
                "5h: 剩余 \(Int($0.remainingPercent.rounded()))%"
            } ?? "5h: 当前日志未提供"

            secondarySummaryView.render(
                label: "7d",
                remainingPercent: sevenDay.map { Int($0.remainingPercent.rounded()) },
                color: WidgetColors.color(for: sevenDay?.remainingPercent)
            )
            secondarySummaryView.toolTip = sevenDay.map {
                "7d: 剩余 \(Int($0.remainingPercent.rounded()))%"
            } ?? "7d: 当前日志未提供"

            if let fiveHour {
                fiveHourLabel.stringValue = "5h: 剩余 \(Int(fiveHour.remainingPercent.rounded()))% · 已用 \(Int(fiveHour.usedPercent.rounded()))%"
            } else {
                fiveHourLabel.stringValue = "5h: 当前日志未提供"
            }
            fiveHourLabel.isHidden = fiveHour == nil

            if let sevenDay {
                sevenDayLabel.stringValue = "7d: 剩余 \(Int(sevenDay.remainingPercent.rounded()))% · 已用 \(Int(sevenDay.usedPercent.rounded()))%"
            } else {
                sevenDayLabel.stringValue = "7d: 当前日志未提供"
            }
            sevenDayLabel.isHidden = sevenDay == nil

            let resetParts = [
                fiveHour.map { "5h \(WidgetFormatter.timeUntilReset($0.resetsAt))" },
                sevenDay.map { "7d \(WidgetFormatter.timeUntilReset($0.resetsAt))" },
            ].compactMap { $0 }
            resetLabel.stringValue = "重置: \(resetParts.isEmpty ? "--" : resetParts.joined(separator: " · "))"
            freshnessLabel.stringValue = "数据来源: \(snapshot.sourceFileName) · \(WidgetFormatter.relativeAge(snapshot.eventTimestamp))"
            planLabel.stringValue = "套餐: \(snapshot.planType ?? "unknown")"
        } else {
            primarySummaryView.isHidden = true
            secondarySummaryView.isHidden = false
            primarySummaryView.render(label: "5h", remainingPercent: nil, color: WidgetColors.mutedColor)
            secondarySummaryView.render(label: "7d", remainingPercent: nil, color: WidgetColors.mutedColor)
            fiveHourLabel.isHidden = true
            sevenDayLabel.isHidden = false
            fiveHourLabel.stringValue = "5h: 等 Codex 写入额度数据"
            sevenDayLabel.stringValue = "7d: 等 Codex 写入额度数据"
            resetLabel.stringValue = "重置: --"
            freshnessLabel.stringValue = "数据来源: 暂无"
            planLabel.stringValue = "套餐: --"
        }
    }

    func setExpanded(_ expanded: Bool) {
        detailStack.isHidden = !expanded
    }

    private func setupViews() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 7
        container.translatesAutoresizingMaskIntoConstraints = false

        summaryStack.orientation = .horizontal
        summaryStack.alignment = .centerY
        summaryStack.distribution = .fillEqually
        summaryStack.spacing = 8
        summaryStack.translatesAutoresizingMaskIntoConstraints = false
        summaryStack.addArrangedSubview(primarySummaryView)
        summaryStack.addArrangedSubview(secondarySummaryView)
        primarySummaryView.translatesAutoresizingMaskIntoConstraints = false
        secondarySummaryView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            primarySummaryView.widthAnchor.constraint(equalToConstant: 60),
            secondarySummaryView.widthAnchor.constraint(equalToConstant: 60),
        ])

        [fiveHourLabel, sevenDayLabel, resetLabel, freshnessLabel, planLabel].forEach { label in
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = NSColor.white.withAlphaComponent(0.9)
            label.lineBreakMode = .byTruncatingTail
            detailStack.addArrangedSubview(label)
        }
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 4
        detailStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 2)
        detailStack.isHidden = true

        container.addArrangedSubview(summaryStack)
        container.addArrangedSubview(detailStack)
        addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            suppressNextMouseUp = true
            showContextMenu(with: event)
            return
        }

        mouseDownWindowOrigin = window?.frame.origin
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextMouseUp {
            suppressNextMouseUp = false
            return
        }

        guard isClickWithoutDrag() else {
            return
        }

        if event.clickCount >= 2 {
            onRequestRefresh?()
            return
        }

        onToggleExpanded?()
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    private func isClickWithoutDrag() -> Bool {
        guard
            let downOrigin = mouseDownWindowOrigin,
            let currentOrigin = window?.frame.origin
        else {
            return true
        }
        return abs(currentOrigin.x - downOrigin.x) < 1 && abs(currentOrigin.y - downOrigin.y) < 1
    }

    private func showContextMenu(with event: NSEvent) {
        let menu = NSMenu()
        let expanded = !detailStack.isHidden

        let toggleItem = NSMenuItem(
            title: expanded ? "收起详情" : "展开详情",
            action: #selector(handleContextToggle),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let refreshItem = NSMenuItem(
            title: "立即更新",
            action: #selector(handleContextRefresh),
            keyEquivalent: ""
        )
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(.separator())

        let touchBarItem = NSMenuItem(
            title: "显示 Touch Bar",
            action: #selector(handleContextShowTouchBar),
            keyEquivalent: ""
        )
        touchBarItem.target = self
        menu.addItem(touchBarItem)

        let touchBarSettingsItem = NSMenuItem(
            title: "打开 Touch Bar 设置...",
            action: #selector(handleContextOpenTouchBarSettings),
            keyEquivalent: ""
        )
        touchBarSettingsItem.target = self
        menu.addItem(touchBarSettingsItem)
        menu.addItem(.separator())

        let languageItem = NSMenuItem(
            title: currentLanguage?().menuTitle ?? WidgetLanguage.english.menuTitle,
            action: #selector(handleContextToggleLanguage),
            keyEquivalent: ""
        )
        languageItem.target = self
        menu.addItem(languageItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc
    private func handleContextToggle() {
        onToggleExpanded?()
    }

    @objc
    private func handleContextRefresh() {
        onRequestRefresh?()
    }

    @objc
    private func handleContextShowTouchBar() {
        onShowTouchBar?()
    }

    @objc
    private func handleContextOpenTouchBarSettings() {
        onOpenTouchBarSettings?()
    }

    @objc
    private func handleContextToggleLanguage() {
        _ = onToggleLanguage?()
    }

    private func normalizedWindows(from snapshot: QuotaSnapshot) -> (fiveHour: WindowQuota?, sevenDay: WindowQuota?) {
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        let fiveHour = windows.first { $0.label == "5h" }
        let sevenDay = windows.first { $0.label == "7d" }
        return (fiveHour, sevenDay)
    }
}

enum WidgetColors {
    static let backgroundColor = NSColor(calibratedRed: 0.07, green: 0.1, blue: 0.15, alpha: 0.94)
    static let mutedColor = NSColor.white.withAlphaComponent(0.45)

    static func color(for remainingPercent: Double?) -> NSColor {
        let value = remainingPercent ?? 0
        switch value {
        case 60...:
            return NSColor(calibratedRed: 0.23, green: 0.79, blue: 0.39, alpha: 1)
        case 30...:
            return NSColor(calibratedRed: 0.97, green: 0.72, blue: 0.22, alpha: 1)
        default:
            return NSColor(calibratedRed: 0.96, green: 0.4, blue: 0.36, alpha: 1)
        }
    }
}

private final class SummaryQuotaView: NSView {
    private let colorDot = DotView()
    private let valueLabel = NSTextField(labelWithString: "--")

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = false
        setupViews()
        render(label: title, remainingPercent: nil, color: WidgetColors.mutedColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(label: String, remainingPercent: Int?, color: NSColor) {
        colorDot.fillColor = color
        let percentText: String
        if let remainingPercent {
            percentText = String(format: "%3d%%", remainingPercent)
        } else {
            percentText = " --%"
        }
        valueLabel.stringValue = "\(label) \(percentText)"
    }

    private func setupViews() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueLabel.textColor = .white
        valueLabel.alignment = .center
        valueLabel.lineBreakMode = .byClipping
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.addArrangedSubview(colorDot)
        stack.addArrangedSubview(valueLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            colorDot.widthAnchor.constraint(equalToConstant: 6),
            colorDot.heightAnchor.constraint(equalToConstant: 6),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }
}

private final class DotView: NSView {
    var fillColor: NSColor = .white {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        fillColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

private enum WidgetFormatter {
    static func timeUntilReset(_ date: Date?) -> String {
        guard let date else { return "--" }
        let delta = Int(date.timeIntervalSinceNow)
        guard delta > 0 else { return "已重置" }

        let hours = delta / 3600
        let minutes = (delta % 3600) / 60

        if hours >= 24 {
            return "\(hours / 24)d \(hours % 24)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    static func relativeAge(_ date: Date?) -> String {
        guard let date else { return "未知" }
        let delta = max(0, Int(-date.timeIntervalSinceNow))
        if delta < 60 {
            return "\(delta)s 前"
        }
        let minutes = delta / 60
        if minutes < 60 {
            return "\(minutes)m 前"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h 前"
        }
        return "\(hours / 24)d 前"
    }
}
