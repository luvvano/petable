import SwiftUI
import AppKit

/// Клавиши режима навигации (узел выделен, TextField не в фокусе).
enum CanvasKey {
    case tab, enter, cmdReturn, escape, delete
    case left, right, up, down
    case cmdLeft, cmdRight
    /// ⌥← / ⌥→ — свернуть и развернуть цепочку работ уровня
    /// (та же пара клавиш, что сворачивает ветку в списках macOS).
    case optionLeft, optionRight
    /// ⌘= — синоним ⌘+ (zoom in без Shift, как во всех приложениях Apple).
    case cmdPlus
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
    /// Двойной клик по пустому месту — координаты вью.
    let onDoubleClickEmpty: (CGPoint) -> Void
    /// Позиция курсора в координатах вью; nil — курсор ушёл с канваса.
    /// SwiftUI-ховер здесь не работает: NSView перехватывает mouseMoved,
    /// поэтому трекинг живёт в самом NSView.
    let onMouseMove: (CGPoint?) -> Void
    let focusBridge: CanvasFocusBridge

    func makeNSView(context: Context) -> EventCatcherView {
        let view = EventCatcherView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: EventCatcherView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: EventCatcherView) {
        view.onKey = onKey
        view.onPan = onPan
        view.onZoom = onZoom
        view.onClickEmpty = onClickEmpty
        view.onDoubleClickEmpty = onDoubleClickEmpty
        view.onMouseMove = onMouseMove
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
    var onDoubleClickEmpty: ((CGPoint) -> Void)?
    var onMouseMove: ((CGPoint?) -> Void)?

    /// Суммарный сдвиг текущего drag — отличаем клик от панорамирования.
    private var dragDistance: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // inVisibleRect — область следует за размером вью сама.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMove?(cursorLocation(event))
    }

    override func mouseExited(with event: NSEvent) {
        onMouseMove?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragDistance = 0
        if event.clickCount == 2 {
            onDoubleClickEmpty?(cursorLocation(event))
        }
    }

    /// Drag по пустому месту = панорамирование (как в Freeform/Figma).
    /// Курсор — «сжатая рука» на время перетаскивания.
    override func mouseDragged(with event: NSEvent) {
        dragDistance += abs(event.deltaX) + abs(event.deltaY)
        if dragDistance > 4 {
            NSCursor.closedHand.set()
            onPan?(CGSize(width: event.deltaX, height: event.deltaY))
        }
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.arrow.set()
        // Клик без движения — deselect; после панорамирования выделение живёт.
        if dragDistance <= 4, event.clickCount <= 1 {
            onClickEmpty?()
        }
        dragDistance = 0
    }

    override func keyDown(with event: NSEvent) {
        guard let key = canvasKey(for: event), onKey?(key) == true else {
            super.keyDown(with: event)
            return
        }
    }

    private func canvasKey(for event: NSEvent) -> CanvasKey? {
        let cmd = event.modifierFlags.contains(.command)
        let option = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 48: return .tab
        case 24, 69: return cmd ? .cmdPlus : nil // "=" и keypad "+"
        case 36: return cmd ? .cmdReturn : .enter
        case 53: return .escape
        case 51, 117: return .delete // backspace и forward-delete
        case 123: return cmd ? .cmdLeft : (option ? .optionLeft : .left)
        case 124: return cmd ? .cmdRight : (option ? .optionRight : .right)
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
