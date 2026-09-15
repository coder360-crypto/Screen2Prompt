import AppKit
import Carbon.HIToolbox

/// Carbon RegisterEventHotKey — the path Maccy and friends use.
/// It is deprecated-but-alive, and unlike NSEvent.addGlobalMonitorForEvents
/// or CGEventTap it does NOT require the Accessibility permission.
/// SPEC.md §12 Phase 0, exit criterion 3.
final class HotKeys {
    static let shared = HotKeys()
    var onPress: ((UInt32) -> Void)?
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    static let toggleID: UInt32 = 1
    static let markerID: UInt32 = 2

    func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeys.shared.onPress?(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Returns the OSStatus so a collision (eventHotKeyExistsErr, -9878) is visible
    /// rather than silently doing nothing — SPEC.md §11 calls that the worst failure here.
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, signature: String = "S2PT") -> OSStatus {
        var ref: EventHotKeyRef?
        let sig = signature.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let hkID = EventHotKeyID(signature: OSType(sig), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { refs.append(ref) }
        return status
    }

    func unregisterAll() {
        for r in refs where r != nil { UnregisterEventHotKey(r!) }
        refs.removeAll()
    }
}
