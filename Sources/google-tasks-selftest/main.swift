import Foundation
import GoogleTasksCore

@main
struct SelfTest {
    static func main() async throws {
        try taskDecodingMatchesGoogleShape()
        try await listTasksBuildsExpectedRequestAndPagination()
        try await moveTaskBuildsDestinationRequest()
        try diskCacheRoundTripsWorkspace()
        print("Selftests passed")
    }

    static func taskDecodingMatchesGoogleShape() throws {
        let json = """
        {
          "id": "task-1",
          "title": "Comprar cafe",
          "status": "needsAction",
          "notes": "Moido",
          "due": "2026-05-08T00:00:00.000Z",
          "hidden": false
        }
        """.data(using: .utf8)!

        let task = try JSONDecoder.googleTasks.decode(GoogleTask.self, from: json)
        try expect(task.id == "task-1")
        try expect(task.title == "Comprar cafe")
        try expect(task.status == .needsAction)
        try expect(task.notes == "Moido")
        try expect(task.hidden == false)
    }

    static func listTasksBuildsExpectedRequestAndPagination() async throws {
        let transport = MockTransport(responses: [
            .json("""
            {"items":[{"id":"1","title":"A","status":"needsAction"}],"nextPageToken":"next"}
            """),
            .json("""
            {"items":[{"id":"2","title":"B","status":"completed"}]}
            """)
        ])
        let api = GoogleTasksAPI(baseURL: URL(string: "https://example.test")!, transport: transport) {
            "token"
        }

        let tasks = try await api.listTasks(in: "list 1")

        try expect(tasks.map(\.id) == ["1", "2"])
        let requestCount = await transport.requestCount
        try expect(requestCount == 2)
        let first = await transport.request(at: 0)
        try expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        try expect(first.url?.absoluteString.contains("showCompleted=true") == true)
        try expect(first.url?.absoluteString.contains("showHidden=true") == true)
    }

    static func moveTaskBuildsDestinationRequest() async throws {
        let transport = MockTransport(responses: [
            .json(#"{"id":"task","title":"Moved","status":"needsAction"}"#)
        ])
        let api = GoogleTasksAPI(baseURL: URL(string: "https://example.test")!, transport: transport) {
            "token"
        }

        _ = try await api.moveTask("task", from: "source", parent: "parent", previous: "prev", destinationListID: "dest")

        let url = await transport.request(at: 0).url?.absoluteString ?? ""
        try expect(url.contains("/tasks/v1/lists/source/tasks/task/move"))
        try expect(url.contains("parent=parent"))
        try expect(url.contains("previous=prev"))
        try expect(url.contains("destinationTasklist=dest"))
    }

    static func diskCacheRoundTripsWorkspace() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("workspace.json")
        let cache = DiskWorkspaceCache(fileURL: fileURL)
        let workspace = CachedWorkspace(
            lists: [GoogleTaskList(id: "list", title: "Inbox")],
            tasksByListID: ["list": [GoogleTask(id: "task", title: "A", status: .needsAction)]],
            selectedListID: "list",
            hiddenListIDs: ["hidden"],
            listOrder: ["list"],
            savedAt: Date()
        )

        try cache.save(workspace)
        let loaded = try cache.load()

        try expect(loaded.lists == workspace.lists)
        try expect(loaded.tasksByListID == workspace.tasksByListID)
        try expect(loaded.selectedListID == "list")
        try expect(loaded.hiddenListIDs == ["hidden"])
    }

    static func expect(_ condition: @autoclosure () -> Bool) throws {
        if !condition() {
            throw SelfTestError.expectationFailed
        }
    }
}

enum SelfTestError: Error {
    case expectationFailed
}

actor MockTransport: HTTPTransport {
    struct Response: Sendable {
        var data: Data
        var statusCode: Int

        static func json(_ string: String, statusCode: Int = 200) -> Response {
            Response(data: Data(string.utf8), statusCode: statusCode)
        }
    }

    private var requests: [URLRequest] = []
    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    var requestCount: Int {
        requests.count
    }

    func request(at index: Int) -> URLRequest {
        requests[index]
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response.data, http)
    }
}
