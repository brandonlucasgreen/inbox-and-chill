import Foundation

/// One decoded Socket Mode envelope.
///
/// Slack wraps everything it pushes down the socket in an envelope:
/// `hello` (handshake), `disconnect` (server is retiring this connection),
/// and the payload-carrying kinds — `events_api`, `interactive`,
/// `slash_commands`. Only `hello`/`disconnect` lack an `envelope_id`;
/// everything else must be acked.
struct SlackEnvelope: Sendable {
    var type: String
    var envelopeID: String?
    /// `"link_disabled"`, `"warning"`, `"refresh_requested"` on `disconnect`.
    var reason: String?
    var payload: SlackJSON
}

/// A live Socket Mode WebSocket.
///
/// `URLSessionWebSocketTask` and its `Message` enum are both `Sendable` in the
/// macOS SDK, so this can be a plain `Sendable` struct handed between the
/// connector actor and its child tasks with no lock or wrapper actor.
struct SlackSocket: Sendable {
    private let task: URLSessionWebSocketTask

    /// Exchanges an app-level `xapp-` token for a single-use WebSocket URL and
    /// connects. Requires the app to have Socket Mode enabled and the token to
    /// carry `connections:write`.
    static func open(appToken: String) async throws -> SlackSocket {
        let response = try await SlackAPI(token: appToken).call("apps.connections.open")
        guard let urlString = response["url"].nonEmptyString,
            let url = URL(string: urlString)
        else {
            throw SlackError(
                errorDescription: "Slack: apps.connections.open returned no socket URL.")
        }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        return SlackSocket(task: task)
    }

    /// Awaits the next envelope, skipping frames we can't decode.
    ///
    /// `URLSessionWebSocketTask.receive()` is not cancellation-aware, so a
    /// pending read would otherwise pin this task alive until Slack happened
    /// to send something. The cancellation handler closes the socket, which
    /// makes the in-flight read fail promptly.
    func nextEnvelope() async throws -> SlackEnvelope {
        while true {
            try Task.checkCancellation()
            let message = try await withTaskCancellationHandler {
                try await task.receive()
            } onCancel: {
                task.cancel(with: .goingAway, reason: nil)
            }

            let data: Data
            switch message {
            case .data(let payload): data = payload
            case .string(let text): data = Data(text.utf8)
            @unknown default: continue
            }

            guard let root = try? JSONDecoder().decode(SlackJSON.self, from: data),
                let type = root["type"].nonEmptyString
            else { continue }

            return SlackEnvelope(
                type: type,
                envelopeID: root["envelope_id"].nonEmptyString,
                reason: root["reason"].nonEmptyString,
                payload: root["payload"])
        }
    }

    /// Acks an envelope. Slack expects this within 3 seconds or it redelivers,
    /// so callers should ack before doing any work with the payload.
    func ack(_ envelopeID: String) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["envelope_id": envelopeID], options: [])
        try await task.send(.string(String(decoding: body, as: UTF8.self)))
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
