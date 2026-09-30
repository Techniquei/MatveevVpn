import SwiftUI
import AppKit

struct InteractiveHover: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(isEnabled && hovering ? AppPalette.cyan.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isEnabled && hovering ? AppPalette.cyan.opacity(0.45) : .clear, lineWidth: 1)
                .allowsHitTesting(false))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

// Keep native button sizing, focus, keyboard activation and roles underneath the hover.
struct HoverButtonStyle: PrimitiveButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if prominent { Button(configuration).buttonStyle(.borderedProminent) }
            else { Button(configuration).buttonStyle(.bordered) }
        }
        .modifier(InteractiveHover())
    }
}

struct AppDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.cyan)
                        .frame(width: 12)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(InteractiveHover())
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content.padding([.horizontal, .bottom], 14)
            }
        }
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct AppWindowHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(AppPalette.cyan)
                .frame(width: 40, height: 40)
                .background(AppPalette.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 21, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct ConnectionView: View {
    @ObservedObject var controller: VPNController
    @Environment(\.dismiss) private var dismiss
    @FocusState private var subscriptionFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppWindowHeader(
                title: needsComponentInstallation ? "Prepare your Mac" : "Subscription",
                subtitle: controller.isInitialSetup ? (needsComponentInstallation ? "Step 1 of 2" : "Step 2 of 2") : "Connection settings",
                icon: needsComponentInstallation ? "shippingbox" : "link"
            )
            if needsComponentInstallation {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Install the VPN component").font(.headline)
                    Text("Confirm your administrator password in the macOS prompt. Then add your subscription to connect.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if controller.isBusy {
                        ProgressView().progressViewStyle(.linear)
                        Text(controller.message).font(.caption).foregroundStyle(.secondary)
                    } else if !controller.failureReport.isEmpty {
                        Text(controller.message).font(.callout).foregroundStyle(.secondary)
                        Button("Export Logs…") { controller.exportLog() }
                    }
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            } else {
                subscriptionForm
            }
            Divider()
            if controller.isBusy && !needsComponentInstallation {
                ProgressView().progressViewStyle(.linear)
                Text(controller.message).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(primaryActionTitle) {
                    if needsComponentInstallation { controller.installInitialComponent() }
                    else { controller.applySubscription() }
                }
                .buttonStyle(HoverButtonStyle(prominent: true))
                .tint(AppPalette.blue)
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isBusy || (!needsComponentInstallation && !controller.canApplySubscription))
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 480, height: needsComponentInstallation ? 320 : (controller.isInitialSetup ? 420 : 540))
        .background(AppPalette.background)
        .preferredColorScheme(.dark)
        .buttonStyle(HoverButtonStyle())
        .disabled(controller.isBusy)
        .background(WindowCloseControl(isBusy: controller.isBusy))
        .onAppear {
            controller.showConnection = true
            subscriptionFocused = controller.isInstalled && controller.candidateURL.isEmpty
            if needsComponentInstallation { controller.installInitialComponent() }
            else if !controller.isInitialSetup { controller.testCandidateNodes() }
        }
        .onChange(of: controller.isInstalled) { installed in
            if installed && controller.isInitialSetup { subscriptionFocused = true }
        }
        .onChange(of: controller.candidateID) {
            if !controller.isBusy { controller.probeCandidateNode($0) }
        }
        .onChange(of: controller.showConnection) { presented in
            if !presented { dismiss() }
        }
        .onDisappear { controller.showConnection = false }
    }

    private var needsComponentInstallation: Bool { controller.isInitialSetup && !controller.isInstalled }

    private var primaryActionTitle: String {
        if needsComponentInstallation {
            if controller.isBusy { return "Installing…" }
            return controller.failureReport.isEmpty ? "Install component" : "Retry installation"
        }
        return controller.isInstalled ? (controller.isInitialSetup ? "Connect" : "Save") : "Install and Connect"
    }

    private var subscriptionForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Subscription link").font(.callout.weight(.semibold))
                    SecureField("Paste an HTTPS or VLESS link", text: $controller.candidateURL)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(subscriptionFocused ? AppPalette.blue.opacity(0.8) : .white.opacity(0.08), lineWidth: 1))
                        .accessibilityLabel("Subscription URL or VLESS link")
                        .focused($subscriptionFocused)
                        .modifier(InteractiveHover())
                    Text(controller.isInitialSetup
                         ? "The first server is selected automatically."
                         : "Your connection stays active until you save.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))

                if !controller.isInitialSetup {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Server").font(.callout.weight(.semibold))
                            Spacer()
                            Button { controller.fetchSubscription() } label: { Image(systemName: "arrow.clockwise") }
                                .controlSize(.small)
                                .help("Reload servers from your subscription")
                                .accessibilityLabel("Reload servers")
                        }
                        Picker("Server", selection: $controller.candidateID) {
                            Text("Choose a server").tag(Optional<String>.none)
                            ForEach(controller.candidateNodes) { node in
                                Text(node.name + (controller.probeResults[node.id].map { " — " + $0.displayText } ?? ""))
                                    .tag(Optional(node.id))
                            }
                        }
                        .labelsHidden()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .simultaneousGesture(TapGesture().onEnded { controller.testCandidateNodes() })
                        .modifier(InteractiveHover())
                        if controller.candidateID == nil && !controller.candidateNodes.isEmpty {
                            Text("Choose a server before saving.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Happ subscriptions")
                            Spacer()
                            Toggle("Happ subscriptions", isOn: Binding(
                                get: { controller.happCompatibilityEnabled },
                                set: { controller.setHappCompatibility($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .modifier(InteractiveHover())
                        }
                        Text("Use for providers that require Happ. Only servers are imported.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Compatibility").font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disclosureGroupStyle(AppDisclosureStyle())
                if let date = controller.state.lastRefresh {
                    Text("Last saved: \(date.formatted())").font(.caption).foregroundStyle(.secondary)
                }
                if !controller.isBusy && !controller.failureReport.isEmpty {
                    Text(controller.message).font(.caption).foregroundStyle(.secondary)
                }
                if !controller.failureReport.isEmpty {
                    Button("Export Logs…") { controller.exportLog() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
}

struct SettingsView: View {
    @ObservedObject private var updater = AppUpdater.shared
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var controller: VPNController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    @State private var confirmRemoval = false
    @State private var domain = ""
    @State private var process = ""
    @State private var path = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppWindowHeader(title: "Settings", subtitle: "Preferences and diagnostics", icon: "gearshape")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("General").font(.headline)
                        Toggle("Launch at login", isOn: Binding(get: { controller.launchAtLogin }, set: { controller.setLogin($0) }))
                            .modifier(InteractiveHover())
                        Toggle("Failure notifications", isOn: Binding(get: { controller.notificationsEnabled }, set: { controller.setNotifications($0) }))
                            .modifier(InteractiveHover())
                        Toggle("Automatic server recovery", isOn: Binding(get: { controller.autoFailoverEnabled }, set: { controller.setAutoFailover($0) }))
                            .modifier(InteractiveHover())
                        Text("Reconnects or switches servers when the connection fails.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Subscription and rules").font(.headline)
                        HStack {
                            Button("Change subscription…") {
                                controller.openSetup()
                                openWindow(id: "connection")
                            }
                            Button("Check for updates…") { updater.check() }
                                .disabled(!updater.available)
                        }
                        Toggle("Receive beta updates", isOn: Binding(
                            get: { updater.betaUpdatesEnabled },
                            set: { updater.setBetaUpdates($0) }
                        ))
                        .toggleStyle(.checkbox)
                        .modifier(InteractiveHover())
                        Text("Includes test releases. Turning this off keeps your installed version until a newer stable release.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Export rules…") { controller.exportRules() }
                            Button("Import rules…") { controller.importRules() }
                        }
                        Text("Rule exports do not include your subscription.").font(.caption).foregroundStyle(.secondary)
                        if !updater.available {
                            Text("App updates are unavailable in this development build.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Diagnostics").font(.headline)
                        HStack {
                            Button("Check connection") { controller.checkConnection() }
                            Button("Repair service…") { controller.repair() }
                            Button("Export logs…") { controller.exportLog() }
                                .help("Exports the complete unfiltered application log (maximum 3 MB).")
                        }
                        if !controller.diagnostics.isEmpty {
                            Text(controller.diagnostics)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if !controller.message.isEmpty {
                            Text(controller.message).font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Explain a routing rule") {
                            VStack(alignment: .leading, spacing: 10) {
                                Menu("Use a running application") {
                                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.executableURL != nil }, id: \.processIdentifier) { application in
                                        Button(application.localizedName ?? "Application") {
                                            path = application.executableURL?.path ?? ""
                                            process = application.executableURL?.lastPathComponent ?? ""
                                        }
                                    }
                                }
                                .modifier(InteractiveHover())
                                TextField("Domain", text: $domain)
                                    .modifier(InteractiveHover())
                                TextField("Process name", text: $process)
                                    .modifier(InteractiveHover())
                                TextField("Executable path", text: $path)
                                    .modifier(InteractiveHover())
                                Text(RuleInspector.explain(domain: domain, process: process, path: path, rules: controller.state.rules)).font(.caption)
                            }
                            .textFieldStyle(.roundedBorder)
                        }
                        .disclosureGroupStyle(AppDisclosureStyle())
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))

                    HStack {
                        Button("Reset settings…", role: .destructive) { confirmReset = true }
                        Spacer()
                        Button("Uninstall…", role: .destructive) { confirmRemoval = true }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .controlSize(.large)
        .tint(AppPalette.blue)
        .padding(22).frame(width: 540, height: 680)
        .background(AppPalette.background)
        .preferredColorScheme(.dark)
        .buttonStyle(HoverButtonStyle())
        .disabled(controller.isBusy)
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset All Settings", role: .destructive) { controller.resetSettings() }
        } message: { Text("This disconnects the VPN and removes your saved subscription, node and rules.") }
        .confirmationDialog("Uninstall matveevVpn?", isPresented: $confirmRemoval) {
            Button("Uninstall and Move to Trash", role: .destructive) { controller.runUninstall() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The system service will be removed. Your settings will be kept for reinstalling.")
        }
        .background(WindowCloseControl(isBusy: controller.isBusy))
        .onChange(of: controller.showConnection) { presented in
            if presented { openWindow(id: "connection") }
        }
    }
}
