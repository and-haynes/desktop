//  LoopbackServer.swift
//  A few dozen lines of HTTP on 127.0.0.1, so a test can give a `WKWebView` a
//  real origin.
//
//  Needed for exactly one thing that cannot be faked: proving that
//  `declarativeNetRequest` **blocked** a request rather than that the request
//  merely failed. Those are indistinguishable against a hostname that does not
//  resolve — every probe "fails" — so the only honest test is one where the
//  resource genuinely exists and is genuinely served, and then does not
//  arrive.
//
//  `Tests/Fixtures/serve.py` does the same job for the manual AutoFill check,
//  but it is a separate process somebody has to remember to start. This runs
//  inside the test, on an ephemeral port, and dies with it.
//
//  Plain HTTP: the simulator reaches loopback without TLS, `NSAllowsLocalNetworking`
//  is already set for the LAN work, and a self-signed certificate would add a
//  trust dance that has nothing to do with what is being measured.

import Foundation
import Network

final class LoopbackServer: @unchecked Sendable {

    struct Response {
        var status: Int = 200
        var contentType: String = "text/html; charset=utf-8"
        var body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "zen.loopback")
    private let lock = NSLock()
    private var routes: [String: Response] = [:]
    private var connections: [NWConnection] = []
    /// Paths that were actually requested, so a test can tell "blocked" from
    /// "asked for and refused".
    private(set) var requestedPaths: [String] = []

    let port: UInt16

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Port 0: the kernel picks a free one, so two tests can run at once.
        listener = try NWListener(using: parameters, on: 0)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak listener] _ in _ = listener }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
            let assigned = listener.port?.rawValue
        else {
            listener.cancel()
            throw NSError(
                domain: "LoopbackServer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "the listener never came up"])
        }
        port = assigned
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    deinit { stop() }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        for connection in open { connection.cancel() }
    }

    var origin: String { "http://127.0.0.1:\(port)" }

    func url(_ path: String) -> URL {
        URL(string: origin + path)!
    }

    func serve(_ path: String, _ response: Response) {
        lock.lock()
        routes[path] = response
        lock.unlock()
    }

    func serve(_ path: String, html: String) {
        serve(path, Response(body: Data(html.utf8)))
    }

    func serve(_ path: String, javascript: String) {
        serve(
            path,
            Response(contentType: "application/javascript; charset=utf-8", body: Data(javascript.utf8)))
    }

    /// The probe page: one control resource and one the blocker's rule matches.
    var probePage: String {
        """
        <!doctype html><html><body><h1>Probe</h1>
        <script src="/allowed.js"></script>
        <script src="/zen-blocked-resource.js"></script>
        </body></html>
        """
    }

    /// Forget what has been asked for so far, so that "did it arrive *this*
    /// time" is a fresh question on the next load. A probe that runs more than
    /// once has to do this between passes or the first pass's requests answer
    /// for the last one.
    func resetRequests() {
        lock.lock()
        requestedPaths = []
        lock.unlock()
    }

    func wasRequested(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestedPaths.contains(path)
    }

    // MARK: Plumbing

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    /// Headers only: nothing here serves a request with a body, and reading
    /// until the blank line is the whole of what HTTP/1.0 needs.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let text = String(data: accumulated, encoding: .utf8),
                text.contains("\r\n\r\n") || text.contains("\n\n")
            {
                self.respond(to: text, on: connection)
                return
            }
            if isComplete || error != nil || accumulated.count >= 8192 {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: accumulated)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let line = request.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let fields = line.split(separator: " ")
        let target = fields.count > 1 ? String(fields[1]) : "/"
        // The query is the cache-buster a probe adds; route on the path.
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target

        lock.lock()
        requestedPaths.append(path)
        let response = routes[path]
        lock.unlock()

        let resolved =
            response
            ?? Response(status: 404, contentType: "text/plain", body: Data("not found".utf8))
        var head = "HTTP/1.1 \(resolved.status) \(resolved.status == 200 ? "OK" : "Not Found")\r\n"
        head += "Content-Type: \(resolved.contentType)\r\n"
        head += "Content-Length: \(resolved.body.count)\r\n"
        // Nothing here should ever be answered from a cache; a second probe
        // that reads a cached copy would report the opposite of the truth.
        head += "Cache-Control: no-store\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(resolved.body)
        connection.send(
            content: payload,
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
