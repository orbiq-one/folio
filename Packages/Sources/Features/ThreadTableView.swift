import AppKit
import Domain
import SwiftUI

enum ThreadTableItem: Hashable {
    case header(ActivityCategory)
    case senderGroup(ActivityFeedGroup.ID)
    case row(ThreadSelection)

    var rowID: ThreadSelection? { if case .row(let id) = self { id } else { nil } }
}

struct ThreadTableContent {
    var items: [ThreadTableItem] = []
    var rows: [ThreadSelection: ThreadListRow] = [:]
    var groups: [ActivityFeedGroup.ID: ActivityFeedGroup] = [:]
    var expanded: Set<ActivityFeedGroup.ID> = []

    init() {}

    init(rows: [ThreadListRow], isActivity: Bool, showsHeaders: Bool = true, expanded: Set<ActivityFeedGroup.ID>) {
        self.expanded = expanded
        self.rows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard isActivity else { items = rows.map { .row($0.id) }; return }
        for section in ActivityFeedSection.group(rows) {
            if showsHeaders { items.append(.header(section.category)) }
            for group in section.groups {
                groups[group.id] = group
                if group.isCollapsedGroup {
                    items.append(.senderGroup(group.id))
                    if expanded.contains(group.id) { items += group.rows.map { .row($0.id) } }
                } else {
                    items += group.rows.map { .row($0.id) }
                }
            }
        }
    }
}

@MainActor
struct ThreadTableView: NSViewRepresentable {
    let rows: [ThreadListRow]
    let isActivity: Bool
    var showsHeaders = true
    var bottomInset: CGFloat = 0
    /// Hides the AppKit view itself; SwiftUI opacity alone leaves tooltips and hover tracking active.
    var isHidden = false
    let selections: Set<ThreadSelection>
    let expanded: Set<ActivityFeedGroup.ID>
    let topInset: CGFloat
    let isRefreshEnabled: Bool
    let reduceMotion: Bool
    let textSize: Double
    let setSelections: (Set<ThreadSelection>) -> Void
    let toggleGroup: (ActivityFeedGroup.ID) -> Void
    let refresh: @MainActor () async -> Void
    let open: (Set<ThreadSelection>) -> Void
    let menu: (Set<ThreadSelection>) -> NSMenu
    let swipeActions: (ThreadListRow, NSTableView.RowActionEdge) -> [NSTableViewRowAction]
    let shortcut: (MailListShortcut) -> Void
    let delete: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ThreadTableContainer {
        let container = ThreadTableContainer()
        context.coordinator.attach(container)
        return container
    }

    func updateNSView(_ container: ThreadTableContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        container.baseInset = topInset
        container.bottomInset = bottomInset
        container.isHidden = isHidden
        container.isRefreshEnabled = isRefreshEnabled
        coordinator.setMetrics(ListTextSize.Metrics(textSize: textSize))
        coordinator.apply(rows: rows, isActivity: isActivity, showsHeaders: showsHeaders, expanded: expanded,
                          selections: selections, animate: !reduceMotion)
    }

