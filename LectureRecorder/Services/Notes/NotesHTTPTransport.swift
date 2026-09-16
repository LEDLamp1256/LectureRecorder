import Foundation

/// The deliberately narrow HTTP boundary used by the Notes provider adapter.
/// It owns no retry, authentication, persistence, or application lifecycle
/// policy; tests replace it with a deterministic in-memory transport.
nonisolated protocol NotesHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> NotesHTTPResponse
}

nonisolated struct NotesHTTPResponse: Sendable, Equatable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data

    func headerValue(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

nonisolated enum NotesHTTPTransportError: LocalizedError, Sendable, Equatable {
    case nonHTTPResponse

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            return "The Notes provider returned a non-HTTP response."
        }
    }
}

nonisolated struct URLSessionNotesHTTPTransport: NotesHTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> NotesHTTPResponse {
        try Task.checkCancellation()
        let (body, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw NotesHTTPTransportError.nonHTTPResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return NotesHTTPResponse(statusCode: http.statusCode, headers: headers, body: body)
    }
}
