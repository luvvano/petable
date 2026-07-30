import Foundation

/// ObjC-граница XPC (решение 1A): ровно два метода с Data — вся
/// типизация в Wire-конверте. Протокол общий для демона и приложения.
@objc public protocol PetableDaemonXPC {
    /// Команда приложение → демон (WireEnvelope как Data).
    func send(_ data: Data, withReply reply: @escaping (Data?) -> Void)
    /// Рукопожатие версий протокола (П0): демон отвечает своей версией.
    func handshake(withReply reply: @escaping (Int) -> Void)
}

/// EventSink приложения: демон пушит события (WireEnvelope как Data).
@objc public protocol PetableEventSinkXPC {
    func receive(_ data: Data)
}

/// Имя Mach-сервиса LaunchAgent.
public let petableDaemonMachService = "com.egorproskurin.petable.daemon"

/// Серверная сторона XPC: оборачивает DaemonCore. Клиент экспортирует
/// PetableEventSinkXPC на своём коннекте — демон пушит события в него.
public final class DaemonXPCDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let core: DaemonCore

    public init(core: DaemonCore) {
        self.core = core
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PetableDaemonXPC.self)
        connection.remoteObjectInterface = NSXPCInterface(with: PetableEventSinkXPC.self)
        let sink = connection.remoteObjectProxy as? PetableEventSinkXPC
        connection.exportedObject = DaemonXPCServer(core: core, sink: sink)
        connection.resume()
        return true
    }
}

/// Явный перенос не-Sendable значения через границу изоляции.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

final class DaemonXPCServer: NSObject, PetableDaemonXPC, @unchecked Sendable {
    private let core: DaemonCore

    init(core: DaemonCore, sink: PetableEventSinkXPC?) {
        self.core = core
        super.init()
        if let sink {
            // XPC-прокси потокобезопасен по контракту NSXPCConnection,
            // Sendable-аннотации у @objc-протокола нет — переносим явно.
            let box = UncheckedSendableBox(sink)
            Task { await core.subscribe { data in box.value.receive(data) } }
        }
    }

    func send(_ data: Data, withReply reply: @escaping (Data?) -> Void) {
        let boxed = UncheckedSendableBox(reply)
        Task {
            do {
                try await core.handle(data)
                boxed.value(nil)
            } catch {
                let message = "\(error)"
                boxed.value(try? WireEnvelope.pack(.attention, message))
            }
        }
    }

    func handshake(withReply reply: @escaping (Int) -> Void) {
        reply(WireEnvelope.protocolVersion)
    }
}