    static func dismantleNSView(_ container: ThreadTableContainer, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ThreadTableView?
        private(set) var content = ThreadTableContent()
        private weak var container: ThreadTableContainer?
        private var table: ThreadNSTableView? { container?.table }
        private var isApplyingSelection = false
        private var dateTimer: Timer?
        private var metrics = ListTextSize.Metrics(textSize: ListTextSize.standard)
        private var contentInputs: ContentInputs?

        private struct ContentInputs: Equatable {
            let rows: [ThreadListRow]
            let isActivity: Bool
            let showsHeaders: Bool
            let expanded: Set<ActivityFeedGroup.ID>
        }

        /// Rebuilds content only when its inputs change; selection, inset, and resize updates skip the O(n) rebuild.
        func apply(rows: [ThreadListRow], isActivity: Bool, showsHeaders: Bool, expanded: Set<ActivityFeedGroup.ID>,
                   selections: Set<ThreadSelection>, animate: Bool) {
            let inputs = ContentInputs(rows: rows, isActivity: isActivity, showsHeaders: showsHeaders, expanded: expanded)
            guard inputs != contentInputs else { applySelection(selections); return }
            contentInputs = inputs
            apply(ThreadTableContent(rows: rows, isActivity: isActivity, showsHeaders: showsHeaders, expanded: expanded),
                  selections: selections, animate: animate)
        }

        func setMetrics(_ next: ListTextSize.Metrics) {
            guard next != metrics, let table else { return }
            metrics = next
            table.reloadData()
        }

        func attach(_ container: ThreadTableContainer) {
            self.container = container
            let table = container.table
            table.dataSource = self
            table.delegate = self
            table.target = self
            table.action = #selector(clicked)
            table.doubleAction = #selector(doubleClicked)
            table.onOpen = { [weak self] in self?.openSelection() }
            table.onShortcut = { [weak self] in self?.parent?.shortcut($0) }
            table.onDelete = { [weak self] in self?.parent?.delete() }
            table.menuProvider = { [weak self] row in self?.menu(forClickedRow: row) }
            container.onRefresh = { [weak self] in await self?.parent?.refresh() }
            dateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDates() }
            }
        }

        func detach() {
            dateTimer?.invalidate()
            dateTimer = nil
            container?.stopObserving()
        }

        func apply(_ next: ThreadTableContent, selections: Set<ThreadSelection>, animate: Bool) {
            guard let table else { return }
            let previous = content
            content = next
            var reloadedAll = false
            if previous.items != next.items {
                let difference = next.items.difference(from: previous.items)
                if previous.items.isEmpty || difference.count > 60 {
                    table.reloadData()
                    reloadedAll = true
                } else {
                    table.beginUpdates()
                    for change in difference {
                        if case .remove(let offset, _, _) = change {
                            table.removeRows(at: IndexSet(integer: offset), withAnimation: animate ? .effectFade : [])
                        }
                    }
                    for change in difference {
                        if case .insert(let offset, _, _) = change {
                            table.insertRows(at: IndexSet(integer: offset), withAnimation: animate ? .effectFade : [])
                        }
                    }
                    table.endUpdates()
                }
            }
            let changed = reloadedAll ? IndexSet() : IndexSet(next.items.indices.filter { index in
                switch next.items[index] {
                case .row(let id): previous.rows[id] != next.rows[id]
                case .senderGroup(let id): previous.groups[id] != next.groups[id] || previous.expanded.contains(id) != next.expanded.contains(id)
                case .header: false
                }
            })
            if !changed.isEmpty {
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            }
            applySelection(selections)
        }

        private func applySelection(_ selections: Set<ThreadSelection>) {
            guard let table else { return }
            let indexes = IndexSet(content.items.indices.filter { content.items[$0].rowID.map(selections.contains) == true })
            guard indexes != table.selectedRowIndexes else { return }
            isApplyingSelection = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
            if let first = indexes.first, !table.rows(in: table.visibleRect).contains(first) { table.scrollRowToVisible(first) }
        }

        private func ids(at indexes: IndexSet) -> Set<ThreadSelection> {
            Set(indexes.compactMap { content.items.indices.contains($0) ? content.items[$0].rowID : nil })
        }

        private func openSelection() {
            let selected = ids(at: table?.selectedRowIndexes ?? [])
            if !selected.isEmpty { parent?.open(selected) }
        }

        @objc private func clicked() {
            guard let table, content.items.indices.contains(table.clickedRow),
                  case .senderGroup(let id) = content.items[table.clickedRow] else { return }
            parent?.toggleGroup(id)
        }

        @objc private func doubleClicked() {
            guard let table, table.clickedRow >= 0 else { return }
            let clicked = ids(at: IndexSet(integer: table.clickedRow))
            guard !clicked.isEmpty else { return }
            let selected = ids(at: table.selectedRowIndexes)
            parent?.open(selected.isSuperset(of: clicked) ? selected : clicked)
        }

        private func menu(forClickedRow row: Int) -> NSMenu? {
            guard let table, let parent else { return nil }
            let clicked = ids(at: IndexSet(integer: row))
            guard !clicked.isEmpty else { return nil }
            let selected = ids(at: table.selectedRowIndexes)
            return parent.menu(table.selectedRowIndexes.contains(row) ? selected : clicked)
        }

        private func refreshDates() {
            let now = Date.now
            table?.enumerateAvailableRowViews { rowView, _ in
                (rowView.view(atColumn: 0) as? ThreadRowCell)?.updateDate(now: now)
            }
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { content.items.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if case .header = content.items[row] { metrics.headerHeight + 14 } else { metrics.rowHeight }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = tableView.makeView(withIdentifier: ThreadTableRowView.identifier, owner: nil) as? ThreadTableRowView ?? ThreadTableRowView()
            rowView.identifier = ThreadTableRowView.identifier
            let isHeader = { (index: Int) in
                guard self.content.items.indices.contains(index), case .header = self.content.items[index] else { return false }
                return true
            }
            rowView.drawsSeparator = !isHeader(row) && !isHeader(row + 1)
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch content.items[row] {
            case .header(let category):
                let cell = tableView.makeView(withIdentifier: ThreadHeaderCell.identifier, owner: nil) as? ThreadHeaderCell ?? ThreadHeaderCell()
                cell.configure(category.title, metrics: metrics)
                return cell
            case .senderGroup(let id):
                let cell = tableView.makeView(withIdentifier: ThreadSenderGroupCell.identifier, owner: nil) as? ThreadSenderGroupCell ?? ThreadSenderGroupCell()
                if let group = content.groups[id] { cell.configure(group, isExpanded: content.expanded.contains(id), metrics: metrics) }
                return cell
            case .row(let id):
                let cell = tableView.makeView(withIdentifier: ThreadRowCell.identifier, owner: nil) as? ThreadRowCell ?? ThreadRowCell()
                guard let row = content.rows[id] else { return cell }
                cell.configure(row, title: parent?.isActivity == true ? row.activityTitle : nil, metrics: metrics)
                cell.onMenu = { [weak self] button in
                    guard let menu = self?.parent?.menu([id]) else { return }
                    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
                }
                return cell
            }
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            content.items[row].rowID != nil
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let table else { return }
            parent?.setSelections(ids(at: table.selectedRowIndexes))
        }

        func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
            guard let id = content.items[row].rowID, let item = content.rows[id] else { return [] }
            return parent?.swipeActions(item, edge) ?? []
        }
    }
}

