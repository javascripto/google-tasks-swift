import GoogleTasksCore
import SwiftUI

struct ContentView: View {
    private let pollingInterval: Duration = .seconds(30)

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var oauth: OAuthManager
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var presence: AppPresenceController
    @State private var selectedTask: GoogleTask?
    @State private var pollingTask: Task<Void, Never>?
    @State private var isConfirmingSignOut = false
    @State private var isSearchVisible = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            TaskListView(selectedTask: $selectedTask, isSearchVisible: $isSearchVisible)
                .navigationSplitViewColumnWidth(min: 360, ideal: 520)
        } detail: {
            TaskDetailView(task: selectedTask)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Filtro", selection: $store.filter) {
                    ForEach(TaskFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)

                Button {
                    Task { await store.sync() }
                } label: {
                    Label("Sincronizar", systemImage: "arrow.clockwise")
                }

                Button {
                    isSearchVisible.toggle()
                    if !isSearchVisible {
                        store.searchText = ""
                    }
                } label: {
                    Label("Buscar", systemImage: "magnifyingglass")
                }

                Picker("Exibicao", selection: Binding(
                    get: { presence.mode },
                    set: { presence.setMode($0) }
                )) {
                    ForEach(AppPresenceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)

                if oauth.isAuthenticated {
                    Button {
                        isConfirmingSignOut = true
                    } label: {
                        Label("Sair", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Button {
                        Task {
                            do {
                                try await oauth.signIn()
                                await store.sync()
                            } catch {
                                store.lastError = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Entrar", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
            }
        }
        .confirmationDialog("Sair da conta?", isPresented: $isConfirmingSignOut) {
            Button("Sair", role: .destructive) {
                do {
                    try oauth.signOut()
                    store.clearAfterSignOut()
                } catch {
                    store.lastError = error.localizedDescription
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Voce precisara entrar novamente para sincronizar suas listas e tarefas.")
        }
        .onAppear {
            if scenePhase == .active {
                startPolling()
            }
        }
        .onDisappear {
            stopPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                startPolling()
                syncIfAuthenticated()
            } else {
                stopPolling()
            }
        }
        .onChange(of: oauth.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated, scenePhase == .active {
                startPolling()
                syncIfAuthenticated()
            } else if !isAuthenticated {
                stopPolling()
            }
        }
    }

    private func startPolling() {
        guard pollingTask == nil, oauth.isAuthenticated else { return }
        pollingTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollingInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, oauth.isAuthenticated else { return }
                await store.sync()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func syncIfAuthenticated() {
        guard oauth.isAuthenticated else { return }
        Task { await store.sync() }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @State private var renamingList: GoogleTaskList?
    @State private var listPendingDeletion: GoogleTaskList?
    @State private var newTitle = ""

    var body: some View {
        List(selection: $store.selectedListID) {
            Section("Listas") {
                ForEach(store.visibleLists) { list in
                    HStack(spacing: 8) {
                        Label(list.title, systemImage: "list.bullet")
                        Spacer(minLength: 8)
                        let count = store.pendingTaskCount(in: list)
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                        .tag(Optional(list.id))
                        .contextMenu {
                            Button("Renomear") {
                                renamingList = list
                                newTitle = list.title
                            }
                            Button("Ocultar") {
                                store.toggleListHidden(list)
                            }
                            DeleteListMenuButton(list: list, listPendingDeletion: $listPendingDeletion)
                        }
                }
                .onMove { source, destination in
                    store.moveList(from: source, to: destination)
                }
            }

            if !store.hiddenListIDs.isEmpty {
                Section("Ocultas") {
                    ForEach(store.orderedLists.filter { store.hiddenListIDs.contains($0.id) }) { list in
                        Button {
                            store.toggleListHidden(list)
                        } label: {
                            Label(list.title, systemImage: "eye.slash")
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Button {
                    Task { await store.createList() }
                } label: {
                    Label("Nova lista", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 16)

                StatusBarView()
            }
            .background(.bar)
        }
        .alert("Renomear lista", isPresented: Binding(
            get: { renamingList != nil },
            set: { if !$0 { renamingList = nil } }
        )) {
            TextField("Nome", text: $newTitle)
            Button("Salvar") {
                if let renamingList {
                    Task { await store.renameList(renamingList, title: newTitle) }
                }
                renamingList = nil
            }
            Button("Cancelar", role: .cancel) {
                renamingList = nil
            }
        }
        .alert("Excluir lista?", isPresented: Binding(
            get: { listPendingDeletion != nil },
            set: { if !$0 { listPendingDeletion = nil } }
        )) {
            Button("Excluir lista", role: .destructive) {
                if let listPendingDeletion {
                    Task { await store.deleteList(listPendingDeletion) }
                }
                listPendingDeletion = nil
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A lista \"\(listPendingDeletion?.title ?? "")\" e suas tarefas serao removidas do Google Tasks.")
        }
    }
}

private struct DeleteListMenuButton: View {
    var list: GoogleTaskList
    @Binding var listPendingDeletion: GoogleTaskList?

    var body: some View {
        Button("Excluir", role: .destructive) {
            listPendingDeletion = list
        }
    }
}

private struct TaskListView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selectedTask: GoogleTask?
    @Binding var isSearchVisible: Bool
    @State private var draftTitle = ""
    @State private var taskPendingDeletion: GoogleTask?
    @State private var taskPendingSubtask: GoogleTask?
    @State private var subtaskTitle = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.selectedList?.title ?? "Google Tasks")
                    .font(.title2.weight(.semibold))
                Spacer()
                if store.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding()

            if isSearchVisible {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Buscar tarefas", text: $store.searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                    if !store.searchText.isEmpty {
                        Button {
                            store.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal)
                .padding(.bottom, 8)
                .onAppear { isSearchFocused = true }
            }

            HStack {
                TextField("Nova tarefa", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { createTask() }
                Button {
                    createTask()
                } label: {
                    Label("Adicionar", systemImage: "plus")
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)

            if store.selectedList == nil {
                ContentUnavailableView("Nenhuma lista", systemImage: "list.bullet", description: Text("Crie uma lista para comecar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.selectedTasks.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "checklist", description: Text(emptyMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { selectedTask?.id },
                    set: { id in selectedTask = store.selectedTasks.first { $0.id == id } }
                )) {
                    ForEach(store.selectedTasks) { task in
                        TaskRow(task: task)
                            .tag(Optional(task.id))
                            .contextMenu {
                                Button(task.isCompleted ? "Reabrir" : "Concluir") {
                                    Task { await store.setCompleted(task, completed: !task.isCompleted) }
                                }
                                if task.parent == nil {
                                    Button("Nova subtarefa") {
                                        taskPendingSubtask = task
                                        subtaskTitle = ""
                                    }
                                }
                                if store.visibleLists.count > 1 {
                                    Menu("Mover para") {
                                        ForEach(store.visibleLists.filter { $0.id != store.selectedList?.id }) { list in
                                            Button(list.title) {
                                                Task { await store.moveTask(task, to: list) }
                                            }
                                        }
                                    }
                                }
                                Button("Excluir", role: .destructive) {
                                    taskPendingDeletion = task
                                }
                            }
                    }
                    .onMove(perform: moveTasks)

                    Color.clear
                        .frame(height: 18)
                        .listRowSeparator(.hidden)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    StatusBarView()
                }
            }
        }
        .alert("Excluir tarefa?", isPresented: Binding(
            get: { taskPendingDeletion != nil },
            set: { if !$0 { taskPendingDeletion = nil } }
        )) {
            Button("Excluir tarefa", role: .destructive) {
                if let taskPendingDeletion {
                    Task {
                        await store.deleteTask(taskPendingDeletion)
                        if selectedTask?.id == taskPendingDeletion.id {
                            selectedTask = nil
                        }
                    }
                }
                taskPendingDeletion = nil
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            let title = taskPendingDeletion?.title ?? ""
            Text("A tarefa \"\(title.isEmpty ? "Sem titulo" : title)\" sera removida do Google Tasks.")
        }
        .alert("Nova subtarefa", isPresented: Binding(
            get: { taskPendingSubtask != nil },
            set: { if !$0 { taskPendingSubtask = nil } }
        )) {
            TextField("Titulo", text: $subtaskTitle)
            Button("Criar") {
                let title = subtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if let taskPendingSubtask, !title.isEmpty {
                    Task { await store.createSubtask(parent: taskPendingSubtask, title: title) }
                }
                taskPendingSubtask = nil
            }
            Button("Cancelar", role: .cancel) {
                taskPendingSubtask = nil
            }
        } message: {
            Text("A subtarefa sera criada abaixo da tarefa selecionada.")
        }
        .onChange(of: isSearchVisible) { _, visible in
            if visible {
                isSearchFocused = true
            }
        }
    }

    private func createTask() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        draftTitle = ""
        Task { await store.createTask(title: title) }
    }

    private func moveTasks(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }
        var tasks = store.selectedTasks
        guard sourceIndex < tasks.count else { return }
        let moved = tasks.remove(at: sourceIndex)
        let insertionIndex = min(destination > sourceIndex ? destination - 1 : destination, tasks.count)
        tasks.insert(moved, at: insertionIndex)
        let previousTask = insertionIndex > 0 ? tasks[insertionIndex - 1] : nil
        Task { await store.moveTask(moved, after: previousTask) }
    }

    private var emptyTitle: String {
        if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Nada encontrado"
        }
        switch store.filter {
        case .all: return "Nenhuma tarefa"
        case .active: return "Sem tarefas pendentes"
        case .completed: return "Sem tarefas concluidas"
        }
    }

    private var emptyMessage: String {
        if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "A busca nao encontrou titulo ou detalhes nesta lista."
        }
        switch store.filter {
        case .all: return "Adicione uma tarefa acima."
        case .active: return "Tudo em dia nesta lista."
        case .completed: return "Tarefas concluidas aparecerao aqui."
        }
    }
}

private struct TaskRow: View {
    @EnvironmentObject private var store: AppStore
    var task: GoogleTask
    @State private var title = ""
    @FocusState private var isEditingTitle: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                Task { await store.setCompleted(task, completed: !task.isCompleted) }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Titulo", text: $title)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .textFieldStyle(.plain)
                    .focused($isEditingTitle)
                    .onSubmit { saveTitle() }
                    .onChange(of: isEditingTitle) { _, focused in
                        if !focused {
                            saveTitle()
                        }
                    }
                if task.parent != nil {
                    Label("Subtarefa", systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let due = task.due {
                    Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .padding(.leading, task.parent == nil ? 0 : 22)
        .onAppear { title = task.title }
        .onChange(of: task.title) { _, newValue in title = newValue }
    }

    private func saveTitle() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanTitle != task.title else { return }
        Task { await store.patchTask(task, title: cleanTitle.isEmpty ? "Sem titulo" : cleanTitle) }
    }
}

private struct TaskDetailView: View {
    @EnvironmentObject private var store: AppStore
    var task: GoogleTask?
    @State private var title = ""
    @State private var notes = ""
    @State private var due = Date()
    @State private var hasDue = false

    var body: some View {
        Group {
            if let task {
                Form {
                    TextField("Titulo", text: $title)
                    TextEditor(text: $notes)
                        .frame(minHeight: 120)
                    Toggle("Data", isOn: $hasDue)
                    if hasDue {
                        DatePicker("Prazo", selection: $due, displayedComponents: .date)
                    }
                    Color.clear
                        .frame(height: 20)
                }
                .padding()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Button {
                            Task {
                                await store.patchTask(task, title: title, notes: notes, due: hasDue ? due : nil, clearDue: !hasDue)
                            }
                        } label: {
                            Label("Salvar", systemImage: "checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 16)

                        StatusBarView()
                    }
                    .background(.bar)
                }
                .onAppear { load(task) }
                .onChange(of: task.id) { _, _ in load(task) }
            } else {
                ContentUnavailableView("Selecione uma tarefa", systemImage: "checklist")
            }
        }
    }

    private func load(_ task: GoogleTask) {
        title = task.title
        notes = task.notes ?? ""
        due = task.due ?? Date()
        hasDue = task.due != nil
    }
}

private struct StatusBarView: View {
    @EnvironmentObject private var oauth: OAuthManager
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack {
            Text(oauth.isAuthenticated ? "Conectado" : "Offline")
            Spacer()
            if let error = store.lastError {
                Text(error)
                    .lineLimit(1)
                    .foregroundStyle(.red)
            } else if store.isSyncing {
                Text("Sincronizando...")
            } else if let lastSyncedAt = store.lastSyncedAt {
                Text("Sincronizado \(lastSyncedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
