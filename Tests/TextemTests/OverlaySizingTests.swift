import AppKit
import SwiftUI
import XCTest
@testable import scarcrux_textem

// A phone panel laid over the web view must never resize the window. A
// SwiftUI host by default pushes its ideal size (e.g. a 1050×700 picture plus
// controls) onto the window; Textem.overlayHost turns that off.
@MainActor
final class OverlaySizingTests: XCTestCase {
    private struct BigPicture: View {
        var body: some View {
            VStack { Text("Saved image"); Color.orange.frame(width: 1050, height: 700) }.padding(40)
        }
    }

    private func windowHeight(after host: NSView) -> CGFloat {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        window.contentView = container
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 340),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor, constant: 64),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.layoutIfNeeded()
        return window.contentLayoutRect.height
    }

    func testDefaultHostGrowsTheWindowSoTheCheckCanFail() {
        XCTAssertGreaterThan(windowHeight(after: NSHostingView(rootView: BigPicture())), 600)
    }

    func testOverlayHostKeepsTheWindowSize() {
        XCTAssertEqual(windowHeight(after: WebViewController.overlayHost(BigPicture())), 600, accuracy: 0.5)
    }
}