// MARK: Container with pull-to-refresh

@MainActor
final class ThreadTableContainer: NSView {
    let scrollView = NSScrollView()
    let table = ThreadNSTableView()
    var onRefresh: (@MainActor () async -> Void)?
    var baseInset: CGFloat = 0 { didSet { if baseInset != oldValue { updateInsets() } } }
    var bottomInset: CGFloat = 0 { didSet { if bottomInset != oldValue { updateInsets() } } }
    var isRefreshEnabled = true
    private let indicator = PullRefreshIndicator()
    private var isTracking = false
    private var isRefreshing = false
    private var refreshTask: Task<Void, Never>?
    private static let threshold: CGFloat = 70
    private static let refreshHeight: CGFloat = 56

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        table.style = .inset
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.floatsGroupRows = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowSizeStyle = .custom
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("thread"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(String(localized: "Conversations"))

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addSubview(indicator)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    required init?(coder: NSCoder) { nil }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
        refreshTask?.cancel()
    }

    private var pullDistance: CGFloat {
        max(0, -scrollView.contentView.bounds.origin.y - baseInset)
    }

    private func updateInsets() {
        let top = baseInset + (isRefreshing ? Self.refreshHeight : 0)
        scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: bottomInset, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: -top + baseInset, left: 0, bottom: 0, right: 0)
        layoutIndicator()
    }

    override func layout() {
        super.layout()
        // The table must never be wider than the viewport, or row reveals scroll it sideways.
        table.sizeLastColumnToFit()
        if scrollView.contentView.bounds.origin.x != 0 {
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: scrollView.contentView.bounds.origin.y))
        }
        layoutIndicator()
    }

    private func layoutIndicator() {
        let gap = isRefreshing ? max(Self.refreshHeight, pullDistance) : pullDistance
        let size: CGFloat = 18
        indicator.frame = NSRect(x: (bounds.width - size) / 2, y: baseInset + max(0, (gap - size) / 2), width: size, height: size)
        indicator.isHidden = gap < 4 && !isRefreshing
    }

    @objc private func liveScrollStarted() {
        isTracking = isRefreshEnabled && !isRefreshing
    }

    @objc private func scrolled() {
        guard isTracking || isRefreshing else { return }
        if isTracking { indicator.progress = min(pullDistance / Self.threshold, 1) }
        layoutIndicator()
    }

    @objc private func liveScrollEnded() {
        let shouldRefresh = isTracking && isRefreshEnabled && pullDistance >= Self.threshold
        isTracking = false
        guard shouldRefresh, let onRefresh else { indicator.progress = 0; layoutIndicator(); return }
        isRefreshing = true
        indicator.isSpinning = true
        updateInsets()
        refreshTask = Task { @MainActor [weak self] in
            await onRefresh()
            guard let self, !Task.isCancelled else { return }
            self.isRefreshing = false
            self.indicator.isSpinning = false
            self.indicator.progress = 0
            let atTop = self.scrollView.contentView.bounds.origin.y < -self.baseInset
            self.updateInsets()
            if atTop {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    self.scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: -self.baseInset))
                }, completionHandler: nil)
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            }
        }
    }
}

