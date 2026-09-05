import SwiftUI
import AppKit

@main
struct NotablesApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Notables", id: "main") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh from PC") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                OpenCanvasButton()
            }
        }

        // Always one click away from the menu bar, even with the window closed.
        MenuBarExtra("Notables", systemImage: menuBarIcon) {
            MenuBarContent(model: model)
        }
        .menuBarExtraStyle(.window)

        // Its own window, not a sheet: an SSO redirect chain through Microsoft
        // deserves a real browser-sized surface.
        Window("Connect Canvas", id: "canvas") {
            CanvasConnectView(client: NotesClient())
        }
        .defaultSize(width: 860, height: 680)

        Settings { SettingsView() }
    }

    private var menuBarIcon: String {
        model.recorder.state == .recording ? "record.circle.fill" : "waveform"
    }
}

/// A command-menu button needs a *view* environment to reach `openWindow`; the
/// `App` struct's own environment does not carry it.
struct OpenCanvasButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Connect Canvas…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "canvas")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.recorder.state == .recording {
                HStack(spacing: 8) {
                    Circle().fill(Theme.recordRed).frame(width: 8, height: 8)
                    Text("Recording  \(formatDuration(model.recorder.elapsed))")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                }
                Button("Stop & File Note") { Task { await model.stopRecordingAndSend() } }
                    .buttonStyle(.borderedProminent).tint(Theme.recordRed)
            } else {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                    Task { await model.startRecording() }
                } label: {
                    Label("Record a Class", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent).tint(Theme.recordRed)
            }

            Divider()

            if let latest = model.notes.first {
                Text("Latest").font(.caption).foregroundStyle(.secondary)
                Text(latest.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(latest.course).font(.caption).foregroundStyle(Theme.courseColor(latest.course))
            }

            if !model.openTodos.isEmpty {
                Divider()
                Text("Due soon").font(.caption).foregroundStyle(.secondary)
                ForEach(model.openTodos.prefix(3)) { t in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "square").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(t.text).font(.system(size: 12)).lineLimit(2)
                    }
                }
            }

            Divider()
            HStack {
                Circle().fill(model.connection.isOnline ? Theme.accent : Theme.soon).frame(width: 6, height: 6)
                Text(model.connection.isOnline ? "Synced" : "PC offline")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                .buttonStyle(.link)
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.link)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { model.onAppear() }
    }
}

struct SettingsView: View {
    @AppStorage("serverHost") private var host = NotesClient.Config.defaultHost
    @AppStorage("serverPort") private var port = NotesClient.Config.defaultPort

    var body: some View {
        Form {
            Section("Note server (Windows PC)") {
                TextField("Host", text: $host)
                TextField("Port", value: $port, format: .number.grouping(.never))
                LabeledContent("Token") {
                    Text(NotesClient.Config.readToken().isEmpty
                         ? "missing — see ~/.notables/token"
                         : "loaded from ~/.notables/token")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Recordings") {
                LabeledContent("Stored on this Mac") {
                    Text(Recorder.recordingsDirectory.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Audio never leaves this Mac — only the transcript is sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
