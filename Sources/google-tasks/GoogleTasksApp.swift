import GoogleTasksCore
import SwiftUI

@main
struct GoogleTasksApp: App {
    @NSApplicationDelegateAdaptor(AppPresenceController.self) private var presence
    @StateObject private var oauth = OAuthManager()
    @StateObject private var store: AppStore

    init() {
        let oauth = OAuthManager()
        _oauth = StateObject(wrappedValue: oauth)
        _store = StateObject(wrappedValue: AppStore(
            cache: DiskWorkspaceCache(),
            api: GoogleTasksAPI(accessTokenProvider: {
                try await oauth.validAccessToken()
            })
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(oauth)
                .environmentObject(store)
                .environmentObject(presence)
                .task {
                    presence.configure(store: store)
                    store.loadCache()
                    if oauth.isAuthenticated {
                        await store.sync()
                    }
                }
        }
        .commands {
            CommandMenu("Tasks") {
                Button("Nova tarefa") {
                    Task { await store.createTask() }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Nova lista") {
                    Task { await store.createList() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("Exibicao") {
                Picker("Mostrar app", selection: Binding(
                    get: { presence.mode },
                    set: { presence.setMode($0) }
                )) {
                    ForEach(AppPresenceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
        }
    }
}
