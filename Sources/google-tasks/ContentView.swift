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

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            TaskListView(selectedTask: $selectedTask)
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
                    Label(list.title, systemImage: "list.bullet")
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
    @State private var draftTitle = ""
    @State private var taskPendingDeletion: GoogleTask?

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
                            Button("Excluir", role: .destructive) {
                                taskPendingDeletion = task
                            }
                        }
                }
                Color.clear
                    .frame(height: 18)
                    .listRowSeparator(.hidden)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBarView()
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
    }

    private func createTask() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        draftTitle = ""
        Task { await store.createTask(title: title) }
    }
}

private struct TaskRow: View {
    @EnvironmentObject private var store: AppStore
    var task: GoogleTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                Task { await store.setCompleted(task, completed: !task.isCompleted) }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title.isEmpty ? "Sem titulo" : task.title)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
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
                                await store.patchTask(task, title: title, notes: notes, due: hasDue ? due : nil)
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
