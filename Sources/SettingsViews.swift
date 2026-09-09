import SwiftUI
import AppKit

struct ConnectionView: View {
    @ObservedObject var controller: VPNController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection Settings").font(.title2.bold())
            Text("Load your subscription, then choose a node. Your current connection stays active until you apply the changes.")
                .foregroundStyle(.secondary)
            SecureField("HTTPS subscription URL or VLESS link", text: $controller.candidateURL)
                .textFieldStyle(.roundedBorder)
            Button("Load / Refresh Nodes") { controller.fetchSubscription() }
            Picker("Node", selection: $controller.candidateID) {
                Text("Choose a node").tag(Optional<String>.none)
                ForEach(controller.candidateNodes) { node in Text(node.name).tag(Optional(node.id)) }
            }
            if let date = controller.state.lastRefresh { Text("Last applied: \(date.formatted())").font(.caption) }
            Text(controller.nodeMessage).font(.caption).foregroundStyle(.secondary)
            Text(controller.message).font(.caption).foregroundStyle(.secondary)
            if !controller.failureReport.isEmpty {
                Button("Copy Error Report") { controller.copyFailureReport() }
            }
            HStack {
                if controller.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(controller.isInstalled ? "Apply" : "Install and Connect") { controller.applySubscription() }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.candidateID == nil)
            }
        }
        .padding(14).frame(width: 450)
        .disabled(controller.isBusy)
        .interactiveDismissDisabled(controller.isBusy)
    }
}

struct SettingsView: View {
    @ObservedObject var controller: VPNController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    @State private var confirmRemoval = false
    @State private var domain = ""
    @State private var process = ""
    @State private var path = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Settings & Diagnostics").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }
            HStack(spacing: 16) {
                Toggle("Launch at login", isOn: Binding(get: { controller.launchAtLogin }, set: { controller.setLogin($0) }))
                Toggle("Failure notifications", isOn: Binding(get: { controller.notificationsEnabled }, set: { controller.setNotifications($0) }))
            }
            HStack {
                Button("Check for Updates…") { AppUpdater.shared.check() }.disabled(!AppUpdater.shared.available)
                Button("Change Subscription…") { controller.openSetup() }
            }
            if !AppUpdater.shared.available { Text("Automatic updates are not configured in this development build.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Export Routing Rules…") { controller.exportRules() }
                Button("Import Routing Rules…") { controller.importRules() }
            }
            Text("Exports include routing rules and VPN mode, without subscription credentials.").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Check Connection") { controller.checkConnection() }
                Button("Repair Service…") { controller.repair() }
                Button("Copy Report") { controller.copyDiagnostics() }.disabled(controller.diagnostics.isEmpty)
            }
            ScrollView { Text(controller.diagnostics.isEmpty ? "Run Check Connection to create a diagnostic report." : controller.diagnostics)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 92)
            Text(controller.message).font(.caption).foregroundStyle(.secondary)
            if !controller.failureReport.isEmpty {
                Button("Copy Last Error Report") { controller.copyFailureReport() }
            }
            DisclosureGroup("Explain a Routing Rule") {
                Menu("Use a Running Application") {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.executableURL != nil }, id: \.processIdentifier) { application in
                        Button(application.localizedName ?? "Application") {
                            path = application.executableURL?.path ?? ""
                            process = application.executableURL?.lastPathComponent ?? ""
                        }
                    }
                }
                TextField("Domain", text: $domain)
                TextField("Process name", text: $process)
                TextField("Executable path", text: $path)
                Text(RuleInspector.explain(domain: domain, process: process, path: path, rules: controller.state.rules)).font(.caption)
            }
            HStack {
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                Spacer()
                Button("Uninstall…", role: .destructive) { confirmRemoval = true }
            }
        }
        .padding(14).frame(width: 460).disabled(controller.isBusy)
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset All Settings", role: .destructive) { controller.resetSettings() }
        } message: { Text("This disconnects the VPN and removes your saved subscription, node and rules.") }
        .confirmationDialog("Uninstall matveevVpn?", isPresented: $confirmRemoval) {
            Button("Uninstall and Move to Trash", role: .destructive) { controller.runUninstall() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The system service will be removed. Your settings will be kept for reinstalling.")
        }
        .sheet(isPresented: $controller.showConnection) { ConnectionView(controller: controller) }
    }
}
