import ArgumentParser
import CoreGraphics
import Foundation

struct Click: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Click at x,y coordinates")

    @Argument(help: "X coordinate") var x: Double
    @Argument(help: "Y coordinate") var y: Double
    @Flag(name: .long, help: "Output as JSON") var json = false

    func run() {
        MouseController.click(x: x, y: y)
        flashIndicatorIfRunning()
        JSONOutput.print(["status": "ok", "message": "Clicked at \(Int(x)),\(Int(y))"], json: json)
    }
}

struct DoubleClick: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doubleclick", abstract: "Double-click at x,y")

    @Argument var x: Double
    @Argument var y: Double
    @Flag(name: .long) var json = false

    func run() {
        MouseController.doubleClick(x: x, y: y)
        flashIndicatorIfRunning()
        JSONOutput.print(["status": "ok", "message": "Double-clicked at \(Int(x)),\(Int(y))"], json: json)
    }
}

struct RightClick: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rightclick", abstract: "Right-click at x,y")

    @Argument var x: Double
    @Argument var y: Double
    @Flag(name: .long) var json = false

    func run() {
        MouseController.rightClick(x: x, y: y)
        flashIndicatorIfRunning()
        JSONOutput.print(["status": "ok", "message": "Right-clicked at \(Int(x)),\(Int(y))"], json: json)
    }
}

struct Move: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Move mouse to x,y")

    @Argument var x: Double
    @Argument var y: Double
    @Flag(name: .long) var json = false

    func run() {
        MouseController.move(x: x, y: y)
        flashIndicatorIfRunning()
        JSONOutput.print(["status": "ok", "message": "Moved to \(Int(x)),\(Int(y))"], json: json)
    }
}

struct Drag: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Drag from x1,y1 to x2,y2")

    @Argument(help: "Start X") var x1: Double
    @Argument(help: "Start Y") var y1: Double
    @Argument(help: "End X") var x2: Double
    @Argument(help: "End Y") var y2: Double
    @Flag(name: .long) var json = false

    func run() {
        MouseController.drag(fromX: x1, fromY: y1, toX: x2, toY: y2)
        flashIndicatorIfRunning()
        JSONOutput.print(["status": "ok", "message": "Dragged from \(Int(x1)),\(Int(y1)) to \(Int(x2)),\(Int(y2))"], json: json)
    }
}

struct Scroll: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scroll up/down/left/right")

    @Argument(help: "Direction: up, down, left, right") var direction: String
    @Argument(help: "Amount (clicks)") var amount: Int32 = 3
    @Flag(name: .long) var json = false

    func run() {
        MouseController.scroll(direction: direction, amount: amount)
        flashIndicatorIfRunning()
        JSONOutput.print(["status": "ok", "message": "Scrolled \(direction) by \(amount)"], json: json)
    }
}

// MARK: - Mouse Controller

enum MouseController {
    static func click(x: Double, y: Double) {
        let point = CGPoint(x: x, y: y)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func doubleClick(x: Double, y: Double) {
        let point = CGPoint(x: x, y: y)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.setIntegerValueField(.mouseEventClickState, value: 2)
        up?.setIntegerValueField(.mouseEventClickState, value: 2)
        // First click
        let d1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let u1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        d1?.post(tap: .cghidEventTap)
        u1?.post(tap: .cghidEventTap)
        // Second click
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func rightClick(x: Double, y: Double) {
        let point = CGPoint(x: x, y: y)
        let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)
        let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func move(x: Double, y: Double) {
        let point = CGPoint(x: x, y: y)
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    static func drag(fromX: Double, fromY: Double, toX: Double, toY: Double) {
        let start = CGPoint(x: fromX, y: fromY)
        let end = CGPoint(x: toX, y: toY)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(50000)
        let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: end, mouseButton: .left)
        drag?.post(tap: .cghidEventTap)
        usleep(50000)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)
        up?.post(tap: .cghidEventTap)
    }

    static func scroll(direction: String, amount: Int32) {
        var dy: Int32 = 0, dx: Int32 = 0
        switch direction.lowercased() {
        case "up": dy = amount
        case "down": dy = -amount
        case "left": dx = amount
        case "right": dx = -amount
        default: break
        }
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
    }
}
