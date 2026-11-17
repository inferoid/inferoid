import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    static let businessEntitlementChanged = Notification.Name("InferoidBusinessEntitlementChanged")
}

struct BusinessEntitlement: Codable {
    var plan: String
    var features: [String]
    var offline_grace_days: Int
    var activated_at: Date
    var grace_until: Date

    var workflowsEnabled: Bool { features.contains("workflows") && Date() <= grace_until }
}

enum BusinessActivation {
    static var endpoint: URL {
        URL(string: (UserDefaults.standard.string(forKey: "businessHubURL") ?? "https://app.inferoid.com") + "/api/activate")!
    }

    static var cached: BusinessEntitlement? {
        guard let data = UserDefaults.standard.data(forKey: "businessEntitlement") else { return nil }
        return try? JSONDecoder().decode(BusinessEntitlement.self, from: data)
    }

    static func activate(token: String) async throws -> BusinessEntitlement {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ActivationError.invalidToken }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["token": token, "machine": ["os": ProcessInfo.processInfo.operatingSystemVersionString, "chip": chipName()]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ActivationError.rejected }
        var result = try JSONDecoder().decode(ServerEntitlement.self, from: data)
        let now = Date()
        let entitlement = BusinessEntitlement(plan: result.plan, features: result.features,
                                               offline_grace_days: result.offline_grace_days,
                                               activated_at: now, grace_until: now.addingTimeInterval(Double(result.offline_grace_days) * 86400))
        UserDefaults.standard.set(try JSONEncoder().encode(entitlement), forKey: "businessEntitlement")
        NotificationCenter.default.post(name: .businessEntitlementChanged, object: nil)
        return entitlement
    }

    private static func chipName() -> String {
        let task = Process(); let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        task.arguments = ["-n", "machdep.cpu.brand_string"]; task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Apple silicon"
    }

    private struct ServerEntitlement: Decodable {
        var plan: String; var features: [String]; var offline_grace_days: Int
    }

    enum ActivationError: LocalizedError {
        case invalidToken, rejected
        var errorDescription: String? {
            switch self { case .invalidToken: return "Enter an activation token."; case .rejected: return "The activation token was rejected." }
        }
    }
}

struct BusinessView: View {
    @State private var token = ""
    @State private var working = false
    @State private var message: String?
    @State private var entitlement = BusinessActivation.cached

    var body: some View {
        Form {
            Section("Business activation") {
                if let entitlement {
                    Label("\(entitlement.plan) · \(entitlement.workflowsEnabled ? "active" : "offline grace expired")", systemImage: entitlement.workflowsEnabled ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    Text("Local inference and workflow data stay on this Mac. Offline grace: 7 days.").foregroundStyle(.secondary)
                } else {
                    Text("Personal Inferoid features work without activation.").foregroundStyle(.secondary)
                }
                SecureField("Activation token", text: $token)
                HStack {
                    Button(working ? "Activating…" : "Activate") { activate() }.disabled(working || token.isEmpty)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if entitlement?.workflowsEnabled == true {
                Section("Self Host") {
                    Text("Node-RED runs locally on 127.0.0.1 with authentication enabled. Inferoid never sends prompts to a hosted model.").foregroundStyle(.secondary)
                    Text("Open Workflows from the sidebar to run or edit the starter flows.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680, maxHeight: .infinity, alignment: .top)
        .padding()
        .navigationTitle("Self Host")
    }

    private func activate() {
        working = true; message = nil
        Task {
            do { entitlement = try await BusinessActivation.activate(token: token); token = ""; message = "Activated." }
            catch { message = error.localizedDescription }
            working = false
        }
    }
}

struct WorkflowItem: Identifiable {
    let id: String; let name: String; let description: String
}

struct WorkflowsView: View {
    private let items = [
        WorkflowItem(id: "meeting-to-local-notes", name: "Meeting → local notes", description: "Save the existing local notes pipeline to a chosen folder."),
        WorkflowItem(id: "notes-to-follow-up-draft", name: "Notes → follow-up draft", description: "Prepare a draft and wait for human approval; never auto-send.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Workflows").font(.title2.bold())
            Text("Business workflows run on this Mac. Inference goes to local Ollama; external email always requires approval.").foregroundStyle(.secondary)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.headline)
                        Text(item.description).foregroundStyle(.secondary)
                        HStack {
                            Text("Installed").font(.caption).foregroundStyle(.green)
                            Button("Run") { }
                            Button("Pause") { }
                            Button("Edit") { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:1880")!) }
                        }
                    }
                    Spacer()
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
        .padding(28)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
        .navigationTitle("Workflows")
    }
}
