import SwiftUI
import AppKit

/// The Messages window: conversation list on the left, bubbles and a composer on the right, in the style of Apple's Messages.
struct MessagesView: View {
    @ObservedObject var manager: MessagesManager
    @State private var query = ""
    @State private var draft = ""
    @State private var composeTo = ""
    @State private var composing = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    if manager.phones.count > 1 {
                        Picker("", selection: Binding(get: { manager.phoneId ?? "" }, set: { manager.selectPhone($0) })) {
                            ForEach(manager.phones) { Text($0.deviceName).tag($0.deviceId) }
                        }.labelsHidden()
                    } else {
                        Text(manager.phones.first?.deviceName ?? "No phone").font(.headline)
                    }
                    Spacer()
                    Button { composing = true; manager.openThread("") } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless).help("New message")
                }.padding(8)
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 8)
                List(selection: Binding(get: { manager.openThreadId }, set: { if let id = $0 { composing = false; manager.openThread(id) } })) {
                    ForEach(filtered) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(t.title).fontWeight(t.unread > 0 ? .semibold : .regular).lineLimit(1)
                                Spacer()
                                Text(t.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text((t.outgoing ? "You: " : "") + t.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .tag(t.id)
                    }
                }
                if manager.loading { ProgressView().controlSize(.small).padding(4) }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                if let error = manager.error {
                    Text(error).foregroundStyle(.red).font(.callout).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                if composing {
                    HStack { Text("To:"); TextField("Phone number", text: $composeTo) }.padding(8)
                    Divider()
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(manager.messages) { m in bubble(m).id(m.id) }
                        }.padding(12)
                    }
                    .onChange(of: manager.messages.count) { _, _ in
                        if let last = manager.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                Divider()
                HStack {
                    TextField("Text Message", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5)
                        .onSubmit(sendDraft)
                    Button("Send", action: sendDraft).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || address.isEmpty)
                }.padding(8)
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .onAppear { manager.open() }
    }

    private var filtered: [MessageThread] {
        query.isEmpty ? manager.threads : manager.threads.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.snippet.localizedCaseInsensitiveContains(query)
        }
    }

    private var address: String {
        if composing { return composeTo.trimmingCharacters(in: .whitespaces) }
        return manager.threads.first { $0.id == manager.openThreadId }?.address ?? ""
    }

    private func sendDraft() {
        guard !address.isEmpty else { return }
        manager.send(body: draft, to: address)
        draft = ""
    }

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.outgoing { Spacer(minLength: 60) }
            VStack(alignment: m.outgoing ? .trailing : .leading, spacing: 2) {
                Text(m.body)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(m.outgoing ? (m.failed ? Color.red : Color.blue) : Color(nsColor: .controlBackgroundColor))
                    .foregroundStyle(m.outgoing ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .opacity(m.sending ? 0.6 : 1)
                    .textSelection(.enabled)
                if m.failed { Text("Not delivered").font(.caption2).foregroundStyle(.red) }
            }
            if !m.outgoing { Spacer(minLength: 60) }
        }
    }
}

enum MessagesWindow {
    private static var window: NSWindow?

    static func show(manager: MessagesManager) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Messages"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MessagesView(manager: manager))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
