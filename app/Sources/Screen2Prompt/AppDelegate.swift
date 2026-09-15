import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var appearanceObs: NSKeyValueObservation?
    private var ticker: Timer?
    private var flashing = false

    private let session = Session()

    private let toggleItem = NSMenuItem(title: "Start recording", action: #selector(toggle), keyEquivalent: "")
    private let markItem   = NSMenuItem(title: "Capture screen", action: #selector(fireMarker), keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let resultLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let copyItem   = NSMenuItem(title: "Copy cards again", action: #selector(copyPaste), keyEquivalent: "")
    private let copyFull   = NSMenuItem(title: "Copy text only", action: #selector(copyTextOnly), keyEquivalent: "")
    private let openItem   = NSMenuItem(title: "Open sessions folder", action: #selector(openFolder), keyEquivalent: "")
    private let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
    private let recentMenu = NSMenu()

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        toggleItem.keyEquivalent = "r"
        toggleItem.keyEquivalentModifierMask = [.option]
        markItem.keyEquivalent = "c"
        markItem.keyEquivalentModifierMask = [.option]
        for item in [toggleItem, markItem] { item.target = self; menu.addItem(item) }
        menu.addItem(.separator())
        statusLine.isEnabled = false; menu.addItem(statusLine)
        resultLine.isEnabled = false; menu.addItem(resultLine)
        menu.addItem(.separator())
        for item in [copyItem, copyFull] { item.target = self; menu.addItem(item) }
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Screen2Prompt", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu

        if let button = statusItem.button {
            appearanceObs = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        }

        session.onChange = { [weak self] in self?.refresh() }
        session.onFinished = { [weak self] folder, steps, chars in
            NSSound(named: "Glass")?.play()
            self?.resultLine.title = "Copied \(steps) step\(steps == 1 ? "" : "s") · \(chars / 1024) KB · \(folder.lastPathComponent)"
            self?.refresh()
        }
        session.onFailure = { [weak self] msg in
            guard let self else { return }
            NSSound(named: "Basso")?.play()
            self.resultLine.title = "⚠︎ \(msg)"
            self.refresh()
            if self.session.captureFailures == 1 {      // shout once, not every marker
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.alertStyle = .critical
                a.messageText = "That capture failed — nothing was saved"
                a.informativeText = msg + "\n\nThe session is still recording audio, but no screenshot was taken."
                a.addButton(withTitle: "OK")
                a.runModal()
            }
        }

        HotKeys.shared.onPress = { [weak self] id in
            if id == HotKeys.toggleID { self?.toggle() }
            if id == HotKeys.markerID { self?.fireMarker() }
        }
        HotKeys.shared.install()
        // Two keys, one hand. Option+R to roll, Option+Space to grab a screen.
        let r = HotKeys.shared.register(id: HotKeys.toggleID, keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey))
        let s = HotKeys.shared.register(id: HotKeys.markerID, keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey))
        if r != noErr { resultLine.title = "\u{26A0} Option-R is already taken by another app" }
        if s != noErr { resultLine.title = "\u{26A0} Option-C is already taken by another app" }
        Log.write("launch: optR=\(r) optC=\(s) accessibility=\(AXIsProcessTrusted()) screenRecording=\(Capture.hasPermission) bundle=\(Bundle.main.bundleIdentifier ?? "?")")

        if !Capture.hasPermission { _ = ensureScreenPermission(atLaunch: true) }

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()

        if CommandLine.arguments.contains("--selftest") { runSelfTest() }
    }

    @objc private func toggle() {
        Task { @MainActor in
            switch session.state {
            case .idle:
                guard ensureScreenPermission(atLaunch: false) else { return }
                NSSound(named: "Tink")?.play(); await session.start()
            case .recording: await session.stop()
            case .finishing: break
            }
        }
    }

    @objc private func fireMarker() {
        guard session.state == .recording else { NSSound(named: "Funk")?.play(); return }
        NSSound(named: "Tink")?.play()
        flashing = true; refresh()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            self.flashing = false; self.refresh()
        }
        Task { @MainActor in await session.mark() }
    }

    /// Screen Recording is not optional here: without it a session records your voice
    /// and captures nothing, which is worse than refusing to start.
    @discardableResult
    private func ensureScreenPermission(atLaunch: Bool) -> Bool {
        Log.write("permission gate: hasPermission=\(Capture.hasPermission) atLaunch=\(atLaunch)")
        if Capture.hasPermission { return true }
        Capture.requestPermission()          // registers the app in the TCC list
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "Screen2Prompt can't capture your screen yet"
        a.informativeText = """
        Without Screen Recording access it would record your narration and save no \
        screenshots at all.

        Turn on Screen2Prompt in System Settings › Privacy & Security › Screen Recording, \
        then relaunch — macOS only applies the change on restart.
        """
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Relaunch")
        a.addButton(withTitle: "Later")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case .alertSecondButtonReturn:
            relaunch()
        default: break
        }
        return false
    }

    private func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    @objc private func copyPaste()   { session.copyForPaste();     NSSound(named: "Tink")?.play() }
    @objc private func copyTextOnly() { session.copyTextOnly(); NSSound(named: "Tink")?.play() }

    // MARK: - Recent sessions

    /// Past sessions, newest first. Clicking one puts its narration on the clipboard —
    /// which is also what makes it show up in a clipboard manager like Maccy.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: Session.root,
                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .prefix(12)

        guard !dirs.isEmpty else {
            let none = NSMenuItem(title: "No sessions yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for d in dirs {
            let name = d.lastPathComponent          // 2026-09-16_04-40-57_some-title
            let parts = name.split(separator: "_", maxSplits: 2).map(String.init)
            let clock = parts.count > 1 ? parts[1].replacingOccurrences(of: "-", with: ":") : ""
            let short = clock.split(separator: ":").prefix(2).joined(separator: ":")
            var label = parts.count > 2 ? parts[2].replacingOccurrences(of: "-", with: " ") : "untitled"
            if label.count > 46 { label = String(label.prefix(46)) + "…" }
            let item = NSMenuItem(title: "\(short)   \(label)", action: #selector(copyRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Click to copy that session's text", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        var text = (try? String(contentsOf: dir.appendingPathComponent("transcript.txt"), encoding: .utf8)) ?? ""
        if text.isEmpty {
            // sessions recorded before transcript.txt existed
            text = (try? String(contentsOf: dir.appendingPathComponent("doc.md"), encoding: .utf8)) ?? ""
        }
        guard !text.isEmpty else { NSSound(named: "Basso")?.play(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        NSSound(named: "Tink")?.play()
        resultLine.title = "Copied text from \(dir.lastPathComponent)"
        refresh()
    }
    @objc private func openFolder() {
        NSWorkspace.shared.open(Session.root)
    }
    @objc private func quit() { HotKeys.shared.unregisterAll(); NSApp.terminate(nil) }

    private func refresh() {
        guard let button = statusItem.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let live = session.state != .idle
        button.image = Glyph.image(recording: live, flash: flashing, tint: dark ? .white : .black)
        button.title = session.state == .recording && session.markerCount > 0 ? " \(session.markerCount)" : ""
        button.imagePosition = .imageLeading

        switch session.state {
        case .idle:
            toggleItem.title = "Start recording"
            statusLine.title = "Ready \u{2014} press \u{2325}R to start"
        case .recording:
            toggleItem.title = "Stop and copy"
            let e = Int(session.elapsed)
            statusLine.title = String(format: "Recording  %02d:%02d  ·  %d capture%@",
                                      e / 60, e % 60, session.markerCount,
                                      session.markerCount == 1 ? "" : "s")
        case .finishing:
            toggleItem.title = "Finishing…"
            statusLine.title = "Transcribing and building the document…"
        }
        markItem.isEnabled = session.state == .recording
        let has = session.lastFolder != nil
        copyItem.isEnabled = has; copyFull.isEnabled = has
        resultLine.isHidden = resultLine.title.isEmpty
    }

    /// Drives a whole session without a human keypress, so the pipeline can be verified.
    private func runSelfTest() {
        Task { @MainActor in
            FileHandle.standardError.write("[selftest] starting\n".data(using: .utf8)!)
            await session.start()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await session.mark()
            FileHandle.standardError.write("[selftest] marker 1\n".data(using: .utf8)!)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await session.mark()
            FileHandle.standardError.write("[selftest] marker 2\n".data(using: .utf8)!)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await session.stop()
            FileHandle.standardError.write("[selftest] done: \(session.lastFolder?.path ?? "none") err=\(session.lastError ?? "none")\n".data(using: .utf8)!)
            NSApp.terminate(nil)
        }
    }
}
