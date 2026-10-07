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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            if model.history.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.prURL) { group in
                            GroupHeader(event: group.events[0])
                            ForEach(group.events) { event in
                                EventRow(event: event) { model.open(event) }
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
            }
            Divider()
            footer
        }
        .frame(width: 380)
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
                .help("Refresh now")
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
            Spacer()
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(10)
    }

    /// Events grouped by PR, groups ordered by their newest event.
    private var groups: [(prURL: String, events: [PREvent])] {
        var order: [String] = []
        var byPR: [String: [PREvent]] = [:]
        for event in model.history {  // already newest first
            if byPR[event.prURL] == nil { order.append(event.prURL) }
            byPR[event.prURL, default: []].append(event)
        }
        return order.map { ($0, byPR[$0]!) }
    }
}

private struct ListHeightKey: PreferenceKey {
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
    let event: PREvent

    var body: some View {
        HStack(spacing: 6) {
            Text(event.prLabel).font(.caption.weight(.semibold).monospaced())
            Text(event.prTitle).font(.caption).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

private struct EventRow: View {
    let event: PREvent
    let action: () -> Void
    // Plain `State` rather than `@State`: in the macOS 27 SDK `@State` is a macro whose
    // plugin ships only with Xcode, and this builds with the Command Line Tools too.
    private let hovering = State(initialValue: false)

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
            .background(hovering.wrappedValue ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering.wrappedValue = $0 }
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
