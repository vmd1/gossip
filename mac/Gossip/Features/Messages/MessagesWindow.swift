import SwiftUI
import AppKit

// MARK: - Look: follows Apple's Messages (green SMS bubbles with tails, grey incoming, round avatars, capsule composer).

private enum MessagesStyle {
    static let sms = Color(red: 0.19, green: 0.82, blue: 0.35)        // Messages' SMS green
    static let failed = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let incoming = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.23, alpha: 1) : NSColor(white: 0.91, alpha: 1)
    })
    static let selection = Color.accentColor
}

/// An Apple Messages bubble: rounded body with the small curled tail on the last bubble of a run. Drawn for an incoming
/// bubble (tail bottom-left); an outgoing bubble is the mirror image.
struct BubbleShape: Shape {
    let outgoing: Bool
    let tail: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let r = min(18, h / 2)
        if tail {
            p.move(to: CGPoint(x: 20, y: h))
            p.addLine(to: CGPoint(x: w - r, y: h))
            p.addCurve(to: CGPoint(x: w, y: h - r), control1: CGPoint(x: w - r * 0.5, y: h), control2: CGPoint(x: w, y: h - r * 0.5))
            p.addLine(to: CGPoint(x: w, y: r))
            p.addCurve(to: CGPoint(x: w - r, y: 0), control1: CGPoint(x: w, y: r * 0.5), control2: CGPoint(x: w - r * 0.5, y: 0))
            p.addLine(to: CGPoint(x: 5 + r, y: 0))
            p.addCurve(to: CGPoint(x: 5, y: r), control1: CGPoint(x: 5 + r * 0.5, y: 0), control2: CGPoint(x: 5, y: r * 0.5))
            p.addLine(to: CGPoint(x: 5, y: h - 10))
            p.addCurve(to: CGPoint(x: 0, y: h), control1: CGPoint(x: 5, y: h - 1), control2: CGPoint(x: 0, y: h))
            p.addLine(to: CGPoint(x: -1, y: h))
            p.addCurve(to: CGPoint(x: 12, y: h - 4), control1: CGPoint(x: 4, y: h + 1), control2: CGPoint(x: 8, y: h - 1))
            p.addCurve(to: CGPoint(x: 20, y: h), control1: CGPoint(x: 15, y: h), control2: CGPoint(x: 20, y: h))
            p.closeSubpath()
        } else {
            p.addRoundedRect(in: CGRect(x: 5, y: 0, width: w - 5, height: h), cornerSize: CGSize(width: r, height: r), style: .continuous)
        }
        if outgoing {
            p = p.applying(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))
        }
        return p
    }
}

struct Avatar: View {
    let title: String
    let isNumber: Bool
    var size: CGFloat = 40

    private var initials: String {
        let words = title.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: isNumber ? [Color(white: 0.70), Color(white: 0.50)] : [Color(red: 0.55, green: 0.50, blue: 0.85), Color(red: 0.34, green: 0.30, blue: 0.62)],
                startPoint: .top, endPoint: .bottom))
            if isNumber || initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.5)).foregroundStyle(.white)
            } else {
                Text(initials).font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

private func isPhoneNumber(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isNumber || "+-() ".contains($0) } }

/// "13:15", "Yesterday", "Mon", "19/10/2026" — how the conversation list stamps a thread.
private func listStamp(_ date: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    if let days = cal.dateComponents([.day], from: date, to: now).day, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
    return date.formatted(date: .numeric, time: .omitted)
}

/// The centred stamp shown above a run of messages ("Today 13:15", "Mon 09:02", "19 Oct 2026 at 09:02").
private func runStamp(_ date: Date) -> String {
    let cal = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if cal.isDateInToday(date) { return "Today \(time)" }
    if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
    if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 { return "\(date.formatted(.dateTime.weekday(.wide))) \(time)" }
    return date.formatted(date: .abbreviated, time: .shortened)
}

/// A capsule with Liquid Glass on macOS 26 and a material capsule before that.
private struct GlassCapsule<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let label = content.padding(.horizontal, 14).padding(.vertical, 6)
        if #available(macOS 26.0, *) {
            label.glassEffect(.regular, in: .capsule)
        } else {
            label.background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        }
    }
}

