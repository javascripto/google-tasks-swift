import Foundation

public struct GoogleTaskList: Codable, Equatable, Identifiable, Sendable {
    public var kind: String?
    public var id: String
    public var etag: String?
    public var title: String
    public var updated: Date?
    public var selfLink: String?

    public init(kind: String? = nil, id: String, etag: String? = nil, title: String, updated: Date? = nil, selfLink: String? = nil) {
        self.kind = kind
        self.id = id
        self.etag = etag
        self.title = title
        self.updated = updated
        self.selfLink = selfLink
    }
}

public struct GoogleTask: Codable, Equatable, Identifiable, Sendable {
    public var kind: String?
    public var id: String
    public var etag: String?
    public var title: String
    public var updated: Date?
    public var selfLink: String?
    public var parent: String?
    public var position: String?
    public var notes: String?
    public var status: TaskStatus
    public var due: Date?
    public var completed: Date?
    public var deleted: Bool?
    public var hidden: Bool?
    public var links: [TaskLink]?
    public var webViewLink: String?

    public var isCompleted: Bool {
        status == .completed
    }

    public init(kind: String? = nil, id: String, etag: String? = nil, title: String, updated: Date? = nil, selfLink: String? = nil, parent: String? = nil, position: String? = nil, notes: String? = nil, status: TaskStatus, due: Date? = nil, completed: Date? = nil, deleted: Bool? = nil, hidden: Bool? = nil, links: [TaskLink]? = nil, webViewLink: String? = nil) {
        self.kind = kind
        self.id = id
        self.etag = etag
        self.title = title
        self.updated = updated
        self.selfLink = selfLink
        self.parent = parent
        self.position = position
        self.notes = notes
        self.status = status
        self.due = due
        self.completed = completed
        self.deleted = deleted
        self.hidden = hidden
        self.links = links
        self.webViewLink = webViewLink
    }
}

public struct TaskLink: Codable, Equatable, Sendable {
    public var type: String?
    public var description: String?
    public var link: String?

    public init(type: String? = nil, description: String? = nil, link: String? = nil) {
        self.type = type
        self.description = description
        self.link = link
    }
}

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case needsAction
    case completed
}

public enum TaskFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case all
    case active
    case completed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "Todas"
        case .active: "Pendentes"
        case .completed: "Concluidas"
        }
    }
}

public struct TaskListPage: Codable, Equatable, Sendable {
    public var kind: String?
    public var etag: String?
    public var nextPageToken: String?
    public var items: [GoogleTaskList]?
}

public struct TaskPage: Codable, Equatable, Sendable {
    public var kind: String?
    public var etag: String?
    public var nextPageToken: String?
    public var items: [GoogleTask]?
}

public struct CachedWorkspace: Codable, Equatable, Sendable {
    public var lists: [GoogleTaskList]
    public var tasksByListID: [String: [GoogleTask]]
    public var selectedListID: String?
    public var hiddenListIDs: Set<String>
    public var listOrder: [String]
    public var savedAt: Date

    public static let empty = CachedWorkspace(
        lists: [],
        tasksByListID: [:],
        selectedListID: nil,
        hiddenListIDs: [],
        listOrder: [],
        savedAt: .distantPast
    )

    public init(lists: [GoogleTaskList], tasksByListID: [String: [GoogleTask]], selectedListID: String?, hiddenListIDs: Set<String>, listOrder: [String], savedAt: Date) {
        self.lists = lists
        self.tasksByListID = tasksByListID
        self.selectedListID = selectedListID
        self.hiddenListIDs = hiddenListIDs
        self.listOrder = listOrder
        self.savedAt = savedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lists = try container.decode([GoogleTaskList].self, forKey: .lists)
        tasksByListID = try container.decode([String: [GoogleTask]].self, forKey: .tasksByListID)
        selectedListID = try container.decodeIfPresent(String.self, forKey: .selectedListID)
        hiddenListIDs = try container.decode(Set<String>.self, forKey: .hiddenListIDs)
        listOrder = try container.decode([String].self, forKey: .listOrder)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
    }
}

extension JSONDecoder {
    public static let googleTasks: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    public static let googleTasks: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
