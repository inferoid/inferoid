import SwiftUI

/// The standard Inferoid Notes application shell. Other apps can use the same
/// shell after registering their own sidebar tabs.
@MainActor
public struct InferoidNotesApp: App {
    @StateObject private var rec = Recorder.shared

    public init() {}

    public var body: some Scene {
        Window("Inferoid", id: "main") {
            MainView().environmentObject(rec)
        }
        .defaultSize(width: 980, height: 680)
        Settings {
            SettingsView().environmentObject(rec)
        }
        MenuBarExtra {
            MenuContent().environmentObject(rec)
        } label: {
            Image(systemName: rec.isRecording ? "record.circle.fill" : "waveform")
        }
    }
}
