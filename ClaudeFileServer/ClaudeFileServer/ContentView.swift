import SwiftUI

struct ContentView: View {
    @StateObject private var server = FileServer()
    @State private var paths: [ResolvedPath] = []
    @State private var copied = false
    @State private var pulse = false
    @State private var now = Date()
    @FocusState private var labelFocused: Bool

    // Drives the "recent activity" pulse animation and relative-time
    // refresh without needing per-event timers.
    private let tick = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            List {
                Section("Server") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(server.isRunning ? "Running" : "Stopped")
                            .foregroundColor(server.isRunning ? .green : .secondary)
                    }

                    Toggle("Enable Server", isOn: Binding(
                        get: { server.isRunning },
                        set: { newValue in
                            if newValue { server.start() } else { server.stop() }
                            UIApplication.shared.isIdleTimerDisabled = newValue
                            paths = PathResolver.shared.discoverPaths()
                        }
                    ))
                }

                Section {
                    HStack {
                        Text("Label")
                        Spacer()
                        TextField("e.g. iPhone 16", text: Binding(
                            get: { server.deviceLabel },
                            set: { server.setDeviceLabel($0) }
                        ))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($labelFocused)
                        .submitLabel(.done)
                    }
                } header: {
                    Text("Identity")
                } footer: {
                    Text("Shown as this phone's name in Claude's `iphone_discover` output. Leave empty to use the iOS device name (\(UIDevice.current.name)).")
                }

                Section("Connection") {
                    LabeledRow(label: "IP Address", value: server.ipAddress)
                    LabeledRow(label: "Port", value: "\(server.port)")
                    HStack {
                        Text("Token")
                        Spacer()
                        Text(server.auth.currentToken.prefix(8) + "...")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Button(action: copyConnectionInfo) {
                        HStack {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "Copied!" : "Copy Connection Info")
                        }
                    }

                    Button(role: .destructive) {
                        server.auth.regenerateToken()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Regenerate Token")
                        }
                    }
                }

                Section {
                    if server.pairingActive, let deadline = server.pairingExpiresAt {
                        let secsLeft = max(0, Int(deadline.timeIntervalSince(now)))
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.orange)
                            Text("Accepting pair requests — \(secsLeft)s left")
                                .foregroundColor(.orange)
                        }
                        Button("Cancel Pairing Window") { server.stopPairingWindow() }
                    } else {
                        Button(action: { server.startPairingWindow() }) {
                            HStack {
                                Image(systemName: "link")
                                Text("Accept Pairing Requests (60s)")
                            }
                        }
                    }
                } header: {
                    Text("Pair a New Client")
                } footer: {
                    Text("Opens a 60-second window. Any `iphone_pair()` request from Claude during this time will pop a confirmation here and, if approved, send your token to the client automatically.")
                }

                Section {
                    HStack {
                        Circle()
                            .fill(activityColor)
                            .frame(width: 10, height: 10)
                            .scaleEffect(pulse && isRecentlyActive ? 1.4 : 1.0)
                            .animation(isRecentlyActive
                                ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                                : .default,
                                value: pulse)
                        if let last = server.lastActivity {
                            Text("Last request \(relative(last))")
                        } else {
                            Text("No activity yet").foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(server.recentRequests.count)").foregroundColor(.secondary)
                    }
                    if !server.recentRequests.isEmpty {
                        ForEach(server.recentRequests.prefix(10)) { req in
                            HStack(alignment: .firstTextBaseline) {
                                Text(req.method)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(width: 52, alignment: .leading)
                                    .foregroundColor(methodColor(req.method))
                                Text(req.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                Text(String(req.statusCode))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(statusColor(req.statusCode))
                                Text(relative(req.timestamp))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Activity")
                }

                Section("Accessible Paths") {
                    if paths.isEmpty {
                        Text("Start server to discover paths")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(paths, id: \.path) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(p.label)
                                        .font(.headline)
                                    Spacer()
                                    Image(systemName: p.exists ? "checkmark.circle.fill" : "xmark.circle")
                                        .foregroundColor(p.exists ? .green : .red)
                                        .font(.caption)
                                }
                                Text(p.path)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Quick Setup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WSL curl test:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("curl http://\(server.ipAddress):\(server.port)/api/info -H \"Authorization: Bearer \(server.auth.currentToken)\"")
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("ClaudeFileServer")
            .onAppear {
                paths = PathResolver.shared.discoverPaths()
                pulse = true
            }
            .onReceive(tick) { t in
                now = t
            }
            .alert(pairAlertTitle, isPresented: pairAlertBinding) {
                Button("Deny", role: .cancel) { server.pendingPair?.respond(false) }
                Button("Approve") { server.pendingPair?.respond(true) }
            } message: {
                if let p = server.pendingPair {
                    Text("Requester: \(p.requester)\n\nApproving sends this phone's auth token to the requester so Claude can start using it.")
                } else {
                    Text("")
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Computed

    private var isRecentlyActive: Bool {
        guard let last = server.lastActivity else { return false }
        return now.timeIntervalSince(last) < 5
    }

    private var activityColor: Color {
        guard server.lastActivity != nil else { return .secondary }
        return isRecentlyActive ? .green : Color.green.opacity(0.3)
    }

    private var pairAlertTitle: String {
        "Pair with \(server.pendingPair?.requester ?? "client")?"
    }

    private var pairAlertBinding: Binding<Bool> {
        Binding(
            get: { server.pendingPair != nil },
            set: { newValue in
                if !newValue { server.pendingPair?.respond(false) }
            }
        )
    }

    private func relative(_ date: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 1 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    private func methodColor(_ m: String) -> Color {
        switch m {
        case "GET": return .blue
        case "POST": return .green
        case "PUT": return .orange
        case "DELETE": return .red
        default: return .primary
        }
    }

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 400..<500: return .orange
        case 500...: return .red
        default: return .secondary
        }
    }

    private func copyConnectionInfo() {
        let info = """
        IPHONE_HOST=\(server.ipAddress)
        IPHONE_PORT=\(server.port)
        IPHONE_TOKEN=\(server.auth.currentToken)
        """
        UIPasteboard.general.string = info
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}