@MainActor
final class PullRefreshIndicator: NSView {
    private let spinner = NSProgressIndicator()
    private let ring = CAShapeLayer()

    var progress: CGFloat = 0 { didSet { ring.strokeEnd = progress; alphaValue = isSpinning ? 1 : progress } }
    var isSpinning = false {
        didSet {
            spinner.isHidden = !isSpinning
            ring.isHidden = isSpinning
            if isSpinning { spinner.startAnimation(nil); alphaValue = 1 } else { spinner.stopAnimation(nil) }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.lineCap = .round
        ring.strokeEnd = 0
        layer?.addSublayer(ring)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        addSubview(spinner)
        alphaValue = 0
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        spinner.frame = bounds
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: inset.midX, y: inset.midY), radius: inset.width / 2,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        ring.path = path
        ring.frame = bounds
    }

    override func updateLayer() {
        ring.strokeColor = NSColor.secondaryLabelColor.cgColor
    }
}

// MARK: Table

@MainActor
final class ThreadNSTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onShortcut: ((MailListShortcut) -> Void)?
    var onDelete: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, window.firstResponder === window || window.firstResponder == nil else { return }
            window.makeFirstResponder(self)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return menuProvider?(row)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            onOpen?()
            return
        case 51, 117:
            onDelete?()
            return
        default:
            break
        }
        var modifiers: EventModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        guard let characters = event.charactersIgnoringModifiers,
              let shortcut = MailListShortcut.resolve(characters, modifiers: modifiers, isEditingText: false) else {
            super.keyDown(with: event)
            return
        }
        switch shortcut {
        case .next: moveSelection(by: 1)
        case .previous: moveSelection(by: -1)
        default: onShortcut?(shortcut)
        }
    }

    private func moveSelection(by offset: Int) {
        guard numberOfRows > 0 else { return }
        var index = offset > 0 ? (selectedRowIndexes.last ?? -1) : (selectedRowIndexes.first ?? numberOfRows)
        repeat {
            index += offset
            guard index >= 0, index < numberOfRows else { return }
        } while delegate?.tableView?(self, shouldSelectRow: index) != true
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        scrollRowToVisible(index)
    }
}

