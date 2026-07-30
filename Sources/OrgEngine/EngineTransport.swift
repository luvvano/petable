import Foundation

/// Транспорт к движку конвейера: команды Wire-конвертом, события —
/// колбэком. Две реализации: демон по XPC (П0) и in-process fallback —
/// честное состояние «движок в приложении, демон не установлен»
/// (матрица 4A), не тихая деградация.
public protocol EngineTransport: Sendable {
    /// Отправить команду (WireEnvelope как Data).
    func send(_ data: Data) async throws
    /// Подписка на события движка (WireEnvelope как Data).
    func subscribe(_ sink: @escaping @Sendable (Data) -> Void) async
    /// Живо ли соединение и какая версия протокола на той стороне.
    func handshake() async -> Int?
}

/// Движок внутри процесса приложения: DaemonCore без XPC. Конвейер
/// работает, пока открыто приложение; вынос в демона — смена транспорта,
/// не переписывание (граница 1A соблюдена).
public struct InProcessTransport: EngineTransport {
    public let core: DaemonCore

    public init(core: DaemonCore) {
        self.core = core
    }

    public func send(_ data: Data) async throws {
        try await core.handle(data)
    }

    public func subscribe(_ sink: @escaping @Sendable (Data) -> Void) async {
        await core.subscribe(sink)
    }

    public func handshake() async -> Int? {
        WireEnvelope.protocolVersion
    }
}

/// Клиент демона: NSXPCConnection к Mach-сервису LaunchAgent.
/// Приложение экспортирует EventSink на своём коннекте — демон пушит
/// события в него (1A).
public final class XPCTransport: NSObject, EngineTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "petable.xpc-transport")
    private var connection: NSXPCConnection?
    private var sink: (@Sendable (Data) -> Void)?

    override public init() {
        super.init()
    }

    private func ensureConnection() -> NSXPCConnection {
        queue.sync {
            if let connection { return connection }
            let fresh = NSXPCConnection(machServiceName: petableDaemonMachService)
            fresh.remoteObjectInterface = NSXPCInterface(with: PetableDaemonXPC.self)
            fresh.exportedInterface = NSXPCInterface(with: PetableEventSinkXPC.self)
            fresh.exportedObject = ClientSink { [weak self] data in
                self?.sink?(data)
            }
            fresh.invalidationHandler = { [weak self] in
                self?.queue.sync { self?.connection = nil }
            }
            fresh.resume()
            connection = fresh
            return fresh
        }
    }

    private var proxy: PetableDaemonXPC? {
        ensureConnection().remoteObjectProxy as? PetableDaemonXPC
    }

    public func send(_ data: Data) async throws {
        guard let proxy else { throw TransportError.daemonUnavailable }
        let reply: Data? = await withCheckedContinuation { continuation in
            proxy.send(data) { continuation.resume(returning: $0) }
        }
        if let reply,
           let (type, envelope) = try? WireEnvelope.unpack(reply), type == .attention,
           let message = try? envelope.payload(as: String.self) {
            throw TransportError.daemonError(message)
        }
    }

    public func subscribe(_ sink: @escaping @Sendable (Data) -> Void) async {
        queue.sync { self.sink = sink }
        _ = ensureConnection()
    }

    /// nil — демон недоступен (не установлен / не отвечает): вызывающий
    /// падает на InProcessTransport с баннером. Таймаут 800 мс — мёртвый
    /// Mach-сервис не отвечает вовсе, ждать нечего.
    public func handshake() async -> Int? {
        guard let proxy else { return nil }
        let boxed = UncheckedSendableBox(proxy)
        return await withTaskGroup(of: Int?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    boxed.value.handshake { continuation.resume(returning: $0) }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 800_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    public enum TransportError: Error, Equatable {
        case daemonUnavailable
        case daemonError(String)
    }
}

/// EventSink приложения на клиентском коннекте.
private final class ClientSink: NSObject, PetableEventSinkXPC {
    private let handler: @Sendable (Data) -> Void

    init(handler: @escaping @Sendable (Data) -> Void) {
        self.handler = handler
    }

    func receive(_ data: Data) {
        handler(data)
    }
}
