import Foundation
import Network

final class WebhookServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.allmyagents.webhook-server")

    init(port: UInt16 = 9876) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[AllMyAgents] Webhook server listening on port \(self.listener.port!)")
            case .failed(let error):
                print("[AllMyAgents] Server failed: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            if let error {
                print("[AllMyAgents] Receive error: \(error)")
                connection.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            self?.processRequest(data: data, connection: connection)
        }
    }

    private func processRequest(data: Data, connection: NWConnection) {
        guard let request = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, status: "400 Bad Request", body: #"{"error":"invalid encoding"}"#)
            return
        }

        let parts = request.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: "400 Bad Request", body: #"{"error":"malformed request"}"#)
            return
        }

        let headerSection = parts[0]
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")

        let firstLine = headerSection.components(separatedBy: "\r\n").first ?? ""
        guard firstLine.hasPrefix("POST /webhook") else {
            sendResponse(connection: connection, status: "404 Not Found", body: #"{"error":"not found"}"#)
            return
        }

        guard let bodyData = body.data(using: .utf8) else {
            sendResponse(connection: connection, status: "400 Bad Request", body: #"{"error":"invalid body"}"#)
            return
        }

        do {
            let payload = try JSONDecoder().decode(WebhookPayload.self, from: bodyData)
            let notification = AgentNotification(from: payload)

            Task { @MainActor in
                NotificationStore.shared.upsertFromWebhook(notification)
            }

            sendResponse(connection: connection, status: "200 OK", body: #"{"ok":true}"#)
        } catch {
            print("[AllMyAgents] JSON parse error: \(error)")
            sendResponse(connection: connection, status: "422 Unprocessable Entity", body: #"{"error":"invalid json"}"#)
        }
    }

    private func sendResponse(connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
