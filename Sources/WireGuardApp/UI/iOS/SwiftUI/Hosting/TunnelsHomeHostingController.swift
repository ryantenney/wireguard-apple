// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit
import SwiftUI
import Combine

/// SwiftUI root shown until the tunnels manager finishes loading.
private struct RootView: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        ZStack {
            Palette.screenBackground.ignoresSafeArea()
            if let store = router.store {
                TunnelsHomeView()
                    .environmentObject(store)
            } else {
                ProgressView()
            }
        }
        .tint(theme.accent.color)
    }
}

/// The master-column root: hosts the SwiftUI Home, owns the theme/router/store,
/// and exposes the shim methods `MainViewController`/`AppDelegate` call.
final class TunnelsHomeHostingController: UIHostingController<AnyView> {
    let theme: AppTheme
    let router: AppRouter
    private var cancellables = Set<AnyCancellable>()

    init() {
        let theme = AppTheme()
        let router = AppRouter(theme: theme)
        self.theme = theme
        self.router = router
        let root = RootView()
            .environmentObject(theme)
            .environmentObject(router)
        super.init(rootView: AnyView(root))
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        router.hostController = self
        navigationItem.title = tr("tunnelsListTitle")
        navigationItem.backButtonTitle = tr("tunnelsListTitle")
        observeTheme()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        applyTheme()
    }

    // MARK: - Installation

    func install(manager: TunnelsManager) {
        router.splitViewController = splitViewController
        if router.store == nil {
            router.store = TunnelStore(manager: manager)
        }
    }

    // MARK: - Shims used by MainViewController / AppDelegate

    func allTunnelNames() -> [String] {
        router.store?.allTunnelNames() ?? []
    }

    func refreshStatuses() {
        router.store?.refreshStatuses()
    }

    func showTunnelDetail(named name: String, shouldToggle: Bool) {
        guard let store = router.store, let node = store.node(named: name) else { return }
        router.showDetail(for: node)
        if shouldToggle {
            store.toggle(node)
        }
    }

    // MARK: - Theme application to UIKit chrome

    private func observeTheme() {
        theme.$accent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyTheme() }
            .store(in: &cancellables)
        theme.$appearance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyTheme() }
            .store(in: &cancellables)
    }

    private func applyTheme() {
        let window = view.window ?? splitViewController?.view.window
        window?.tintColor = theme.accent.uiColor
        window?.overrideUserInterfaceStyle = theme.appearance.userInterfaceStyle
    }
}
