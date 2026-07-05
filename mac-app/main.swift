import AppKit
import Foundation
import ApplicationServices

// Private libsystem call: with disclaim = 0 the spawned child stays under the
// PARENT's TCC responsibility. This is why the app's Accessibility grant then
// covers node's osascript keystrokes. (Chromium & others use the same call.)
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

/// Runs the Co/Pad Node helper (`server.js`) as a child process and surfaces its
/// state. Node is spawned WITHOUT disclaiming responsibility, so the .app stays
/// the responsible process for TCC — Accessibility / Automation granted to
/// "Co/Pad Server" cover node's keystrokes. No terminal needed.
final class HelperController {
    private var pid: pid_t = 0
    private var outPipe: Pipe?
    private var exitSource: DispatchSourceProcess?
    private(set) var address = ""
    private(set) var running = false
    private(set) var clients = 0
    private(set) var note = ""
    var onChange: (() -> Void)?

    private let resourceDir: URL
    init(resourceDir: URL) { self.resourceDir = resourceDir }

    func start() {
        guard pid == 0 else { return }
        guard let node = Self.findNode() else {
            note = "Node not found — install Node 18+"; running = false; emit(); return
        }
        let serverJs = resourceDir.appendingPathComponent("server.js").path

        let pipe = Pipe()
        let writeFD = pipe.fileHandleForWriting.fileDescriptor

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, 1)   // stdout
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, 2)   // stderr
        posix_spawn_file_actions_addchdir_np(&fileActions, resourceDir.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        _ = responsibility_spawnattrs_setdisclaim(&attr, 0)  // keep the app responsible

        let argv: [String] = [node, serverJs]
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]

        var newPid: pid_t = 0
        let rc = posix_spawn(&newPid, node, &fileActions, &attr, cArgs, environ)

        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)
        cArgs.forEach { free($0) }

        guard rc == 0 else {
            note = "Failed to launch node (posix_spawn \(rc))"; running = false; emit(); return
        }
        pid = newPid
        outPipe = pipe
        running = true; note = ""

        try? pipe.fileHandleForWriting.close()  // parent's copy — let EOF work
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            self?.parse(s)
        }

        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, self.pid != 0 else { return }
            let dead = self.pid
            self.teardown()
            var s: Int32 = 0; waitpid(dead, &s, WNOHANG)  // reap
        }
        exitSource = src
        src.resume()
        emit()
    }

    /// Release handlers/source and reset state (does not kill).
    private func teardown() {
        exitSource?.cancel(); exitSource = nil
        outPipe?.fileHandleForReading.readabilityHandler = nil
        outPipe = nil
        pid = 0; running = false; clients = 0
        emit()
    }

    func stop() {
        let dead = pid
        teardown()
        if dead != 0 {
            kill(dead, SIGTERM)
            DispatchQueue.global().async { var s: Int32 = 0; waitpid(dead, &s, 0) }  // reap
        }
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.start() }
    }

    private func parse(_ s: String) {
        // Runs on the pipe's background queue. All state mutation and emit()
        // must happen on the main thread — rebuildMenu() reads this state there.
        var newAddress: String?
        var delta = 0
        if let r = s.range(of: #"ws://[0-9.]+:[0-9]+"#, options: .regularExpression) {
            newAddress = String(s[r])
        }
        for line in s.split(separator: "\n") {
            if line.contains("client connected") { delta += 1 }
            else if line.contains("client disconnected") { delta -= 1 }
        }
        guard newAddress != nil || delta != 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let newAddress { self.address = newAddress }
            if delta != 0 { self.clients = max(0, self.clients + delta) }
            self.emit()
        }
    }

    private func emit() { onChange?() }

    /// Locate the `node` binary — common install paths, nvm, then a login shell
    /// (covers Homebrew, /usr/local, and nvm-managed installs).
    static func findNode() -> String? {
        let fm = FileManager.default

        for p in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] {
            if fm.isExecutableFile(atPath: p) { return p }
        }

        // nvm: ~/.nvm/versions/node/<version>/bin/node — pick the newest.
        let nvm = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            let candidates = versions
                .filter { fm.isExecutableFile(atPath: $0.appendingPathComponent("bin/node").path) }
                // Sort by the version directory name (e.g. "v20.11.0"), not the
                // full binary path — a numeric compare over the whole path
                // misorders versions.
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
            if let newest = candidates.last {
                return newest.appendingPathComponent("bin/node").path
            }
        }

        // Login shell PATH (zsh first — the macOS default — then bash).
        for shell in ["/bin/zsh", "/bin/bash"] {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: shell)
            t.arguments = ["-lc", "command -v node"]
            let pipe = Pipe(); t.standardOutput = pipe
            do { try t.run() } catch { continue }
            t.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let out, !out.isEmpty, fm.isExecutableFile(atPath: out) { return out }
        }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let helper = HelperController(resourceDir: Bundle.main.resourceURL
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    private var axTrusted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Canonical Accessibility request: the app asks the system, which adds it
        // to the list correctly bound to this process's code identity and prompts
        // on first run if not yet granted.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        axTrusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        // Re-check so the menu reflects a grant (or revocation) made while running.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = AXIsProcessTrusted()
            if now != self.axTrusted { self.axTrusted = now; self.rebuildMenu() }
        }
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slash.circle.fill",
                                   accessibilityDescription: "Co/Pad Server")
            button.image?.isTemplate = true
        }
        helper.onChange = { [weak self] in self?.rebuildMenu() }
        rebuildMenu()
        helper.start()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Co/Pad Server", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let statusText: String
        if !helper.note.isEmpty { statusText = "⚠︎ \(helper.note)" }
        else if helper.running { statusText = "● Running — \(helper.clients) connected" }
        else { statusText = "○ Stopped" }
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        // Clear, actionable warning when Accessibility isn't granted — without it
        // keystroke macros / the dial silently do nothing (Chrome/Music still work).
        if !axTrusted {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: "⚠︎ Accessibility off — keys won't type",
                                  action: #selector(openAccessibility), keyEquivalent: "")
            warn.target = self
            warn.toolTip = "Grant Accessibility to Co/Pad Server so it can send keystrokes."
            menu.addItem(warn)
        }

        if helper.running && !helper.address.isEmpty {
            let addr = NSMenuItem(title: helper.address, action: #selector(copyAddress), keyEquivalent: "")
            addr.target = self
            addr.toolTip = "Click to copy"
            menu.addItem(addr)
        }

        menu.addItem(.separator())
        let run = NSMenuItem(title: helper.running ? "Restart Helper" : "Start Helper",
                             action: #selector(toggleRun), keyEquivalent: "r")
        run.target = self
        menu.addItem(run)

        let acc = NSMenuItem(title: "Open Accessibility Settings…",
                             action: #selector(openAccessibility), keyEquivalent: "")
        acc.target = self
        menu.addItem(acc)

        let auto = NSMenuItem(title: "Open Automation Settings…",
                              action: #selector(openAutomation), keyEquivalent: "")
        auto.target = self
        menu.addItem(auto)

        menu.addItem(.separator())
        let about = NSMenuItem(title: "About Co/Pad Server", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Co/Pad Server", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.toolTip = helper.running ? (helper.address.isEmpty ? "Co/Pad Server" : helper.address)
                                                     : "Co/Pad Server — stopped"
    }

    @objc private func toggleRun() { helper.running ? helper.restart() : helper.start() }

    @objc private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(helper.address, forType: .string)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openAutomation() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "The Mac server for Co/Pad — your iPad macro pad for Claude Code.\n\n"
                  + "Runs the helper that turns iPad key taps into real Mac keystrokes: "
                  + "multi-instance targeting, keyboard shortcuts, trackpad haptics, "
                  + "voice dictation and Kokoro read-back.\n\n"
                  + "iPad + Mac on the same Wi-Fi. Menu-bar only — grant Accessibility to type.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Co/Pad Server",
            .applicationVersion: "1.0",
            .version: "1",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Co/Pad",
        ])
    }

    @objc private func quit() { helper.stop(); NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) { helper.stop() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()
