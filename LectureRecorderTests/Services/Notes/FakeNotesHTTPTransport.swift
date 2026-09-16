@testable import LectureRecorder
import Foundation

actor FakeNotesHTTPTransport: NotesHTTPTransport {
    enum Behavior: Sendable {
        case response(NotesHTTPResponse)
        case failure(FakeTransportFailure)
        case waitForCancellation
    }

    private var behaviors: [Behavior]
    private(set) var requests: [URLRequest] = []

    init(behaviors: [Behavior]) {
        self.behaviors = behaviors
    }

    func send(_ request: URLRequest) async throws -> NotesHTTPResponse {
        requests.append(request)
        guard !behaviors.isEmpty else { throw FakeTransportFailure.noConfiguredResponse }
        let behavior = behaviors.removeFirst()
        switch behavior {
        case .response(let response):
            return response
        case .failure(let error):
            throw error
        case .waitForCancellation:
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}

enum FakeTransportFailure: LocalizedError, Sendable {
    case offline
    case noConfiguredResponse

    var errorDescription: String? {
        switch self {
        case .offline: return "offline"
        case .noConfiguredResponse: return "no configured response"
        }
    }
}