@MainActor
final class ThreadTableRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ThreadTableRowView")
    var drawsSeparator = true { didSet { if drawsSeparator != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard drawsSeparator, !isSelected, !isNextRowSelected else { return }
        NSColor.separatorColor.setFill()
        let inset: CGFloat = 16
        let hairline = 1 / (window?.backingScaleFactor ?? 2)
        NSRect(x: inset, y: bounds.maxY - hairline, width: bounds.width - inset * 2, height: hairline).fill()
    }
}

// MARK: Cells

@MainActor
private func label(size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.cell?.truncatesLastVisibleLine = true
    return field
}

@MainActor
final class ThreadAvatarView: NSView {
    private let initials = label(size: 9, weight: .semibold)
    private static let colors = AvatarView.palette.map(NSColor.init)
    private var colorIndex = 0
    private var side: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        initials.alignment = .center
        initials.translatesAutoresizingMaskIntoConstraints = false
        addSubview(initials)
        translatesAutoresizingMaskIntoConstraints = false
        side = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            side, heightAnchor.constraint(equalTo: widthAnchor),
            initials.centerXAnchor.constraint(equalTo: centerXAnchor), initials.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func configure(name: String, address: String, size: CGFloat) {
        if side.constant != size {
            side.constant = size
            let fontSize = (size * 0.45).rounded()
            let base = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            initials.font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: fontSize)
        }
        initials.stringValue = AvatarView.initials(name: name, address: address)
        colorIndex = AvatarView.colorIndex(address: address)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = side.constant / 2
        layer?.backgroundColor = Self.colors[colorIndex].withAlphaComponent(0.22).cgColor
    }
}

