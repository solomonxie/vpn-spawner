import Foundation
import Network

final class SubscriptionServer {
    static let shared = SubscriptionServer()
    static let port: UInt16 = 8964

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "vpn.subscription.server")
    private var subscriptionContent: String = ""

    var subscriptionURLString: String {
        "http://127.0.0.1:\(Self.port)/sub"
    }

    func start(with ssURI: String) {
        stop()
        subscriptionContent = Data(ssURI.utf8).base64EncodedString()

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener?.start(queue: queue)
        } catch {
            // Port may already be in use
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] _, _, _, _ in
            guard let self else { return }
            let body = self.subscriptionContent
            let response = [
                "HTTP/1.1 200 OK",
                "Content-Type: text/plain; charset=utf-8",
                "Content-Length: \(body.utf8.count)",
                "Connection: close",
                "",
                body
            ].joined(separator: "\r\n")

            connection.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        }
    }
}
