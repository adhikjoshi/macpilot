import AppKit
import Foundation

/// Lightweight visual overlay for indicating MacPilot actions.
/// Shows brief visual feedback (circles for clicks, borders for screenshots, etc.)
/// Auto-dismisses after a short delay. Does not interfere with automation.
enum Overlay {

    /// Show a small circle at the given screen coordinates (for click feedback)
    static func showClick(x: Double, y: Double, duration: TimeInterval = 0.4) {
        showOverlay(duration: duration) { screen in
            let size: CGFloat = 30
            // Convert screen coords to window coords (top-left origin)
            let frame = NSRect(x: x - Double(size/2), y: Double(screen.frame.maxY) - y - Double(size/2), width: Double(size), height: Double(size))
            let window = makeWindow(frame: frame, screen: screen)
            let view = ClickIndicatorView(frame: NSRect(origin: .zero, size: frame.size))
            window.contentView = view
            return window
        }
    }

    /// Flash a border around the screen (for screenshot feedback)
    static func showScreenFlash(duration: TimeInterval = 0.3) {
        showOverlay(duration: duration) { screen in
            let window = makeWindow(frame: screen.frame, screen: screen)
            let view = BorderFlashView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            return window
        }
    }

    /// Show a small notification at top of screen with text (for keyboard feedback)
    static func showKeyNotification(text: String, duration: TimeInterval = 0.5) {
        showOverlay(duration: duration) { screen in
            let width: CGFloat = min(CGFloat(text.count * 12 + 40), 300)
            let height: CGFloat = 32
            let x = screen.frame.midX - width / 2
            let y = screen.frame.maxY - height - 40
            let frame = NSRect(x: x, y: y, width: width, height: height)
            let window = makeWindow(frame: frame, screen: screen)
            let view = KeyNotificationView(frame: NSRect(origin: .zero, size: frame.size), text: text)
            window.contentView = view
            return window
        }
    }

    // MARK: - Private

    private static func makeWindow(frame: NSRect, screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        return window
    }

    private static func showOverlay(duration: TimeInterval, builder: @escaping (NSScreen) -> NSWindow) {
        // Run on main thread, but don't block
        DispatchQueue.main.async {
            guard let screen = NSScreen.main else { return }
            let window = builder(screen)
            window.orderFrontRegardless()

            // Fade out and close
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.15
                    window.animator().alphaValue = 0
                }, completionHandler: {
                    window.close()
                })
            }
        }
    }
}

// MARK: - Custom Views

private class ClickIndicatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        NSColor.systemYellow.withAlphaComponent(0.8).setFill()
        path.fill()
        NSColor.systemOrange.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

private class BorderFlashView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3))
        NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 6
        path.stroke()
    }
}

private class KeyNotificationView: NSView {
    let text: String
    init(frame: NSRect, text: String) {
        self.text = text
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        path.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        str.draw(at: origin)
    }
}
