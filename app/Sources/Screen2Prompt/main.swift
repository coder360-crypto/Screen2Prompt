import AppKit

// Small CLI surface so the key and the engine can be set without any UI.
let args = CommandLine.arguments
if args.contains("--set-groq-key") {
    FileHandle.standardError.write("Paste your Groq API key and press Return:\n".data(using: .utf8)!)
    let key = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { print("nothing entered"); exit(1) }
    var c = Config.load(); c.provider = "groq"; c.save()
    print(Keychain.setGroqKey(key)
          ? "Saved to the login keychain. Provider set to groq."
          : "Could not write to the keychain.")
    exit(0)
}
if let i = args.firstIndex(of: "--provider"), i + 1 < args.count {
    var c = Config.load(); c.provider = args[i + 1]; c.save()
    print("provider = \(c.provider)  (\(Config.url.path))")
    exit(0)
}
if args.contains("--where") {
    print("config:   \(Config.url.path)")
    print("sessions: \(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Screen2Prompt").path)")
    exit(0)
}

// NSApplication.delegate is weak, so the delegate needs an owner that outlives setup.
nonisolated(unsafe) var keepAlive: AppDelegate?

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    keepAlive = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no dock icon
    app.run()
}
