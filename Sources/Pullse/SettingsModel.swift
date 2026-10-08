import Foundation
import Observation
import PullseCore
import SwiftUI

/// The settings file, observable. The file is the only store: edits from the Settings
/// window are written to it, and edits made by hand are picked up on the next poll.
@MainActor
@Observable
final class SettingsModel {
    private(set) var current: PullseSettings
    /// Set when the file exists but can't be read. The last good settings stay in use,
    /// and nothing is written until the file is fixed, so a hand edit is never lost.
    private(set) var error: String?

    @ObservationIgnored let file: SettingsFile
    /// The file's location as shown in the Settings window.
    @ObservationIgnored let displayPath: String
    @ObservationIgnored private var loadedModificationDate: Date?

    /// `displayPath` defaults to the file's real path; captures pass the usual one so
    /// a temporary path never shows up in them.
    init(file: SettingsFile = SettingsFile(), displayPath: String? = nil) {
        self.file = file
        self.displayPath = displayPath ?? (file.url.path as NSString).abbreviatingWithTildeInPath
        current = PullseSettings()
        load()
        // Write the defaults out once so there is a file to find and edit.
        if error == nil, !file.exists {
            save()
        }
    }

    func reloadIfChanged() {
        if file.modificationDate != loadedModificationDate {
            load()
        }
    }

    func update(_ change: (inout PullseSettings) -> Void) {
        guard error == nil else { return }
        var next = current
        change(&next)
        guard next != current else { return }
        current = next
        save()
    }

    func binding<Value>(_ keyPath: WritableKeyPath<PullseSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.current[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }

    func binding(_ condition: PRCondition) -> Binding<Bool> {
        Binding(
            get: { self.current.isEnabled(condition) },
            set: { value in self.update { $0.setEnabled(condition, value) } }
        )
    }

    private func load() {
        do {
            current = try file.load()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loadedModificationDate = file.modificationDate
    }

    private func save() {
        do {
            try file.save(current)
            loadedModificationDate = file.modificationDate
        } catch {
            self.error = "Couldn't save \(file.url.path): \(error.localizedDescription)"
        }
    }
}
