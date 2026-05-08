import AppKit
import SwiftUI

enum AppPresenceMode: String, CaseIterable, Identifiable {
    case dock
    case menuBar
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dock: "Dock"
        case .menuBar: "Menu bar"
        case .both: "Dock e menu bar"
        }
    }
}

@MainActor
final class AppPresenceController: NSObject, ObservableObject, NSApplicationDelegate {
    @Published var mode: AppPresenceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            applyMode()
        }
    }

    private static let modeKey = "appPresenceMode"
    private var statusItem: NSStatusItem?
    private weak var store: AppStore?

    override init() {
        let savedMode = UserDefaults.standard.string(forKey: Self.modeKey)
            .flatMap(AppPresenceMode.init(rawValue:)) ?? .dock
        mode = savedMode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyMode()
    }

    func configure(store: AppStore) {
        self.store = store
        rebuildStatusMenu()
    }

    func setMode(_ mode: AppPresenceMode) {
        self.mode = mode
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("showMainWindow:")), to: nil, from: nil)
        }

        if mode == .menuBar {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func applyMode() {
        switch mode {
        case .dock:
            removeStatusItem()
            NSApp.setActivationPolicy(.regular)
        case .menuBar:
            installStatusItem()
            NSApp.setActivationPolicy(.accessory)
        case .both:
            installStatusItem()
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else {
            rebuildStatusMenu()
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Google Tasks")
            button.image?.isTemplate = true
            button.action = #selector(statusButtonClicked)
            button.target = self
        }
        statusItem = item
        rebuildStatusMenu()
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func rebuildStatusMenu() {
        guard let statusItem else { return }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Abrir Google Tasks", action: #selector(openFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Sincronizar", action: #selector(syncFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Mostrar no Dock", action: #selector(showDockOnly), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Mostrar na menu bar", action: #selector(showMenuBarOnly), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Mostrar em ambos", action: #selector(showBoth), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Sair", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }

        menu.item(withTitle: "Mostrar no Dock")?.state = mode == .dock ? .on : .off
        menu.item(withTitle: "Mostrar na menu bar")?.state = mode == .menuBar ? .on : .off
        menu.item(withTitle: "Mostrar em ambos")?.state = mode == .both ? .on : .off

        statusItem.menu = menu
    }

    @objc private func statusButtonClicked() {
        showMainWindow()
    }

    @objc private func openFromMenu() {
        showMainWindow()
    }

    @objc private func syncFromMenu() {
        Task { await store?.sync() }
    }

    @objc private func showDockOnly() {
        setMode(.dock)
    }

    @objc private func showMenuBarOnly() {
        setMode(.menuBar)
    }

    @objc private func showBoth() {
        setMode(.both)
    }

    @objc private func quit() {
        let alert = NSAlert()
        alert.messageText = "Sair do Google Tasks?"
        alert.informativeText = "O app sera fechado. Suas tarefas sincronizadas continuarao no Google Tasks."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sair")
        alert.addButton(withTitle: "Cancelar")

        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }
}
