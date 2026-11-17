import Foundation
import SwiftUI

struct InferoidNotesApp: App {
    @StateObject private var rec = Recorder.shared
    var body: some Scene {
        Window("Inferoid Notes", id: "main") {
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

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1, args[1].hasPrefix("--") {
            Task {
                do { try await Headless.run(Array(args.dropFirst())) } catch {
                    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
                exit(0)
            }
            dispatchMain()
        }
        InferoidNotesApp.main()
    }
}
