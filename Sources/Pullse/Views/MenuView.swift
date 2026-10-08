import PullseCore
import SwiftUI

struct MenuView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    /// Height of the event list's content. A ScrollView with a max height grows to that
    /// max, so the list is sized to its content (up to `maxListHeight`) by measuring it.
    /// Plain `State`, see EventRow.
    private let listHeight = State<CGFloat>(initialValue: 0)
    private let maxListHeight: CGFloat = 440
    /// Height of the whole menu, for `FitWindowToContent`. Plain `State`, see EventRow.
    private let contentHeight = State<CGFloat>(initialValue: 0)
    /// The highlighted row (`ActivityGroups.headingID`/`eventID`), from the keyboard or
    /// the pointer. Plain `State`, see EventRow.
    private let selection = State<String?>(initialValue: nil)
    /// Set when the keyboard moved the selection, so the list scrolls to it; the pointer
    /// moving over a row shouldn't scroll.
    private let scrollToSelection = State(initialValue: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let groups = activityGroups()
            header
            Divider()
            if let problem = model.notificationProblem {
                NotificationsOffBanner(problem: problem) { model.notifier.openSystemSettings() }
                Divider()
            }
            if model.updater.available != nil {
                UpdateBanner(updater: model.updater)
                Divider()
            }
            if groups.isEmpty {
                empty
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups) { group in
                                let heading = ActivityGroups.headingID(group)
                                GroupHeader(group: group, isSelected: selection.wrappedValue == heading) {
                                    hover(heading, $0)
                                } action: {
                                    model.open(group)
                                }
                                .id(heading)
                                if group.events.isEmpty {
                                    Text("No new activity")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(.leading, 36)
                                        .padding(.vertical, 4)
                                }
                                ForEach(group.events) { event in
                                    let row = ActivityGroups.eventID(event)
                                    EventRow(event: event, isSelected: selection.wrappedValue == row) {
                                        hover(row, $0)
                                    } action: {
                                        model.open(event)
                                    }
                                    .id(row)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                        })
                    }
                    .frame(height: min(max(listHeight.wrappedValue, 1), maxListHeight))
                    .onPreferenceChange(ListHeightKey.self) { listHeight.wrappedValue = $0 }
                    .onChange(of: selection.wrappedValue) { _, row in
                        guard scrollToSelection.wrappedValue, let row else { return }
                        scrollToSelection.wrappedValue = false
                        scroller.scrollTo(row)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: MenuHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(MenuHeightKey.self) { contentHeight.wrappedValue = $0 }
        .background(FitWindowToContent(height: contentHeight.wrappedValue))
        .background(MenuKeys(onOpen: { selection.wrappedValue = nil }) { key in
            handle(key, rows: ActivityGroups.rowIDs(activityGroups()))
        })
        // Catches notifications being turned on in System Settings since the last look.
        .onAppear { Task { await model.refreshNotificationStatus() } }
        // Whatever was unread has now been seen; the highlight stays until the popover closes.
        .onDisappear { model.markAllRead() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pull request activity").font(.headline)
                status
            }
            Spacer()
            if model.isPolling {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.poll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now (⌘R)")
            }
        }
        .padding(12)
    }

    @ViewBuilder private var status: some View {
        if let error = model.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let lastPoll = model.lastPoll {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                Text("\(model.openPullRequests) open PRs in \(model.settings.current.org) · checked \(lastPoll.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Checking GitHub…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
            Text("Nothing yet").font(.callout)
            Text("New comments, reviews, CI results and mentions will show up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Button("Mark all read") { model.markAllRead() }
                .disabled(model.unreadCount == 0)
            Button("Clear") { model.clearHistory() }
                .disabled(model.history.isEmpty)
                .help("Remove everything from this list")
            Spacer()
            Text("v\(model.updater.version)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let local = model.updater.localBuildDescription {
                Label("local", systemImage: "hammer")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Built on this Mac (\(local)), not a release")
            }
            Spacer()
            Button("Settings…") { showSettings() }
                .help("Settings (⌘S)")
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(10)
    }

    /// The pointer highlights the row it is over, and clears it on the way out.
    private func hover(_ row: String, _ inside: Bool) {
        if inside {
            selection.wrappedValue = row
        } else if selection.wrappedValue == row {
            selection.wrappedValue = nil
        }
    }

    /// The menu's keys. Returns false for keys it leaves to the window.
    private func handle(_ key: MenuKeys.Key, rows: [String]) -> Bool {
        switch (key.code, key.command) {
        case (125, false), (126, false):  // ↓ ↑
            scrollToSelection.wrappedValue = true
            selection.wrappedValue = ActivityGroups.next(
                after: selection.wrappedValue, in: rows, by: key.code == 125 ? 1 : -1
            )
        case (36, false), (76, false):  // Return, Enter
            open(selection.wrappedValue)
        case (53, false):  // Esc
            MenuToggle.toggle()
        case (15, true):  // ⌘R
            Task { await model.poll() }
        case (1, true):  // ⌘S
            showSettings()
        default:
            return false
        }
        return true
    }

    private func open(_ row: String?) {
        guard let row else { return }
        for group in activityGroups() {
            if ActivityGroups.headingID(group) == row { return model.open(group) }
            if let event = group.events.first(where: { ActivityGroups.eventID($0) == row }) {
                return model.open(event)
            }
        }
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    /// Events grouped by PR, plus every open PR when the setting is on.
    private func activityGroups() -> [ActivityGroups.Group] {
        ActivityGroups.build(
            history: model.history,
            open: model.settings.current.showOpenPullRequests ? model.openPRs : nil
        )
    }
}

/// Sizes the menu window to its content, keeping the top edge under the menu bar.
/// A `.window`-style MenuBarExtra grows with its content but never shrinks, so when the
/// content gets shorter (the list empties, a banner goes away, a group is hidden) it sits
/// at the bottom of a window that is too tall, leaving a gap under the menu bar.
private struct FitWindowToContent: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> FittingView { FittingView() }

    func updateNSView(_ nsView: FittingView, context: Context) {
        nsView.height = height
    }

    final class FittingView: NSView {
        var height: CGFloat = 0 {
            didSet { if height != oldValue { scheduleFit() } }
        }

        // The height can be measured before this view is in the window; fit once it is.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleFit()
        }

        /// After the current layout pass, so the window isn't resized in the middle of one.
        private func scheduleFit() {
            DispatchQueue.main.async { [weak self] in self?.fit() }
        }

        private func fit() {
            guard let window else { return }
            // Never taller than the screen, whatever was measured: the window hangs from the
            // menu bar, so anything taller would run off the bottom.
            let available = window.screen?.visibleFrame.height ?? .greatestFiniteMagnitude
            let height = min(height, available)
            guard height > 0, abs(window.frame.height - height) > 0.5 else { return }
            var frame = window.frame
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            window.setFrame(frame, display: true)
        }
    }
}

/// The menu's keyboard handling. The keys are read with a local event monitor limited to
/// the menu's own window: a MenuBarExtra window gives SwiftUI's focus system nothing
/// focused to send them to.
private struct MenuKeys: NSViewRepresentable {
    struct Key {
        let code: UInt16
        /// ⌘ held, with no ⌥ or ⌃.
        let command: Bool
    }

    /// Each time the menu opens.
    let onOpen: () -> Void
    /// True when the key was handled, and so shouldn't reach the window.
    let onKey: (Key) -> Bool

    func makeNSView(context: Context) -> KeyView { KeyView() }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onOpen = onOpen
        nsView.onKey = onKey
    }

    final class KeyView: NSView {
        var onOpen: () -> Void = {}
        var onKey: (Key) -> Bool = { _ in false }
        private var monitor: Any?
        private var opened: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let opened { NotificationCenter.default.removeObserver(opened) }
            monitor = nil
            opened = nil
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let flags = event.modifierFlags.intersection([.command, .option, .control])
                guard flags.isEmpty || flags == .command else { return event }
                return self.onKey(Key(code: event.keyCode, command: flags == .command)) ? nil : event
            }
            opened = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onOpen() }
            }
        }
    }
}

