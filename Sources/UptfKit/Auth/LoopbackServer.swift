public import Foundation
import Network

/// A one-shot HTTP server on `127.0.0.1` (ephemeral port) that receives the OAuth redirect
/// (RFC 8252 §7.3). It only answers `GET /callback`, ignores callbacks whose `state` does not
/// match, and closes after the first valid one (or after `timeout`).
public final class LoopbackServer: @unchecked Sendable {
    private let expectedState: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.smilemasktechnology.uploadthefile.loopback")

    // All mutable state below is only touched on `queue`.
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var startContinuation: CheckedContinuation<UInt16, any Error>?
    private var waiter: CheckedContinuation<String, any Error>?
    private var result: Result<String, UptfError>?
    private var accepted = false
    private var timer: DispatchWorkItem?

    public init(expectedState: String, timeout: TimeInterval = 300) {
        self.expectedState = expectedState
        self.timeout = timeout
    }

    /// Starts listening and returns the port. Redirect URI: `http://127.0.0.1:<port>/callback`.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    self.startContinuation = continuation
                    listener.stateUpdateHandler = { [self] state in stateChanged(state) }
                    listener.newConnectionHandler = { [self] connection in handle(connection) }
                    listener.start(queue: self.queue)
                    let timer = DispatchWorkItem { [self] in
                        finish(.failure(.signInFailed("Timed out waiting for the browser (\(Int(timeout / 60)) minutes).")))
                    }
                    self.timer = timer
                    self.queue.asyncAfter(deadline: .now() + self.timeout, execute: timer)
                } catch {
                    continuation.resume(throwing: UptfError.signInFailed("Couldn't start sign-in on this Mac: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// Waits for the redirect and returns the authorization code.
    public func waitForCode() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(with: result.mapError { $0 as any Error })
                    } else {
                        self.waiter = continuation
                    }
                }
            }
        } onCancel: {
            stop()
        }
    }

    /// Stops listening. A pending `waitForCode()` fails.
    public func stop() {
        queue.async { [self] in finish(.failure(.signInFailed("Cancelled."))) }
    }

    // MARK: - Queue-confined internals

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue ?? 0
            startContinuation?.resume(returning: port)
            startContinuation = nil
        case .failed(let error):
            if let startContinuation {
                startContinuation.resume(throwing: UptfError.signInFailed("Local listener failed: \(error.localizedDescription)"))
                self.startContinuation = nil
            }
            finish(.failure(.signInFailed("Local listener failed: \(error.localizedDescription)")))
        default:
            break
        }
    }

    private func finish(_ outcome: Result<String, UptfError>) {
        guard result == nil else { return }
        result = outcome
        timer?.cancel()
        timer = nil
        listener?.cancel()
        listener = nil
        if let startContinuation {
            startContinuation.resume(throwing: UptfError.signInFailed("Cancelled."))
            self.startContinuation = nil
        }
        if let waiter {
            waiter.resume(with: outcome.mapError { $0 as any Error })
            self.waiter = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Drop connections that never send a request.
        queue.asyncAfter(deadline: .now() + 15) { connection.cancel() }
        receive(on: connection, buffered: Data())
    }

    private static let headTerminator = Data("\r\n\r\n".utf8)

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, isComplete, error in
            var buffer = buffered
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Self.headTerminator) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                process(head: head, on: connection)
            } else if error != nil || isComplete || buffer.count > 16 * 1024 {
                connection.cancel()
            } else {
                receive(on: connection, buffered: buffer)
            }
        }
    }

    private func process(head: String, on connection: NWConnection) {
        guard let request = HTTPRequestLine.parse(head) else {
            return respond(connection, status: "400 Bad Request", page: .invalid)
        }
        // Only a browser on this machine talking to the address we handed out may speak to us.
        if let host = request.host, host != "127.0.0.1:\(port)" {
            return respond(connection, status: "400 Bad Request", page: .invalid)
        }
        guard request.method == "GET", let callback = AuthorizationCallback.parse(target: request.target) else {
            return respond(connection, status: "404 Not Found", page: .notFound)
        }
        guard !accepted else {
            return respond(connection, status: "404 Not Found", page: .notFound)
        }
        do {
            let code = try callback.validated(expectedState: expectedState)
            accepted = true
            respond(connection, status: "200 OK", page: .success) { [self] in finish(.success(code)) }
        } catch .denied(let error, let description) {
            accepted = true
            let message = CallbackError.denied(error: error, description: description).localizedDescription
            respond(connection, status: "200 OK", page: .denied) { [self] in
                finish(.failure(.signInFailed(message)))
            }
        } catch {
            // Wrong state or no code: not our redirect. Keep waiting for the real one.
            respond(connection, status: "400 Bad Request", page: .invalid)
        }
    }

    enum Page {
        case success, denied, invalid, notFound

        var html: String {
            let (title, body): (String, String)
            switch self {
            case .success:
                (title, body) = ("You're signed in", "You can close this tab and go back to Upload the File.")
            case .denied:
                (title, body) = ("Sign-in cancelled", "Nothing was changed. You can close this tab.")
            case .invalid:
                (title, body) = ("Invalid sign-in response", "This request did not belong to the sign-in in progress.")
            case .notFound:
                (title, body) = ("Not found", "")
            }
            return """
                <!doctype html><html lang="en"><head><meta charset="utf-8">\
                <meta name="viewport" content="width=device-width,initial-scale=1"><title>\(title)</title>\
                <style>body{font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;\
                min-height:90vh;margin:0;color:#1d1d1f}main{text-align:center;padding:24px}\
                h1{font-size:22px;margin:0 0 8px}p{margin:0;color:#6e6e73}\
                @media(prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}p{color:#a1a1a6}}</style>\
                </head><body><main><h1>\(title)</h1><p>\(body)</p></main></body></html>
                """
        }
    }

    private func respond(
        _ connection: NWConnection, status: String, page: Page, then: (@Sendable () -> Void)? = nil
    ) {
        let body = Data(page.html.utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(
            content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
                then?()
            })
    }
}
