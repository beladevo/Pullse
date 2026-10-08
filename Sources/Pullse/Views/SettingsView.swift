import AppKit
import PullseCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case github, notifications, updates, app

    var id: Self { self }

    var title: String {
        switch self {
        case .github: return "GitHub"
        case .notifications: return "Notifications"
        case .updates: return "Updates"
        case .app: return "App"
        }
    }

    var icon: String {
        switch self {
        case .github: return "person.crop.circle"
        case .notifications: return "bell.badge"
        case .updates: return "arrow.down.circle"
        case .app: return "gearshape"
        }
    }
}

struct SettingsView: View {
    let model: AppModel

    // Plain `State` rather than `@State`: in the macOS 27 SDK `@State` is a macro whose
    // plugin ships only with Xcode, and this builds with the Command Line Tools too.
    private let tab: State<SettingsTab>
    private let launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    private let loginError = State<String?>(initialValue: nil)
    /// Set while the toggle is being put back after a failed change, so that reset
    /// isn't treated as the user flipping it again.
    private let revertingLoginToggle = State(initialValue: false)
    /// Text fields keep their own text and apply it on Return, on leaving their tab, or
    /// when the window closes: applying every keystroke would poll half-typed org names.
    private let orgText = State(initialValue: "")
    private let mutedText = State(initialValue: "")
    /// Set for a moment after "Send test notification", which then shows it went through.
    private let testSent = State(initialValue: false)

    init(model: AppModel, tab: SettingsTab = .github) {
        self.model = model
        self.tab = State(initialValue: tab)
    }

