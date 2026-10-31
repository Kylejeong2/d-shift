import Foundation

/// The HTTP streaming loop shared by the Claude and OpenAI clients: POST, surface non-200 bodies as errors, and map
/// each SSE line to zero or more events.
enum ServerSentEvents {
    static func stream<Event>(
        _ makeRequest: @escaping () throws -> URLRequest,
        httpError: @escaping (_ status: Int, _ body: String) -> Error,
        parse: @escaping (String) throws -> [Event]
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: makeRequest())
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw httpError(http.statusCode, body)
                    }
                    for try await line in bytes.lines {
                        for event in try parse(line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The JSON object on a `data: ` line, or nil for comments, event names, and other non-data lines.
    static func payload(_ line: String) throws -> JSON? {
        guard line.hasPrefix("data: ") else { return nil }
        return try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? JSON
    }
}
