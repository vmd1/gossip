import AppKit
import Foundation
import Security

/// Remembered lock-screen credentials for "unlock from the Mac" (screen-off mirroring), one per phone, in the login
/// Keychain. Opt-in per phone from the unlock prompt; a credential the phone rejects is forgotten.
///
/// Unlike the identity/trust blobs (`SecretBlobStore`), this one is a credential for another device, so it goes in the
/// Keychain despite the self-signed build: macOS may ask once after a rebuild whether Gossip may read it.
enum RemoteUnlockStore {
    private static let service = "dev.vmd1.gossip.remote-unlock"

    static func secret(for deviceId: String) -> String? {
        var query = baseQuery(deviceId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ secret: String, for deviceId: String) {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(baseQuery(deviceId) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(deviceId)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Gossip phone unlock"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func forget(_ deviceId: String) {
        SecItemDelete(baseQuery(deviceId) as CFDictionary)
    }

    private static func baseQuery(_ deviceId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: deviceId]
    }
}

/// The Mac's native prompt for a locked phone's PIN or password (the phone's own entry screen is FLAG_SECURE, so it
/// shows up black in the mirror and can't be used from here).
enum RemoteUnlockPrompt {
    struct Answer {
        let secret: String
        let remember: Bool
    }

    /// Modal; `nil` when cancelled. Must be called on the main thread.
    static func ask(deviceName: String, retry: Bool) -> Answer? {
        let alert = NSAlert()
        alert.messageText = retry ? "Wrong PIN or password" : "\(deviceName) is locked"
        alert.informativeText = retry
            ? "\(deviceName) is still locked. Enter its PIN or password again. Wrong attempts count toward the phone's lockout."
            : "Enter its lock screen PIN or password to unlock it and start mirroring. The phone's screen stays dark."
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 26, width: 260, height: 24))
        field.placeholderString = "PIN or password"
        let remember = NSButton(checkboxWithTitle: "Remember on this Mac", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 50))
        box.addSubview(field)
        box.addSubview(remember)
        alert.accessoryView = box
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let secret = field.stringValue
        guard !secret.isEmpty else { return nil }
        return Answer(secret: secret, remember: remember.state == .on)
    }
}

/// A small floating "Unlocking… / Connecting…" panel shown while a whole-screen mirror is being set up, so the few
/// seconds before the mirror window appears don't look like nothing is happening. Doesn't take focus.
final class MirrorProgressHUD {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    /// Shows the panel, or updates its text if it's already up. Main thread.
    func show(_ text: String) {
        label.stringValue = text
        if let panel { return fit(panel) }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        p.contentView = background
        self.stack = stack
        panel = p
        fit(p)
        p.orderFrontRegardless()
    }

    private var stack: NSStackView?

    /// Sizes the panel to its content plus padding and centers it on the screen.
    private func fit(_ p: NSPanel) {
        guard let stack else { return }
        stack.layoutSubtreeIfNeeded()
        let content = stack.fittingSize
        let size = NSSize(width: ceil(content.width) + 40, height: max(48, ceil(content.height) + 28))
        p.setContentSize(size)
        // Dead center of the screen (NSWindow.center() sits noticeably above the middle).
        if let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        stack = nil
    }
}
