import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleTasksAPIError.invalidResponse
        }
        return (data, httpResponse)
    }
}

public enum GoogleTasksAPIError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int, String)
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Resposta HTTP invalida."
        case let .httpStatus(status, body):
            "Google Tasks respondeu \(status): \(body)"
        case .missingToken:
            "Faca login para sincronizar com o Google Tasks."
        }
    }
}

public enum GoogleTasksPatchValue: Encodable, Sendable {
    case string(String)
    case null

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct GoogleTasksAPI: Sendable {
    public var baseURL = URL(string: "https://tasks.googleapis.com")!
    public var transport: HTTPTransport
    public var accessTokenProvider: @Sendable () async throws -> String

    public init(
        baseURL: URL = URL(string: "https://tasks.googleapis.com")!,
        transport: HTTPTransport = URLSessionTransport(),
        accessTokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.accessTokenProvider = accessTokenProvider
    }

    public func listTaskLists() async throws -> [GoogleTaskList] {
        var allItems: [GoogleTaskList] = []
        var pageToken: String?

        repeat {
            var components = components(path: "/tasks/v1/users/@me/lists")
            components.queryItems = [
                URLQueryItem(name: "maxResults", value: "100"),
                pageToken.map { URLQueryItem(name: "pageToken", value: $0) }
            ].compactMap { $0 }

            let page: TaskListPage = try await send(.get, url: components.url!)
            allItems.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil

        return allItems
    }

    public func insertTaskList(title: String) async throws -> GoogleTaskList {
        try await send(.post, path: "/tasks/v1/users/@me/lists", body: ["title": title])
    }

    public func patchTaskList(_ listID: String, title: String) async throws -> GoogleTaskList {
        try await send(.patch, path: "/tasks/v1/users/@me/lists/\(listID.urlPathEncoded)", body: ["title": title])
    }

    public func deleteTaskList(_ listID: String) async throws {
        let _: EmptyResponse = try await send(.delete, path: "/tasks/v1/users/@me/lists/\(listID.urlPathEncoded)")
    }

    public func listTasks(in listID: String, showCompleted: Bool = true, showHidden: Bool = true) async throws -> [GoogleTask] {
        var allItems: [GoogleTask] = []
        var pageToken: String?

        repeat {
            var components = components(path: "/tasks/v1/lists/\(listID.urlPathEncoded)/tasks")
            components.queryItems = [
                URLQueryItem(name: "maxResults", value: "100"),
                URLQueryItem(name: "showCompleted", value: showCompleted ? "true" : "false"),
                URLQueryItem(name: "showHidden", value: showHidden ? "true" : "false"),
                pageToken.map { URLQueryItem(name: "pageToken", value: $0) }
            ].compactMap { $0 }

            let page: TaskPage = try await send(.get, url: components.url!)
            allItems.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil

        return allItems
    }

    public func insertTask(in listID: String, title: String, parent: String? = nil, previous: String? = nil) async throws -> GoogleTask {
        var components = components(path: "/tasks/v1/lists/\(listID.urlPathEncoded)/tasks")
        components.queryItems = [
            parent.map { URLQueryItem(name: "parent", value: $0) },
            previous.map { URLQueryItem(name: "previous", value: $0) }
        ].compactMap { $0 }
        return try await send(.post, url: components.url!, body: ["title": title])
    }

    public func patchTask(_ taskID: String, in listID: String, payload: [String: String?]) async throws -> GoogleTask {
        let body = payload.compactMapValues { $0 }
        return try await send(.patch, path: "/tasks/v1/lists/\(listID.urlPathEncoded)/tasks/\(taskID.urlPathEncoded)", body: body)
    }

    public func patchTask(_ taskID: String, in listID: String, payload: [String: GoogleTasksPatchValue]) async throws -> GoogleTask {
        try await send(.patch, path: "/tasks/v1/lists/\(listID.urlPathEncoded)/tasks/\(taskID.urlPathEncoded)", body: payload)
    }

    public func setTaskCompleted(_ taskID: String, in listID: String, completed: Bool) async throws -> GoogleTask {
        try await patchTask(taskID, in: listID, payload: [
            "status": completed ? TaskStatus.completed.rawValue : TaskStatus.needsAction.rawValue
        ])
    }

    public func deleteTask(_ taskID: String, in listID: String) async throws {
        let _: EmptyResponse = try await send(.delete, path: "/tasks/v1/lists/\(listID.urlPathEncoded)/tasks/\(taskID.urlPathEncoded)")
    }

    public func moveTask(_ taskID: String, from listID: String, parent: String? = nil, previous: String? = nil, destinationListID: String? = nil) async throws -> GoogleTask {
        var components = components(path: "/tasks/v1/lists/\(listID.urlPathEncoded)/tasks/\(taskID.urlPathEncoded)/move")
        components.queryItems = [
            parent.map { URLQueryItem(name: "parent", value: $0) },
            previous.map { URLQueryItem(name: "previous", value: $0) },
            destinationListID.map { URLQueryItem(name: "destinationTasklist", value: $0) }
        ].compactMap { $0 }
        return try await send(.post, url: components.url!)
    }

    private func send<T: Decodable>(_ method: HTTPMethod, path: String, body: Encodable? = nil) async throws -> T {
        try await send(method, url: components(path: path).url!, body: body)
    }

    private func send<T: Decodable>(_ method: HTTPMethod, url: URL, body: Encodable? = nil) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(try await accessTokenProvider())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = try JSONEncoder.googleTasks.encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GoogleTasksAPIError.httpStatus(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }

        return try JSONDecoder.googleTasks.decode(T.self, from: data)
    }

    private func components(path: String) -> URLComponents {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        return components
    }
}

private enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

private struct EmptyResponse: Decodable {}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: Encodable) {
        encodeValue = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

private extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