@MainActor
final class ThreadTagView: NSView {
    private let text = label(size: 10, weight: .semibold)
    var tint: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var usesNeutralBackground = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ string: String, tint: NSColor, neutral: Bool, size: CGFloat) {
        text.stringValue = string
        text.font = .monospacedDigitSystemFont(ofSize: size, weight: neutral ? .regular : .semibold)
        text.textColor = neutral ? .secondaryLabelColor : tint
        self.tint = tint
        usesNeutralBackground = neutral
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = (usesNeutralBackground ? NSColor.quaternaryLabelColor : tint.withAlphaComponent(0.16)).cgColor
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

@MainActor
final class ThreadRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ThreadRowCell")
    var onMenu: ((NSButton) -> Void)?
    private let dot = NSView()
    private let avatar = ThreadAvatarView()
    private let title = label()
    private let preview = label(color: .secondaryLabelColor)
    private let stateTag = ThreadTagView()
    private let countTag = ThreadTagView()
    private let attachment = NSImageView(image: NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil) ?? NSImage())
    private let flag = NSImageView(image: NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil) ?? NSImage())
    private let sender = label(color: .secondaryLabelColor)
    private let date = label(color: .secondaryLabelColor)
    private let more = NSButton()
    private var rowDate = Date.now
    private var row: ThreadListRow?
    private var stack: NSStackView!
    private var appliedMetrics: ListTextSize.Metrics?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false

        for image in [attachment, flag] {
            image.setContentHuggingPriority(.required, for: .horizontal)
            image.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        attachment.contentTintColor = .secondaryLabelColor
        flag.contentTintColor = .systemOrange

        date.alignment = .right
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        date.setContentHuggingPriority(.required, for: .horizontal)

        more.isBordered = false
        more.contentTintColor = .secondaryLabelColor
        more.target = self
        more.action = #selector(showMenu)
        more.toolTip = String(localized: "More Actions")
        more.setContentHuggingPriority(.required, for: .horizontal)
        more.setContentCompressionResistancePriority(.required, for: .horizontal)

        title.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(300), for: .horizontal)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        preview.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        preview.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sender.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        sender.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let trailing = NSStackView(views: [attachment, flag, sender])
        trailing.spacing = 4
        trailing.setHuggingPriority(.defaultHigh, for: .horizontal)

        stack = NSStackView(views: [dot, avatar, title, preview, stateTag, countTag, spacer, trailing, date, more])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.setCustomSpacing(5, after: dot)
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(6, after: stateTag)
        stack.setCustomSpacing(8, after: date)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6),
            sender.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            date.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func apply(_ metrics: ListTextSize.Metrics) {
        guard appliedMetrics != metrics else { return }
        appliedMetrics = metrics
        sender.font = .systemFont(ofSize: metrics.textSize)
        preview.font = sender.font
        date.font = .monospacedDigitSystemFont(ofSize: metrics.textSize, weight: .regular)
        for image in [attachment, flag] { image.symbolConfiguration = .init(pointSize: metrics.smallSize, weight: .regular) }
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: String(localized: "More Actions"))?
            .withSymbolConfiguration(.init(pointSize: metrics.smallSize + 3, weight: .regular))
        stack.spacing = metrics.spacing
    }

    func configure(_ row: ThreadListRow, title override: String?, metrics: ListTextSize.Metrics) {
        apply(metrics)
        self.row = row
        title.stringValue = override ?? row.subject.displaySubject
        title.font = .systemFont(ofSize: metrics.textSize, weight: row.isUnread ? .semibold : .regular)
        preview.stringValue = override == nil ? row.snippet.collapsingWhitespace : ""
        preview.isHidden = preview.stringValue.isEmpty
        avatar.configure(name: row.sender, address: row.senderAddress, size: metrics.avatarSize)
        if let tag = row.stateTag, let state = row.state {
            stateTag.configure(tag, tint: NSColor(state.tint), neutral: false, size: metrics.smallSize)
            stateTag.isHidden = false
        } else {
            stateTag.isHidden = true
        }
        countTag.isHidden = row.messageCount <= 1
        if row.messageCount > 1 { countTag.configure(row.messageCount.formatted(), tint: .secondaryLabelColor, neutral: true, size: metrics.smallSize) }
        attachment.isHidden = !row.hasAttachments
        flag.isHidden = !row.isStarred
        sender.stringValue = row.sender
        rowDate = row.date
        updateDate(now: .now)
        toolTip = "\(row.sender) — \(row.subject)"
        dot.layer?.backgroundColor = row.isUnread ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
    }

    override func accessibilityLabel() -> String? { row?.accessibilityDescription }

    func updateDate(now: Date) {
        date.stringValue = ThreadDateFormat.compact(for: rowDate, now: now)
    }

    @objc private func showMenu() { onMenu?(more) }
}

@MainActor
final class ThreadHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ThreadHeaderCell")
    private let text = label(size: 11, weight: .semibold, color: .secondaryLabelColor)
    func configure(_ title: String, metrics: ListTextSize.Metrics) {
        text.stringValue = title
        text.font = .systemFont(ofSize: metrics.headerSize, weight: .semibold)
        setAccessibilityLabel(title)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class ThreadSenderGroupCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ThreadSenderGroupCell")
    private let avatar = ThreadAvatarView()
    private let text = label(weight: .semibold)
    private let chevron = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        chevron.contentTintColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let stack = NSStackView(views: [avatar, text, spacer, chevron])
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ group: ActivityFeedGroup, isExpanded: Bool, metrics: ListTextSize.Metrics) {
        guard let first = group.rows.first else { return }
        chevron.symbolConfiguration = .init(pointSize: metrics.smallSize, weight: .semibold)
        text.font = .systemFont(ofSize: metrics.textSize, weight: .semibold)
        avatar.configure(name: first.sender, address: first.senderAddress, size: metrics.avatarSize)
        text.stringValue = String(localized: "\(first.sender) · \(group.unseenCount) new")
        chevron.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        setAccessibilityLabel(text.stringValue)
        setAccessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
    }
}

@MainActor
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
