import SwiftUI
import AppKit

/// The clipboard history window: search, click to copy back, pin, delete, clear, and the on/off toggle.
struct ClipboardHistoryView: View {
    @ObservedObject var store: ClipboardHistoryStore
    var onCopy: (String) -> Void
    @State private var query = ""
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Keep clipboard history on this Mac", isOn: Binding(get: { store.isEnabled }, set: { store.isEnabled = $0 }))
            Text("Stored only on this Mac, never sent to other devices or the relay. Passwords from password managers are skipped.")
                .font(.caption).foregroundStyle(.secondary)
            if store.isEnabled {
                TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                List(store.filtered(query)) { entry in
                    HStack {
                        Button { onCopy(entry.text) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(entry.remote ? "From another device · " : "")\(entry.date.formatted(.relative(presentation: .named)))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                        Button { store.togglePin(entry.id) } label: { Image(systemName: entry.pinned ? "pin.fill" : "pin") }
                            .buttonStyle(.borderless).help(entry.pinned ? "Unpin" : "Pin")
                        Button { store.remove(entry.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Delete")
                    }
                }
                HStack {
                    Text("\(store.entries.count) items").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear All…") { confirmClear = true }.disabled(store.entries.isEmpty)
                }
            } else {
                Spacer()
            }
        }
        .padding(12)
        .frame(minWidth: 380, minHeight: 360)
        .confirmationDialog("Delete all clipboard history, including pinned items?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) { store.clear() }
        }
    }
}

final class ClipboardHistoryWindow: NSWindow {
    private static var shared: ClipboardHistoryWindow?

    static func show(onCopy: @escaping (String) -> Void) {
        if shared == nil {
            let w = ClipboardHistoryWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Clipboard History"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ClipboardHistoryView(store: .shared, onCopy: onCopy))
            w.center()
            shared = w
        }
        shared?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