/// A light blur over the top of the conversation: messages passing under the header soften as they reach it instead of being
/// cut off. A single material layer faded by a gradient, kept short and light like Apple's Messages. Drawn
/// on every macOS version (the system scroll-edge effect only applies under a real toolbar, which this header isn't).
private struct SoftTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            // One light layer, tall enough to cover the avatar and name and no more, as in Apple's Messages.
            Rectangle().fill(.ultraThinMaterial)
                .mask(LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .black.opacity(0.5), location: 0.5),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .frame(height: 88)
            .allowsHitTesting(false)
            .ignoresSafeArea(.container, edges: .top)
        }
    }
}

// MARK: - Views

struct MessagesView: View {
    @ObservedObject var manager: MessagesManager
    @State private var query = ""
    @State private var draft = ""
    @State private var composeTo = ""
    /// A contact picked from the suggestions (the typed text is then just their name).
    @State private var pickedNumber: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, minHeight: 440)
        .onAppear { manager.open() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("Search", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
            .padding(.horizontal, 10).padding(.vertical, 8)

            List(selection: Binding(get: { manager.openThreadId }, set: { manager.openThread($0) })) {
                ForEach(filtered) { thread in
                    ThreadRow(thread: thread, showPhone: manager.reachablePhones.count > 1)
                        .tag(thread.id)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if filtered.isEmpty {
                    Text(manager.loading ? "Loading…" : (query.isEmpty ? "No Conversations" : "No Results"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { manager.startComposing() } label: { Image(systemName: "square.and.pencil") }
                    .help("New Message")
            }
        }
    }

    private var filtered: [MessageThread] {
        query.isEmpty ? manager.threads : manager.threads.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.snippet.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: Detail

    private var composing: Bool { manager.openThreadId == nil }

    private var recipient: String {
        composing ? (pickedNumber ?? composeTo.trimmingCharacters(in: .whitespaces)) : (manager.openThread?.address ?? "")
    }

    /// Contacts matching what was typed in "To:"; picking one fills in their number and the phone it belongs to.
    @ViewBuilder
    private var suggestionList: some View {
        let matches = pickedNumber == nil ? manager.suggestions(for: composeTo) : []
        if !matches.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.offset) { _, m in
                    Button {
                        composeTo = m.contact.name
                        pickedNumber = m.number
                        manager.composePhoneId = m.phoneId
                    } label: {
                        HStack(spacing: 10) {
                            Avatar(title: m.contact.name, isNumber: false, size: 28)
                            Text(m.contact.name).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(m.number).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Divider()
            }
        }
    }

    private var phoneId: String? { composing ? manager.composePhoneId : manager.openThread?.phoneId }

    private var detail: some View {
        VStack(spacing: 0) {
            if composing {
                HStack(spacing: 8) {
                    Text("To:").foregroundStyle(.secondary)
                    TextField("Name or phone number", text: Binding(get: { composeTo }, set: { composeTo = $0; pickedNumber = nil }))
                        .textFieldStyle(.plain)
                    if manager.phones.count > 1 {
                        Picker("", selection: Binding(get: { manager.composePhoneId ?? "" }, set: { manager.composePhoneId = $0 })) {
                            ForEach(manager.phones) { Text("via \($0.deviceName)").tag($0.deviceId) }
                        }.labelsHidden().fixedSize()
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 10).padding(.top, 36) // clears the traffic lights
                Divider()
                suggestionList
            }
            if let error = manager.error {
                Text(error).font(.callout).foregroundStyle(.white).padding(8).frame(maxWidth: .infinity)
                    .background(MessagesStyle.failed)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) { conversation }
                        .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, composing ? 12 : 186) // room for the floating header
                }
                .onChange(of: manager.messages) { _, new in
                    if let last = new.last?.id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) } }
                }
                // Messages scroll under the header and fade out into a soft blur at the top, like Apple's Messages.
                .modifier(SoftTopEdge())
            }
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .top) { conversationHeader.ignoresSafeArea(.container, edges: .top) }
    }

    /// The avatar over a glass name capsule, centred at the top of the conversation where the title bar is, like Apple's
    /// Messages. Floats above the messages, which blur out beneath it.
    private var conversationHeader: some View {
        VStack(spacing: -4) {
            if let t = manager.openThread {
                Avatar(title: t.title, isNumber: isPhoneNumber(t.title), size: 56)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .zIndex(1) // in front of the name capsule it overlaps
                GlassCapsule { Text(t.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).padding(.top, 10) }
            } else {
                GlassCapsule { Text("New Message").font(.system(size: 13, weight: .semibold)) }
                    .padding(.top, 14)
            }
        }
        .padding(.top, 80)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var conversation: some View {
        let items = manager.messages
        ForEach(Array(items.enumerated()), id: \.element.id) { index, m in
            let previous = index > 0 ? items[index - 1] : nil
            let next = index + 1 < items.count ? items[index + 1] : nil
            if previous == nil || m.date.timeIntervalSince(previous!.date) > 3600 {
                Text(runStamp(m.date)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.top, previous == nil ? 0 : 10).padding(.bottom, 4)
            }
            let startsRun = previous == nil || previous!.outgoing != m.outgoing || m.date.timeIntervalSince(previous!.date) > 3600
            let endsRun = next == nil || next!.outgoing != m.outgoing || next!.date.timeIntervalSince(m.date) > 3600
            VStack(alignment: m.outgoing ? .trailing : .leading, spacing: 2) {
                bubble(m, tail: endsRun)
                if m.failed {
                    Text("Not Delivered").font(.system(size: 10)).foregroundStyle(MessagesStyle.failed)
                } else if m.sending {
                    Text("Sending…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: m.outgoing ? .trailing : .leading)
            .padding(.top, startsRun ? 6 : 0)
            .id(m.id)
        }
    }

    private func bubble(_ m: ChatMessage, tail: Bool) -> some View {
        Text(m.body)
            .font(.system(size: 13.5))
            .foregroundStyle(m.outgoing ? Color.white : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .padding(m.outgoing ? .trailing : .leading, 5)
            .background(
                BubbleShape(outgoing: m.outgoing, tail: tail)
                    .fill(m.outgoing ? (m.failed ? MessagesStyle.failed : MessagesStyle.sms) : MessagesStyle.incoming)
            )
            .opacity(m.sending ? 0.7 : 1)
            .textSelection(.enabled)
            .frame(maxWidth: 440, alignment: m.outgoing ? .trailing : .leading)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Text Message • SMS", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.leading, 14).padding(.trailing, 36).padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)).foregroundStyle(MessagesStyle.sms)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4).padding(.bottom, 3)
                    .opacity(canSend ? 1 : 0)
                    .disabled(!canSend)
                }
                .onSubmit(sendDraft)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recipient.isEmpty && phoneId != nil }

    private func sendDraft() {
        guard canSend, let phoneId else { return }
        manager.send(body: draft, to: recipient, via: phoneId)
        draft = ""
    }
}

private struct ThreadRow: View {
    let thread: MessageThread
    let showPhone: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(thread.unread > 0 ? Color.accentColor : .clear).frame(width: 9, height: 9)
            Avatar(title: thread.title, isNumber: isPhoneNumber(thread.title), size: 38)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(listStamp(thread.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text((thread.outgoing ? "You: " : "") + thread.snippet)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                if showPhone {
                    Text(thread.phoneName).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Opens the Messages window with its own Dock icon. Gossip itself is a menu-bar app with no Dock presence, so while the
/// window is open the app becomes a regular one wearing the Messages icon (taken from the embedded "Gossip Messages"
/// launcher), and goes back to being a menu-bar app when the window closes.
enum MessagesWindow {
    private static var window: NSWindow?
    private static let closeObserver = CloseObserver()
    fileprivate static weak var manager: MessagesManager?

    private final class CloseObserver: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            // Back to a menu-bar app: no Dock icon, and the default icon again.
            NSApp.applicationIconImage = nil
            NSApp.setActivationPolicy(.accessory)
            MessagesWindow.manager?.close()
        }
    }

    private static var icon: NSImage? {
        let url = Bundle.main.sharedSupportURL?
            .appendingPathComponent("\(LauncherInstaller.messagesLauncherName)/Contents/Resources/AppIcon.icns")
        return url.flatMap { NSImage(contentsOf: $0) }
    }

    static func show(manager: MessagesManager) {
        self.manager = manager
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Messages"
            w.titleVisibility = .hidden // the conversation header and the sidebar already say what this is
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = closeObserver
            w.contentView = NSHostingView(rootView: MessagesView(manager: manager))
            w.setFrameAutosaveName("GossipMessages")
            w.center()
            window = w
        }
        manager.open() // also when the window is re-shown after being closed
        NSApp.setActivationPolicy(.regular)
        if let icon { NSApp.applicationIconImage = icon }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
