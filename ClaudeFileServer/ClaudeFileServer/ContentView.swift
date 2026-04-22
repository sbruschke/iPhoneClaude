import SwiftUI

struct ContentView: View {
    @StateObject private var server = FileServer()
    @State private var paths: [ResolvedPath] = []
    @State private var copied = false

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
                            if newValue {
                                UIApplication.shared.isIdleTimerDisabled = true
                            } else {
                                UIApplication.shared.isIdleTimerDisabled = false
                            }
                            paths = PathResolver.shared.discoverPaths()
                        }
                    ))
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
                                    if p.exists {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                            .font(.caption)
                                    } else {
                                        Image(systemName: "xmark.circle")
                                            .foregroundColor(.red)
                                            .font(.caption)
                                    }
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
            }
        }
        .navigationViewStyle(.stack)
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
