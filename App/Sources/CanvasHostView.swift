import SwiftUI
import AppKit

/// Клавиши режима навигации (узел выделен, TextField не в фокусе).
enum CanvasKey {
    case tab, enter, cmdReturn, escape, delete
    case left, right, up, down
    case cmdLeft, cmdRight
}

/// Единая точка входа событий канваса: NSView — first responder своего окна,
/// локально получает keyDown / scrollWheel / magnify. Никаких глобальных
/// NSEvent-мониторов (ловят чужие окна DocumentGroup и дерутся с фокусом
/// TextField). Режим редактирования — штатно: TextField забрал фокус,
/// этот вью событий не видит.
struct CanvasHostView: NSViewRepresentable {
    let onKey: (CanvasKey) -> Bool
    let onPan: (CGSize) -> Void
    /// (множитель, позиция курсора в координатах вью) — zoom вокруг курсора.
    let onZoom: (CGFloat, CGPoint) -> Void
    let onClickEmpty: () -> Void
    let focusBridge: CanvasFocusBridge

    func makeNSView(context: Context) -> EventCatcherView {
        let view = EventCatcherView()
        view.onKey = onKey
        view.onPan = onPan
        view.onZoom = onZoom
        view.onClickEmpty = onClickEmpty
        focusBridge.view = view
        return view
    }

    func updateNSView(_ view: EventCatcherView, context: Context) {
        view.onKey = onKey
        view.onPan = onPan
        view.onZoom = onZoom
        view.onClickEmpty = onClickEmpty
        focusBridge.view = view
    }
}

/// Мост «верни фокус канвасу после закрытия инлайн-редактора».
@MainActor
final class CanvasFocusBridge: ObservableObject {
    weak var view: NSView?

    func focusCanvas() {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
    }
}

final class EventCatcherView: NSView {
    var onKey: ((CanvasKey) -> Bool)?
    var onPan: ((CGSize) -> Void)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var onClickEmpty: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onClickEmpty?()
    }

    override func keyDown(with event: NSEvent) {
        guard let key = canvasKey(for: event), onKey?(key) == true else {
            super.keyDown(with: event)
            return
        }
    }

    private func canvasKey(for event: NSEvent) -> CanvasKey? {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 48: return .tab
        case 36: return cmd ? .cmdReturn : .enter
        case 53: return .escape
        case 51: return .delete
        case 123: return cmd ? .cmdLeft : .left
        case 124: return cmd ? .cmdRight : .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⌘-скролл = zoom вокруг курсора.
            let factor = 1 + event.scrollingDeltaY / 200
            onZoom?(factor, cursorLocation(event))
        } else {
            // Двухпальцевый скролл = pan.
            onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        }
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification, cursorLocation(event))
    }

    private func cursorLocation(_ event: NSEvent) -> CGPoint {
        var point = convert(event.locationInWindow, from: nil)
        // SwiftUI-контент поверх — top-left система координат.
        if !isFlipped { point.y = bounds.height - point.y }
        return point
    }

    override var isFlipped: Bool { true }
}
