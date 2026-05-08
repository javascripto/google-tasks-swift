import Foundation
import GoogleTasksCore
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var lists: [GoogleTaskList] = []
    @Published var tasksByListID: [String: [GoogleTask]] = [:]
    @Published var selectedListID: String?
    @Published var hiddenListIDs: Set<String> = []
    @Published var listOrder: [String] = []
    @Published var filter: TaskFilter = .active
    @Published var searchText = ""
    @Published var isSyncing = false
    @Published var lastSyncedAt: Date?
    @Published var lastError: String?

    private let cache: WorkspaceCaching
    private let api: GoogleTasksAPI

    init(cache: WorkspaceCaching, api: GoogleTasksAPI) {
        self.cache = cache
        self.api = api
    }

    var visibleLists: [GoogleTaskList] {
        orderedLists.filter { !hiddenListIDs.contains($0.id) }
    }

    var orderedLists: [GoogleTaskList] {
        lists.sorted { lhs, rhs in
            let left = listOrder.firstIndex(of: lhs.id) ?? Int.max
            let right = listOrder.firstIndex(of: rhs.id) ?? Int.max
            if left == right {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return left < right
        }
    }

    var selectedList: GoogleTaskList? {
        visibleLists.first { $0.id == selectedListID } ?? visibleLists.first
    }

    var selectedTasks: [GoogleTask] {
        guard let selectedList else { return [] }
        return tasks(in: selectedList, filter: filter, searchText: searchText)
    }

    func pendingTaskCount(in list: GoogleTaskList) -> Int {
        tasks(in: list, filter: .active, searchText: "").count
    }

    func loadCache() {
        do {
            apply(try cache.load())
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearAfterSignOut() {
        lists = []
        tasksByListID = [:]
        selectedListID = nil
        lastSyncedAt = nil
        lastError = nil
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let remoteLists = try await api.listTaskLists()
            var remoteTasks: [String: [GoogleTask]] = [:]
            for list in remoteLists {
                remoteTasks[list.id] = try await api.listTasks(in: list.id)
            }
            lists = remoteLists
            tasksByListID = remoteTasks
            reconcileSelection()
            reconcileListOrder()
            try persist()
            lastSyncedAt = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createList(title: String = "Nova lista") async {
        do {
            let list = try await api.insertTaskList(title: title)
            lists.append(list)
            selectedListID = list.id
            listOrder.append(list.id)
            try persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func renameList(_ list: GoogleTaskList, title: String) async {
        do {
            let updated = try await api.patchTaskList(list.id, title: title)
            replaceList(updated)
            try persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteList(_ list: GoogleTaskList) async {
        do {
            try await api.deleteTaskList(list.id)
            lists.removeAll { $0.id == list.id }
            tasksByListID.removeValue(forKey: list.id)
            hiddenListIDs.remove(list.id)
            listOrder.removeAll { $0 == list.id }
            reconcileSelection()
            try persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleListHidden(_ list: GoogleTaskList) {
        if hiddenListIDs.contains(list.id) {
            hiddenListIDs.remove(list.id)
        } else {
            hiddenListIDs.insert(list.id)
        }
        reconcileSelection()
        try? persist()
    }

    func moveList(from source: IndexSet, to destination: Int) {
        var visibleIDs = visibleLists.map(\.id)
        visibleIDs.move(fromOffsets: source, toOffset: destination)
        let hiddenIDs = orderedLists.map(\.id).filter { hiddenListIDs.contains($0) }
        listOrder = visibleIDs + hiddenIDs
        try? persist()
    }

    func createTask(title: String = "Nova tarefa") async {
        guard let list = selectedList else { return }
        do {
            let task = try await api.insertTask(in: list.id, title: title)
            tasksByListID[list.id, default: []].append(task)
            try persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createSubtask(parent task: GoogleTask, title: String = "Nova subtarefa") async {
        guard task.parent == nil, let listID = taskListID(containing: task) else { return }
        do {
            let subtask = try await api.insertTask(in: listID, title: title, parent: task.id)
            tasksByListID[listID, default: []].append(subtask)
            try persist()
            await sync()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func patchTask(_ task: GoogleTask, title: String? = nil, notes: String? = nil, due: Date? = nil, clearDue: Bool = false) async {
        guard let listID = taskListID(containing: task) else { return }
        do {
            var payload: [String: GoogleTasksPatchValue] = [
                "title": .string(title ?? task.title),
                "notes": .string(notes ?? task.notes ?? "")
            ]
            if clearDue {
                payload["due"] = .null
            } else if let due {
                payload["due"] = .string(ISO8601DateFormatter().string(from: due))
            } else if let taskDue = task.due {
                payload["due"] = .string(ISO8601DateFormatter().string(from: taskDue))
            }

            let updated = try await api.patchTask(task.id, in: listID, payload: payload)
            replaceTask(updated, in: listID)
            try persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setCompleted(_ task: GoogleTask, completed: Bool) async {
        guard let listID = taskListID(containing: task) else { return }
        do {
            let updated = try await api.setTaskCompleted(task.id, in: listID, completed: completed)
            replaceTask(updated, in: listID)
            try persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteTask(_ task: GoogleTask) async {
        guard let listID = taskListID(containing: task) else { return }
        do {
            try await api.deleteTask(task.id, in: listID)
            tasksByListID[listID]?.removeAll { $0.id == task.id }
            try persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func moveTask(_ task: GoogleTask, after previousTask: GoogleTask?) async {
        guard let listID = taskListID(containing: task) else { return }
        do {
            let previous = task.parent == nil ? previousTask?.topLevelTaskID : previousTask?.id
            let updated = try await api.moveTask(task.id, from: listID, previous: previous)
            replaceTask(updated, in: listID)
            await sync()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func moveTask(_ task: GoogleTask, to destinationList: GoogleTaskList) async {
        guard let sourceListID = taskListID(containing: task), sourceListID != destinationList.id else { return }
        do {
            let updated = try await api.moveTask(task.id, from: sourceListID, destinationListID: destinationList.id)
            tasksByListID[sourceListID]?.removeAll { $0.id == task.id }
            replaceTask(updated, in: destinationList.id)
            try persist()
            await sync()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func menuTaskSummaries(limit: Int = 6) -> [MenuTaskSummary] {
        orderedLists.flatMap { list in
            tasks(in: list, filter: .active, searchText: "")
                .map { MenuTaskSummary(title: $0.title, listTitle: list.title) }
        }
        .prefix(limit)
        .map { $0 }
    }

    private func apply(_ workspace: CachedWorkspace) {
        lists = workspace.lists
        tasksByListID = workspace.tasksByListID
        selectedListID = workspace.selectedListID
        hiddenListIDs = workspace.hiddenListIDs
        listOrder = workspace.listOrder
        reconcileSelection()
        reconcileListOrder()
    }

    private func persist() throws {
        try cache.save(CachedWorkspace(
            lists: lists,
            tasksByListID: tasksByListID,
            selectedListID: selectedList?.id,
            hiddenListIDs: hiddenListIDs,
            listOrder: listOrder,
            savedAt: Date()
        ))
    }

    private func reconcileSelection() {
        if selectedListID == nil || !visibleLists.contains(where: { $0.id == selectedListID }) {
            selectedListID = visibleLists.first?.id
        }
    }

    private func reconcileListOrder() {
        let ids = lists.map(\.id)
        listOrder = listOrder.filter { ids.contains($0) }
        listOrder.append(contentsOf: ids.filter { !listOrder.contains($0) })
    }

    private func replaceList(_ list: GoogleTaskList) {
        if let index = lists.firstIndex(where: { $0.id == list.id }) {
            lists[index] = list
        } else {
            lists.append(list)
        }
    }

    private func replaceTask(_ task: GoogleTask, in listID: String) {
        if let index = tasksByListID[listID]?.firstIndex(where: { $0.id == task.id }) {
            tasksByListID[listID]?[index] = task
        } else {
            tasksByListID[listID, default: []].append(task)
        }
    }

    private func taskListID(containing task: GoogleTask) -> String? {
        tasksByListID.first { _, tasks in
            tasks.contains { $0.id == task.id }
        }?.key
    }

    private func tasks(in list: GoogleTaskList, filter: TaskFilter, searchText: String) -> [GoogleTask] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredTasks = (tasksByListID[list.id] ?? [])
            .filter { task in
                switch filter {
                case .all:
                    !(task.deleted ?? false)
                case .active:
                    task.status == .needsAction && !(task.deleted ?? false) && !(task.hidden ?? false)
                case .completed:
                    task.status == .completed && !(task.deleted ?? false)
                }
            }

        return hierarchicalTasks(filteredTasks)
            .filter { task in
                guard !query.isEmpty else { return true }
                return task.title.localizedCaseInsensitiveContains(query)
                    || (task.notes?.localizedCaseInsensitiveContains(query) ?? false)
            }
    }

    private func hierarchicalTasks(_ tasks: [GoogleTask]) -> [GoogleTask] {
        let byParent = Dictionary(grouping: tasks) { $0.parent }
            .mapValues { children in
                children.sorted { ($0.position ?? "") < ($1.position ?? "") }
            }
        var visited = Set<String>()
        var result: [GoogleTask] = []

        func appendTask(_ task: GoogleTask) {
            guard !visited.contains(task.id) else { return }
            visited.insert(task.id)
            result.append(task)
            for child in byParent[task.id] ?? [] {
                appendTask(child)
            }
        }

        for task in byParent[nil] ?? [] {
            appendTask(task)
        }

        for task in tasks.sorted(by: { ($0.position ?? "") < ($1.position ?? "") }) where !visited.contains(task.id) {
            appendTask(task)
        }

        return result
    }
}

private extension GoogleTask {
    var topLevelTaskID: String? {
        parent == nil ? id : nil
    }
}

struct MenuTaskSummary: Identifiable {
    var id: String { "\(listTitle)-\(title)" }
    var title: String
    var listTitle: String
}
