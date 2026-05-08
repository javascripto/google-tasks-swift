import AppKit
import GoogleTasksCore
import SwiftUI
import UniformTypeIdentifiers

private enum ContentMode {
    case taskList
    case calendar
}

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
    @State private var contentMode: ContentMode = .taskList

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            if contentMode == .calendar {
                CalendarView(selectedTask: $selectedTask)
                    .navigationSplitViewColumnWidth(min: 520, ideal: 720)
            } else {
                TaskListView(selectedTask: $selectedTask, isSearchVisible: $isSearchVisible)
                    .navigationSplitViewColumnWidth(min: 360, ideal: 520)
            }
        } detail: {
            TaskDetailView(task: selectedTask.flatMap { store.task(withID: $0.id) } ?? selectedTask)
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
                .disabled(contentMode == .calendar)

                Button {
                    Task { await store.sync() }
                } label: {
                    Label("Sincronizar", systemImage: "arrow.clockwise")
                }
                .help("Sincronizar com Google Tasks")

                Button {
                    contentMode = .taskList
                    isSearchVisible.toggle()
                    if !isSearchVisible {
                        store.searchText = ""
                    }
                } label: {
                    Label("Buscar", systemImage: "magnifyingglass")
                }
                .disabled(contentMode == .calendar)
                .help("Buscar tarefas na lista atual")

                Button {
                    contentMode = contentMode == .calendar ? .taskList : .calendar
                    if contentMode == .calendar {
                        isSearchVisible = false
                        store.searchText = ""
                    }
                } label: {
                    Label(contentMode == .calendar ? "Lista" : "Calendario", systemImage: contentMode == .calendar ? "list.bullet" : "calendar")
                }
                .help(contentMode == .calendar ? "Voltar para a lista de tarefas" : "Abrir calendario de prazos")

                Menu {
                    Button("Exportar todas como Markdown") {
                        exportTasks(listIDs: Set(store.orderedLists.map(\.id)), format: .markdown)
                    }
                    Button("Exportar todas como JSON") {
                        exportTasks(listIDs: Set(store.orderedLists.map(\.id)), format: .json)
                    }
                    Divider()
                    Button("Exportar lista atual como Markdown") {
                        exportTasks(listIDs: selectedExportListIDs, format: .markdown)
                    }
                    .disabled(store.selectedList == nil)
                    Button("Exportar lista atual como JSON") {
                        exportTasks(listIDs: selectedExportListIDs, format: .json)
                    }
                    .disabled(store.selectedList == nil)
                    Divider()
                    Button("Importar JSON") {
                        importTasks()
                    }
                } label: {
                    Label("Exportar e importar", systemImage: "square.and.arrow.up")
                }
                .help("Exportar ou importar tarefas")

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
                    .help("Sair da conta Google")
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
                    .help("Entrar com Google")
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

    private var selectedExportListIDs: Set<String> {
        if let selectedList = store.selectedList {
            return [selectedList.id]
        }
        return []
    }

    private func exportTasks(listIDs: Set<String>, format: ExportFormat) {
        do {
            let text = try store.exportWorkspace(listIDs: listIDs, format: format)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == .json ? .json : (UTType(filenameExtension: "md") ?? .plainText)]
            panel.nameFieldStringValue = format == .json ? "google-tasks-export.json" : "google-tasks-export.md"
            if panel.runModal() == .OK, let url = panel.url {
                try text.data(using: .utf8)?.write(to: url)
            }
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func importTasks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                Task { await store.importWorkspace(from: data) }
            } catch {
                store.lastError = error.localizedDescription
            }
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @State private var renamingList: GoogleTaskList?
    @State private var listPendingDeletion: GoogleTaskList?
    @State private var hiddenListsExpanded = true
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
                Section {
                    DisclosureGroup(isExpanded: $hiddenListsExpanded) {
                        ForEach(store.orderedLists.filter { store.hiddenListIDs.contains($0.id) }) { list in
                            Button {
                                store.toggleListHidden(list)
                            } label: {
                                Label(list.title, systemImage: "eye.slash")
                            }
                        }
                    } label: {
                        HStack {
                            Label("Ocultas", systemImage: "eye.slash")
                            Spacer()
                            Text("\(store.hiddenListIDs.count)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
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

private struct CalendarView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selectedTask: GoogleTask?
    @State private var displayedMonth = Calendar.current.monthStart(for: Date())
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var selectedListIDs: Set<String> = []
    @State private var listSelectionInitialized = false
    @State private var showCompleted = true

    private var calendar: Calendar {
        Calendar.current
    }

    private var summaries: [DueTaskSummary] {
        store.dueTaskSummaries(selectedListIDs: selectedListIDs, showCompleted: showCompleted)
    }

    private var summariesByDay: [Date: [DueTaskSummary]] {
        Dictionary(grouping: summaries) { summary in
            summary.task.due?.dueCalendarDay ?? .distantPast
        }
    }

    private var selectedDaySummaries: [DueTaskSummary] {
        summariesByDay[selectedDate] ?? []
    }

    var body: some View {
        HStack(spacing: 0) {
            calendarFilters
                .frame(width: 190)
                .background(.bar)

            Divider()

            VStack(spacing: 0) {
                calendarHeader
                    .padding()

                monthGrid
                    .padding(.horizontal)

                Divider()
                    .padding(.top, 12)

                agenda
            }
        }
        .onAppear {
            initializeListSelectionIfNeeded()
        }
        .onChange(of: store.calendarLists.map(\.id)) { _, _ in
            reconcileListSelection()
        }
    }

    private var calendarFilters: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Calendario")
                .font(.headline)

            Button {
                if allListsSelected {
                    selectedListIDs = []
                } else {
                    selectedListIDs = Set(store.calendarLists.map(\.id))
                }
                listSelectionInitialized = true
            } label: {
                Label("Todas as listas", systemImage: allListsIconName)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Marcar ou desmarcar todas as listas")

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.calendarLists) { list in
                        Toggle(isOn: Binding(
                            get: { selectedListIDs.contains(list.id) },
                            set: { isOn in
                                if isOn {
                                    selectedListIDs.insert(list.id)
                                } else {
                                    selectedListIDs.remove(list.id)
                                }
                                listSelectionInitialized = true
                            }
                        )) {
                            Text(list.title)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Divider()

            Toggle("Mostrar concluidas", isOn: $showCompleted)

            Spacer()
            StatusBarView()
        }
        .padding(12)
    }

    private var calendarHeader: some View {
        HStack {
            Text(monthTitle)
                .font(.title2.weight(.semibold))
            Spacer()
            Button {
                moveMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            Button("Hoje") {
                selectedDate = calendar.startOfDay(for: Date())
                displayedMonth = calendar.monthStart(for: selectedDate)
            }
            Button {
                moveMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
        }
    }

    private var monthGrid: some View {
        let days = calendarDays
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(0..<6, id: \.self) { row in
                GridRow {
                    ForEach(0..<7, id: \.self) { column in
                        dayCell(days[row * 7 + column])
                    }
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let day = calendar.startOfDay(for: date)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day)
        let isDisplayedMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)
        let daySummaries = summariesByDay[day] ?? []

        return Button {
            selectedDate = day
        } label: {
            VStack(spacing: 6) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.body.weight(isToday ? .semibold : .regular))
                    .foregroundStyle(isDisplayedMonth ? .primary : .tertiary)

                if daySummaries.isEmpty {
                    Circle()
                        .fill(.clear)
                        .frame(width: 6, height: 6)
                } else {
                    Text("\(daySummaries.count)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.16), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedDate.formatted(date: .complete, time: .omitted))
                    .font(.headline)
                Spacer()
                Text("\(selectedDaySummaries.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding()

            if selectedDaySummaries.isEmpty {
                ContentUnavailableView("Sem tarefas com prazo", systemImage: "calendar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selectedDaySummaries, selection: Binding(
                    get: { selectedTask.map { "\($0.id)" } },
                    set: { id in
                        selectedTask = selectedDaySummaries.first { $0.task.id == id }?.task
                    }
                )) { summary in
                    CalendarTaskRow(summary: summary)
                        .tag(summary.task.id)
                }
            }
        }
    }

    private var calendarDays: [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)
        else { return [] }

        return (0..<42).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: firstWeek.start)
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var monthTitle: String {
        displayedMonth.formatted(Date.FormatStyle().month(.wide).year())
    }

    private func moveMonth(by value: Int) {
        displayedMonth = calendar.monthStart(for: calendar.date(byAdding: .month, value: value, to: displayedMonth) ?? displayedMonth)
    }
}

private extension Calendar {
    func monthStart(for date: Date) -> Date {
        dateInterval(of: .month, for: date)?.start ?? startOfDay(for: date)
    }
}

private extension CalendarView {
    var allListsSelected: Bool {
        !store.calendarLists.isEmpty && selectedListIDs == Set(store.calendarLists.map(\.id))
    }

    var noListsSelected: Bool {
        selectedListIDs.isEmpty
    }

    var allListsIconName: String {
        if allListsSelected {
            return "checkmark.square"
        }
        if noListsSelected {
            return "square"
        }
        return "minus.square"
    }

    func initializeListSelectionIfNeeded() {
        guard !listSelectionInitialized else { return }
        selectedListIDs = Set(store.calendarLists.map(\.id))
        listSelectionInitialized = true
    }

    func reconcileListSelection() {
        let ids = Set(store.calendarLists.map(\.id))
        selectedListIDs = selectedListIDs.intersection(ids)
        if !listSelectionInitialized {
            selectedListIDs = ids
            listSelectionInitialized = true
        }
    }
}

private extension Date {
    var dueCalendarDay: Date {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utcCalendar.dateComponents([.year, .month, .day], from: self)
        return Calendar.current.date(from: DateComponents(
            year: components.year,
            month: components.month,
            day: components.day
        )) ?? Calendar.current.startOfDay(for: self)
    }

    var localDateForDueDatePicker: Date {
        dueCalendarDay
    }

    var formattedDueDate: String {
        dueCalendarDay.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct CalendarTaskRow: View {
    var summary: DueTaskSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.task.title.isEmpty ? "Sem titulo" : summary.task.title)
                .strikethrough(summary.task.isCompleted)
                .foregroundStyle(summary.task.isCompleted ? .secondary : .primary)
            HStack(spacing: 8) {
                Label(summary.listTitle, systemImage: "list.bullet")
                if summary.task.isCompleted {
                    Label("Concluida", systemImage: "checkmark.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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
                    Label(due.formattedDueDate, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let completed = task.completed {
                    Label("Concluida \(completed.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
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
                    HStack {
                        Toggle("Prazo", isOn: $hasDue)
                        Spacer()
                        Button("Hoje") {
                            setDue(daysFromToday: 0)
                        }
                        Button("Amanhã") {
                            setDue(daysFromToday: 1)
                        }
                    }
                    if hasDue {
                        VStack(alignment: .leading, spacing: 4) {
                            DatePicker("Prazo", selection: $due, displayedComponents: .date)
                            if let originalDue = task.due {
                                Text("Atual: \(originalDue.formattedDueDate)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let completed = task.completed {
                        LabeledContent("Conclusao") {
                            Text(completed.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
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
        due = task.due?.localDateForDueDatePicker ?? Date()
        hasDue = task.due != nil
    }

    private func setDue(daysFromToday days: Int) {
        hasDue = true
        due = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: Date())) ?? Date()
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
