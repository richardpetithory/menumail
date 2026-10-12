import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect.
final class LoopbackReceiver {
    private let listener: NWListener
    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            portContinuation = continuation
            // Handlers are delivered on .main (see start(queue:)), so assuming main-actor isolation is safe.
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.stateChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.handle(connection) }
            }
            listener.start(queue: .main)
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port?.rawValue {
                portContinuation?.resume(returning: port)
                portContinuation = nil
            }
        case .failed(let error):
            portContinuation?.resume(throwing: error)
            portContinuation = nil
        default:
            break
        }
    }

    /// Waits for the browser to hit the redirect URI and returns its query parameters.
    func waitForCallback(timeout: Duration = .seconds(300)) async throws -> [String: String] {
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(.failure(MailError.cancelled))
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { callbackContinuation = $0 }
    }

    func cancel() {
        finish(.failure(MailError.cancelled))
    }

    private func finish(_ result: Result<[String: String], Error>) {
        callbackContinuation?.resume(with: result)
        callbackContinuation = nil
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated { self?.respond(to: data, on: connection) }
        }
    }

    private func respond(to data: Data?, on connection: NWConnection) {
        let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let items = URLComponents(string: "http://localhost\(path)")?.queryItems ?? []
        let params = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })

        let isCallback = params["code"] != nil || params["error"] != nil
        let body = isCallback
            ? "<html><body style='font-family:-apple-system;padding:40px'><h2>MenuMail is signed in.</h2>You can close this tab.</body></html>"
            : "Not found"
        let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        if isCallback { finish(.success(params)) }
    }
}
