import Foundation

public protocol WorkspaceCaching: Sendable {
    func load() throws -> CachedWorkspace
    func save(_ workspace: CachedWorkspace) throws
}

public struct DiskWorkspaceCache: WorkspaceCaching {
    private let fileURL: URL

    public init(fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GoogleTasksMac", isDirectory: true)
        try? fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        fileURL = baseURL.appendingPathComponent("workspace.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> CachedWorkspace {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.googleTasks.decode(CachedWorkspace.self, from: data)
    }

    public func save(_ workspace: CachedWorkspace) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.googleTasks.encode(workspace)
        try data.write(to: fileURL, options: [.atomic])
    }
}
