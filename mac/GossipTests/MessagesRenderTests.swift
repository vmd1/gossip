import XCTest
import SwiftUI
@testable import Gossip

/// Renders pieces of the Messages UI to a PNG (path in GOSSIP_RENDER_OUT) so the look can be checked without a screen.
final class MessagesRenderTests: XCTestCase {
    @MainActor
    func testRenderBubbles() throws {
        guard let out = ProcessInfo.processInfo.environment["GOSSIP_RENDER_OUT"] else { throw XCTSkip("no output path") }
        func bubble(_ text: String, outgoing: Bool, tail: Bool) -> some View {
            Text(text).font(.system(size: 13.5)).foregroundStyle(outgoing ? Color.white : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 7).padding(outgoing ? .trailing : .leading, 5)
                .background(BubbleShape(outgoing: outgoing, tail: tail).fill(outgoing ? Color(red: 0.19, green: 0.82, blue: 0.35) : Color(white: 0.23)))
                .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
        }
        let view = VStack(spacing: 4) {
            Avatar(title: "Kiana Dharia", isNumber: false, size: 56)
            Text("kh <3").font(.system(size: 13, weight: .semibold)).padding(.top, 8)
            bubble("Babes I do know how to install an app", outgoing: false, tail: false)
            bubble("Lmfao", outgoing: false, tail: true)
            bubble("yes I know", outgoing: true, tail: false)
            bubble("I was just saying cos I have 3 diff app stores on my phone", outgoing: true, tail: true)
            Avatar(title: "+447822027638", isNumber: true, size: 38)
        }
        .padding(20).frame(width: 520).background(Color(white: 0.12)).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}