    private var settings: SettingsModel { model.settings }
    private var updater: Updater { model.updater }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                if let error = settings.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.red.opacity(0.08))
                }
                Form { page }
                    .formStyle(.grouped)
            }
            .frame(width: 460)
        }
        .frame(minHeight: 300)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            Task { await model.refreshNotificationStatus() }
            settings.reloadIfChanged()
            orgText.wrappedValue = settings.current.org
            mutedText.wrappedValue = settings.current.mutedRepos.joined(separator: ", ")
        }
        .onChange(of: tab.wrappedValue) { applyText() }
        .onDisappear(perform: applyText)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { item in
                SidebarRow(tab: item, selected: tab.wrappedValue == item,
                           badge: item == .notifications && model.notificationProblem != nil
                               || item == .updates && updater.available != nil) {
                    tab.wrappedValue = item
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 180)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var page: some View {
        switch tab.wrappedValue {
        case .github: githubPage
        case .notifications: notificationsPage
        case .updates: updatesPage
        case .app: appPage
        }
    }

    // MARK: - GitHub

    @ViewBuilder private var githubPage: some View {
        Section {
            TextField("Organization", text: orgText.projectedValue, prompt: Text("your-org"))
                .onSubmit(applyText)
            Picker("Check every", selection: settings.binding(\.pollSeconds)) {
                Text("30 seconds").tag(30)
                Text("1 minute").tag(60)
                Text("2 minutes").tag(120)
                Text("5 minutes").tag(300)
                Text("15 minutes").tag(900)
            }
            .onChange(of: settings.current.pollSeconds) { model.restartLoop() }
        } header: {
            Text("GitHub")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let error = model.lastError {
                    Footnote(error, isError: true)
                } else if let lastPoll = model.lastPoll {
                    // Re-rendered on a timer, or "checked 24 seconds ago" never ages.
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        Footnote("\(model.openPullRequests) open PRs in \(settings.current.org) · checked \(lastPoll.formatted(.relative(presentation: .named)))")
                    }
                }
                Footnote("Pullse signs in with your GitHub CLI login (gh auth login) and only reads from GitHub.")
            }
        }
    }

    // MARK: - Notifications

    @ViewBuilder private var notificationsPage: some View {
        if let problem = model.notificationProblem {
            Section {
                HStack {
                    Label(problem, systemImage: "bell.slash.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Notification Settings") { model.notifier.openSystemSettings() }
                        .controlSize(.small)
                }
            }
        }

        Section {
            Toggle("Show open pull requests in the menu", isOn: settings.binding(\.showOpenPullRequests))
        } header: {
            Text("Menu")
        } footer: {
            Footnote("Lists every open pull request you authored, with its CI and review status, even when there's no new activity on it.")
        }

        Section("Notify me about") {
            Toggle("Comments on my pull requests", isOn: settings.binding(\.notifyComments))
            Toggle("Reviews on my pull requests", isOn: settings.binding(\.notifyReviews))
            Toggle("CI results on my pull requests", isOn: settings.binding(\.notifyCI))
            Picker("CI results", selection: settings.binding(\.ciResults)) {
                Text("Failures only").tag(DetectorSettings.CIMode.failuresOnly)
                Text("Failures, passes and cancellations").tag(DetectorSettings.CIMode.all)
            }
            .disabled(!settings.current.notifyCI)
            Toggle("@mentions in other people's pull requests", isOn: settings.binding(\.notifyMentions))
            ForEach(PRCondition.allCases, id: \.self) { condition in
                if let rule = PRConditions.rule(for: condition) {
                    Toggle(rule.title, isOn: settings.binding(condition))
                }
            }
        }

        Section {
            Toggle("Include bots", isOn: settings.binding(\.includeBots))
            TextField("Muted repositories", text: mutedText.projectedValue,
                      prompt: Text("sandbox, your-org/legacy-app"))
                .onSubmit(applyText)
        } header: {
            Text("Filters")
        } footer: {
            Footnote("Bots are accounts like github-actions or dependabot. Muted repositories are comma separated, as a name or owner/name.")
        }

        Section {
            Button { Task { await sendTest() } } label: {
                // Both labels are always laid out, so the button keeps one width when it swaps.
                ZStack {
                    Text("Send test notification").opacity(testSent.wrappedValue ? 0 : 1)
                    Label(model.notificationProblem == nil ? "Sent" : "Added to the menu only",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(model.notificationProblem == nil ? .green : .orange)
                        .opacity(testSent.wrappedValue ? 1 : 0)
                }
            }
            .disabled(testSent.wrappedValue)
        } footer: {
            Footnote("Posts a sample notification and adds a test item to the activity list.")
        }
    }

    private func sendTest() async {
        await model.sendTest()
        testSent.wrappedValue = true
        try? await Task.sleep(for: .seconds(2))
        testSent.wrappedValue = false
    }

    // MARK: - Updates

    private var updateStatus: String {
        switch updater.phase {
        case .downloading: return "Downloading…"
        case .installing: return "Verifying and installing…"
        case .idle, .checking: break
        }
        if let error = updater.error { return error }
        if let checked = updater.lastChecked {
            // An update found gets its own row below, with the Install button.
            let when = "checked \(checked.formatted(.relative(presentation: .named)))"
            return updater.available != nil ? "Update found · \(when)" : "Up to date · \(when)"
        }
        return updater.repository == nil ? "This build has no update source" : ""
    }

    @ViewBuilder private var updatesPage: some View {
        Section {
            LabeledContent("Version", value: "\(updater.version) (build \(updater.build))"
                + (updater.localBuildDescription.map { " · \($0)" } ?? ""))
            HStack {
                Button("Check now") { Task { await updater.check() } }
                    .disabled(updater.isBusy || updater.repository == nil)
                if updater.phase == .checking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(updateStatus)
                        .font(.caption)
                        .foregroundStyle(updater.error != nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .multilineTextAlignment(.trailing)
                }
            }
            // Install right here, without going back to the menu's banner.
            if let update = updater.available {
                HStack {
                    Label("Pullse \(update.version.description) is available", systemImage: "arrow.up.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    if updater.phase == .downloading || updater.phase == .installing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("What's new") { updater.openReleasePage() }
                            .buttonStyle(.link)
                        if !updater.canInstallInPlace, AppMover.shouldOffer {
                            Button("Move to Applications") { AppMover.move() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(updater.canInstallInPlace ? "Install" : "Download") {
                                Task { await updater.install() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(updater.isBusy)
                        }
                    }
                }
            }
        } header: {
            Text("Pullse")
        } footer: {
            if updater.available != nil, updater.canInstallInPlace {
                Footnote("Install downloads the update, checks it, and restarts Pullse.")
            }
        }

        Section {
            Toggle("Check for updates automatically", isOn: settings.binding(\.checkForUpdates))
            Toggle("Install updates automatically", isOn: settings.binding(\.autoUpdate))
            Toggle("Include prereleases", isOn: settings.binding(\.includePrereleases))
            Toggle("Notify me after Pullse updates", isOn: settings.binding(\.notifyAfterUpdate))
        } header: {
            Text("Automatic updates")
        } footer: {
            if updater.canInstallInPlace, settings.current.autoUpdate {
                Footnote("Automatic installs wait until the menu and this window are closed, then restart Pullse.")
            } else if AppMover.shouldOffer {
                HStack(alignment: .firstTextBaseline) {
                    Footnote("Pullse is running from a download location, where it can't update itself. Move it to Applications once and updates install in place.")
                    Button("Move to Applications…") { AppMover.move() }
                        .controlSize(.small)
                }
            } else if !updater.canInstallInPlace {
                Footnote("Updates install in place only when Pullse is in Applications or ~/Applications. From anywhere else they open the download page.")
            }
        }
    }

    // MARK: - App

    @ViewBuilder private var appPage: some View {
        Section {
            LabeledContent("Open Pullse menu") {
                ShortcutRecorder(
                    shortcut: settings.current.openMenuShortcut, globalShortcut: model.shortcut
                ) { hotKey in settings.update { $0.openMenuShortcut = hotKey } }
            }
        } header: {
            Text("Keyboard")
        } footer: {
            if let error = model.shortcut.registrationError {
                Footnote(error, isError: true)
            } else {
                Footnote("Opens and closes the menu from any app. In the menu, ↑ ↓ move, Return opens, ⌘R refreshes, ⌘S opens Settings and Esc closes.")
            }
        }

        Section("Startup") {
            Toggle("Launch at login", isOn: launchAtLogin.projectedValue)
                .onChange(of: launchAtLogin.wrappedValue) { _, enabled in setLaunchAtLogin(enabled) }
            if let loginError = loginError.wrappedValue {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }

        Section {
            LabeledContent("Location") {
                Text(settings.displayPath).textSelection(.enabled)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([settings.file.url])
            }
        } header: {
            Text("Settings file")
        } footer: {
            Footnote("Everything on these tabs is saved here as JSON, and edits to the file are picked up on the next check.")
        }
    }

    // MARK: - Actions

    private func applyText() {
        let org = orgText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if org != settings.current.org {
            settings.update { $0.org = org }
            model.restartLoop()
        }
        let repos = mutedText.wrappedValue
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
        if repos != settings.current.mutedRepos {
            settings.update { $0.mutedRepos = repos }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if revertingLoginToggle.wrappedValue {
            revertingLoginToggle.wrappedValue = false
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError.wrappedValue = nil
        } catch {
            loginError.wrappedValue = error.localizedDescription
            let actual = SMAppService.mainApp.status == .enabled
            if actual != launchAtLogin.wrappedValue {
                revertingLoginToggle.wrappedValue = true
                launchAtLogin.wrappedValue = actual
            }
        }
    }
}

/// A section footer note: small, secondary, left-aligned across the section's width.
private struct Footnote: View {
    let text: String
    var isError = false

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarRow: View {
    let tab: SettingsTab
    let selected: Bool
    /// A dot for a tab that needs a look: notifications off, or an update waiting.
    let badge: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .frame(width: 18)
                Text(tab.title)
                Spacer(minLength: 0)
                if badge {
                    Circle()
                        .fill(selected ? Color.white : Color.orange)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Records a global shortcut: click, then press the keys. Esc cancels.
private struct ShortcutRecorder: View {
    let shortcut: HotKey?
    let globalShortcut: GlobalShortcut
    let onChange: (HotKey?) -> Void
    // Plain `State`, see EventRow in MenuView.
    private let recording = State(initialValue: false)
    private let hint = State<String?>(initialValue: nil)
    private let monitor = State(initialValue: MonitorBox())

    /// Holds the key monitor while recording; a class, so stopping it needs no view update.
    final class MonitorBox {
        var token: Any?
    }

    var body: some View {
        HStack(spacing: 6) {
            if let hint = hint.wrappedValue {
                Text(hint).font(.caption).foregroundStyle(.red)
            }
            Button(recording.wrappedValue ? "Press a shortcut…" : shortcut?.display ?? "Record Shortcut") {
                recording.wrappedValue ? stop() : start()
            }
            if shortcut != nil, !recording.wrappedValue {
                Button {
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove the shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        hint.wrappedValue = nil
        recording.wrappedValue = true
        globalShortcut.suspend()
        monitor.wrappedValue.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            record(event)
            return nil
        }
    }

    private func stop() {
        if let token = monitor.wrappedValue.token {
            NSEvent.removeMonitor(token)
            monitor.wrappedValue.token = nil
        }
        if recording.wrappedValue {
            recording.wrappedValue = false
            globalShortcut.resume()
        }
    }

    private func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = Set<HotKey.Modifier>()
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if event.keyCode == 53, modifiers.isEmpty {  // Esc
            stop()
            return
        }
        let hotKey = HotKey(keyCode: Int(event.keyCode), key: Self.keyName(event), modifiers: modifiers)
        guard hotKey.isValid else {
            hint.wrappedValue = "Add ⌘, ⌥ or ⌃"
            return
        }
        hint.wrappedValue = nil
        stop()
        onChange(hotKey)
    }

    /// The key's name for display: the special keys by name or symbol, else its character.
    private static func keyName(_ event: NSEvent) -> String {
        let special: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 49: "Space", 36: "↩", 48: "⇥",
            51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        if let name = special[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "").uppercased()
    }
}
