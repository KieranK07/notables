import SwiftUI
import WebKit
import AppKit

/// Canvas sign-in.
///
/// Franciscan's Canvas has student access tokens disabled and authenticates through
/// Microsoft SAML SSO, so there is no token or password flow available to us. What
/// there IS: Canvas's own web UI drives /api/v1 with the session cookie, and Canvas
/// honours that cookie for GETs from anywhere.
///
/// So: the user signs in here, by hand, in a real WKWebView — Microsoft's page, MFA
/// and all. This app never sees the password. We harvest only the resulting Canvas
/// cookie and hand it to the PC, which uses it for read-only API calls.
///
/// The cookie expires. That is not a bug to hide: a dead session must surface as
/// "reconnect Canvas", never as "no new materials".
@MainActor
final class CanvasConnect: ObservableObject {

    enum Phase: Equatable {
        case signingIn
        case verifying
        case connected(String)
        case failed(String)

        var isTerminal: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published var phase: Phase = .signingIn
    @Published var host: String = CanvasConnect.defaultHost
    @Published var pageTitle: String = ""

    static let defaultHost = "franciscan.instructure.com"

    /// Cookie names that mean "this is a live Canvas session". Canvas has renamed
    /// this over the years, so accept any of them rather than pinning one.
    private static let sessionCookieNames: Set<String> = [
        "canvas_session", "_normandy_session", "_legacy_normandy_session",
        "_csrf_token",
    ]

    /// Deliberately the dashboard, not /login. If the persisted session is still
    /// good, Canvas serves it straight away and we harvest without a single
    /// keystroke; if it isn't, Canvas redirects to Microsoft SSO by itself.
    var startURL: URL { URL(string: "https://\(host)/")! }

    /// True once a previous sign-in's cookies were found in the persistent store,
    /// which is the normal case after the first time.
    @Published var restoredSession = false

    private let client: NotesClient
    init(client: NotesClient) { self.client = client }

    /// Called after every completed navigation. Returns true once we're done.
    func evaluate(_ webView: WKWebView) async {
        guard case .signingIn = phase else { return }
        // Only harvest once we're actually back on Canvas — mid-SSO we're on
        // login.microsoftonline.com and there is nothing of ours to take.
        guard webView.url?.host?.hasSuffix(host) == true else { return }

        let all = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let mine = all.filter { cookieMatchesHost($0) }
        restoredSession = !mine.isEmpty
        let names = Set(mine.map(\.name))
        guard !names.isDisjoint(with: Self.sessionCookieNames) else { return }

        // A cookie jar is not proof of a working session — Canvas hands out a
        // pre-auth session cookie on the login page too. Let the server be the
        // judge: it calls /api/v1/users/self and refuses anything that fails.
        phase = .verifying
        let header = mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        do {
            let user = try await client.connectCanvas(host: host, cookie: header)
            phase = .connected(user.name ?? user.login ?? "connected")
        } catch {
            // Not fatal: we may simply have grabbed the jar too early, before SSO
            // finished. Go back to watching rather than tearing the flow down.
            phase = .signingIn
            lastRejection = error.localizedDescription
        }
    }

    @Published var lastRejection: String?

    /// macOS does not offer iCloud Keychain autofill inside a third-party app's web
    /// view — that is a Safari privilege. The next best thing is one click to the
    /// Passwords app, then paste.
    func openPasswords() {
        let url = URL(fileURLWithPath: "/System/Applications/Passwords.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            // Older macOS keeps them in System Settings.
            if let u = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension") {
                NSWorkspace.shared.open(u)
            }
        }
    }

    /// Wipe the stored Canvas cookies in this app so the next attempt starts clean.
    func startFresh() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let mine = records.filter { $0.displayName.contains("instructure") ||
                                    $0.displayName.contains("microsoft") ||
                                    $0.displayName.contains("franciscan") }
        await store.removeData(ofTypes: types, for: mine)
        restoredSession = false
        lastRejection = nil
        phase = .signingIn
    }

    private func cookieMatchesHost(_ c: HTTPCookie) -> Bool {
        let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
        return host == d || host.hasSuffix("." + d)
    }
}

// ------------------------------------------------------------------ web view
struct CanvasWebView: NSViewRepresentable {
    @ObservedObject var connect: CanvasConnect

    func makeCoordinator() -> Coordinator { Coordinator(connect: connect) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // persistent: reconnect stays cheap
        // Microsoft Entra refuses to authenticate in some embedded browsers. Appending
        // the Safari product token makes this present as Safari while leaving WebKit's
        // real version in the string — a wholly fabricated UA breaks sites that sniff
        // the WebKit build, and password autofill heuristics read this too.
        cfg.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: connect.startURL))
        // Focus it, so typing goes to the page and the system's fill affordances
        // have a first responder to attach to.
        DispatchQueue.main.async { web.window?.makeFirstResponder(web) }
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let connect: CanvasConnect
        init(connect: CanvasConnect) { self.connect = connect }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            connect.pageTitle = webView.title ?? ""
            // Focus the page so typing lands in it and the system's password autofill
            // has a first responder to attach to — but never steal focus back from a
            // field already being used, or a late-firing navigation yanks the caret
            // out of the password box mid-autofill.
            if let window = webView.window {
                let focused = (window.firstResponder as? NSView)?.isDescendant(of: webView) ?? false
                if !focused { window.makeFirstResponder(webView) }
            }
            Task { await connect.evaluate(webView) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            // Cancelled loads are normal during an SSO redirect chain.
            let ns = error as NSError
            guard ns.code != NSURLErrorCancelled else { return }
            connect.phase = .failed(error.localizedDescription)
        }
    }
}

// ---------------------------------------------------------------- the window
struct CanvasConnectView: View {
    @StateObject private var connect: CanvasConnect
    @Environment(\.dismiss) private var dismiss

    init(client: NotesClient) {
        _connect = StateObject(wrappedValue: CanvasConnect(client: client))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch connect.phase {
            case .connected(let who):
                success(who)
            case .failed(let why):
                failure(why)
            default:
                CanvasWebView(connect: connect)
            }
        }
        .frame(minWidth: 780, minHeight: 620)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "graduationcap.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sign in to Canvas").font(.system(size: 13, weight: .semibold))
                Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if case .verifying = connect.phase { ProgressView().controlSize(.small) }
            Button {
                connect.openPasswords()
            } label: {
                Label("Passwords", systemImage: "key.fill")
            }
            .help("Open the Passwords app to copy your Franciscan password, then paste it here (⌘V)")
            Menu {
                Button("Start fresh (clear saved Canvas sign-in)") {
                    Task { await connect.startFresh() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var statusLine: String {
        switch connect.phase {
        case .signingIn:
            if let why = connect.lastRejection { return "Still signing in — \(why)" }
            return connect.restoredSession
                ? "Reusing your saved sign-in…"
                : "Your password goes to Franciscan, never to this app. ⌘V works here."
        case .verifying:  return "Checking the session with the PC…"
        case .connected:  return "Connected."
        case .failed(let why): return why
        }
    }

    private func success(_ who: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40)).foregroundStyle(.green)
            Text("Canvas connected").font(.title3.weight(.semibold))
            Text("Signed in as \(who). The PC can now read your courses and module files. " +
                 "This sign-in is remembered, so reconnecting later usually needs no typing.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ why: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36)).foregroundStyle(.orange)
            Text("Couldn't connect").font(.title3.weight(.semibold))
            Text(why).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Try again") { connect.phase = .signingIn }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