/// The list's own height, measured inside its ScrollView. A preference keeps flowing up
/// past the views that read it, so this needs a key of its own: if it shared one with
/// `MenuHeightKey`, the menu would size its window to the whole list rather than to the
/// capped ScrollView, and a long list made the window taller than the screen.
private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The whole menu's height, for `FitWindowToContent`.
private struct MenuHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct NotificationsOffBanner: View {
    let problem: String
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications are off").font(.callout.weight(.semibold))
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Turn On…", action: openSettings)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }
}

private struct UpdateBanner: View {
    let updater: Updater

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let update = updater.available {
                    Text("Pullse \(update.version.description) is available").font(.callout.weight(.semibold))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(updater.error != nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if updater.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button("What's new") { updater.openReleasePage() }
                if !updater.canInstallInPlace, AppMover.shouldOffer {
                    Button("Move to Applications") { AppMover.move() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(updater.canInstallInPlace ? "Install" : "Download") {
                        Task { await updater.install() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    private var detail: String {
        switch updater.phase {
        case .downloading: return "Downloading…"
        case .installing: return "Verifying and installing…"
        case .idle, .checking:
            if let error = updater.error { return error }
            if updater.canInstallInPlace { return "You have \(updater.version). Pullse restarts to finish." }
            return AppMover.shouldOffer
                ? "You have \(updater.version). Pullse can update itself once it's in Applications."
                : "You have \(updater.version). Move Pullse to Applications to update in place."
        }
    }
}

private struct GroupHeader: View {
    let group: ActivityGroups.Group
    let isSelected: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(group.label).font(.caption.weight(.semibold).monospaced())
                Text(group.title).font(.caption).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let pr = group.open {
                    StatusChips(pr: pr)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .background(isSelected ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .help("Open the pull request")
    }
}

/// An open PR's CI and review status, after its title in the group header.
private struct StatusChips: View {
    let pr: OpenPullRequest

    var body: some View {
        HStack(spacing: 4) {
            switch pr.ci {
            case .passing: chip("CI", icon: "checkmark", tint: .green)
            case .failing: chip("CI", icon: "xmark", tint: .red)
            case .running: chip("CI", icon: "ellipsis", tint: .secondary)
            case nil: EmptyView()
            }
            if pr.isDraft {
                chip("Draft", icon: nil, tint: .secondary)
            } else {
                switch pr.review {
                case .approved: chip("Approved", icon: "checkmark", tint: .green)
                case .changesRequested: chip("Changes", icon: "exclamationmark", tint: .red)
                case .required: chip("Review", icon: nil, tint: .secondary)
                case nil: EmptyView()
                }
            }
        }
        .fixedSize()
    }

    private func chip(_ text: String, icon: String?, tint: Color) -> some View {
        HStack(spacing: 2) {
            if let icon { Image(systemName: icon).font(.caption2.weight(.bold)) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

// Views keep their state as plain `State` rather than `@State`: in the macOS 27 SDK
// `@State` is a macro whose plugin ships only with Xcode, and this builds with the
// Command Line Tools too.
private struct EventRow: View {
    let event: PREvent
    let isSelected: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(event.headline)
                            .font(.callout.weight(event.isUnread ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(event.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !event.snippet.isEmpty {
                        Text(event.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Circle()
                    .fill(event.isUnread ? Color.accentColor : .clear)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isSelected ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
    }

    private var icon: String {
        switch event.kind {
        case .comment: return "text.bubble"
        case .review:
            return event.isNegative ? "exclamationmark.circle" :
                event.headline.hasSuffix("approved") ? "checkmark.seal" : "eye"
        case .ci: return event.isNegative ? "xmark.octagon" : "checkmark.circle"
        case .mention: return "at"
        case .condition: return conditionRule?.symbol ?? "arrow.triangle.merge"
        case .test: return "bell.badge"
        }
    }

    private var tint: Color {
        if event.isNegative { return .red }
        if event.kind == .review, event.headline.hasSuffix("approved") { return .green }
        if event.kind == .ci { return .green }
        if event.kind == .condition, conditionRule?.tint == .positive { return .green }
        return .accentColor
    }

    private var conditionRule: PRConditionRule? {
        event.condition.flatMap(PRConditions.rule(for:))
    }
}
