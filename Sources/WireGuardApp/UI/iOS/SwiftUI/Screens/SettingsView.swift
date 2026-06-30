// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import SwiftUI
import UserNotifications

/// Settings: appearance (theme + live accent), failover defaults, notifications,
/// IP discovery, data/logs, and version info.
struct SettingsView: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var theme: AppTheme

    @State private var notifyOnDisconnect = NotificationSettings.isDisconnectNotificationEnabled
    @State private var notifyOnFailover = NotificationSettings.isFailoverNotificationEnabled
    @State private var ipDiscovery = IPDiscoverySettings.isEnabled
    @State private var backgroundProbeDefault = FailoverDefaults.useBackgroundProbes
    @State private var defaultSensitivity = FailoverDefaults.sensitivity

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.screenBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Settings")
                        .font(.appSans(32, .bold))
                        .foregroundColor(Palette.primaryText)
                        .padding(.top, 8)
                        .padding(.bottom, 16)

                    appearanceSection
                    failoverDefaultsSection
                    notificationsSection
                    dataAndLogsSection
                    aboutSection
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 96)
            }
            BottomTabBar(selected: .settings,
                         accent: theme.accent.color,
                         onSelectTunnels: { router.popToHome() },
                         onSelectSettings: {})
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        section("Appearance") {
            GroupedCard {
                Menu {
                    ForEach(AppAppearance.allCases) { option in
                        Button(option.displayName) { theme.appearance = option }
                    }
                } label: {
                    settingsValueRow(title: "Theme", value: theme.appearance.displayName)
                }
                RowDivider()
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Text("Accent color")
                            .font(.appSans(15))
                            .foregroundColor(Palette.primaryText)
                        Spacer()
                        Text("live preview")
                            .font(.appMono(11))
                            .foregroundColor(theme.accent.color)
                    }
                    HStack(spacing: 16) {
                        ForEach(AppAccent.allCases) { accent in
                            accentSwatch(accent)
                        }
                        Spacer()
                    }
                    Text("Tints the connection hero, toggles, and active failover path across the app.")
                        .font(.appSans(11))
                        .foregroundColor(Palette.mutedText)
                }
                .padding(15)
            }
        }
    }

    private func accentSwatch(_ accent: AppAccent) -> some View {
        let isSelected = accent == theme.accent
        return Circle()
            .fill(accent.color)
            .frame(width: 40, height: 40)
            .padding(4)
            .overlay(
                Circle().strokeBorder(isSelected ? accent.color : Color.clear, lineWidth: 2)
            )
            .contentShape(Circle())
            .onTapGesture { theme.accent = accent }
    }

    // MARK: - Failover defaults

    private var failoverDefaultsSection: some View {
        section("Failover Defaults") {
            GroupedCard {
                ToggleRow(title: "Background probes",
                          isOn: Binding(
                            get: { backgroundProbeDefault },
                            set: { backgroundProbeDefault = $0; FailoverDefaults.useBackgroundProbes = $0 }),
                          accent: theme.accent.color)
                RowDivider()
                Menu {
                    ForEach(FailoverSensitivity.allCases) { option in
                        Button(option.displayName) {
                            defaultSensitivity = option
                            FailoverDefaults.sensitivity = option
                        }
                    }
                } label: {
                    settingsValueRow(title: "Default sensitivity", value: defaultSensitivity.displayName)
                }
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        section("Notifications") {
            GroupedCard {
                ToggleRow(title: "Notify on disconnect",
                          isOn: Binding(
                            get: { notifyOnDisconnect },
                            set: { handleNotificationToggle($0, isDisconnect: true) }),
                          accent: theme.accent.color)
                RowDivider()
                ToggleRow(title: "Notify on failover",
                          isOn: Binding(
                            get: { notifyOnFailover },
                            set: { handleNotificationToggle($0, isDisconnect: false) }),
                          accent: theme.accent.color)
                RowDivider()
                ToggleRow(title: "Discover public IP",
                          isOn: Binding(
                            get: { ipDiscovery },
                            set: { ipDiscovery = $0; IPDiscoverySettings.isEnabled = $0 }),
                          accent: theme.accent.color)
            }
        }
    }

    private func handleNotificationToggle(_ isOn: Bool, isDisconnect: Bool) {
        if isDisconnect { notifyOnDisconnect = isOn } else { notifyOnFailover = isOn }
        if isOn {
            requestNotificationPermission { granted in
                if granted {
                    if isDisconnect {
                        NotificationSettings.isDisconnectNotificationEnabled = true
                    } else {
                        NotificationSettings.isFailoverNotificationEnabled = true
                    }
                } else {
                    if isDisconnect { notifyOnDisconnect = false } else { notifyOnFailover = false }
                }
            }
        } else if isDisconnect {
            NotificationSettings.isDisconnectNotificationEnabled = false
        } else {
            NotificationSettings.isFailoverNotificationEnabled = false
        }
    }

    private func requestNotificationPermission(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    completion(true)
                case .notDetermined:
                    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        DispatchQueue.main.async { completion(granted) }
                    }
                default:
                    completion(false)
                }
            }
        }
    }

    // MARK: - Data & logs

    private var dataAndLogsSection: some View {
        section("Data & Logs") {
            GroupedCard {
                DisclosureRow(title: "Export tunnels", value: ".zip") { router.exportAllConfigurations() }
                RowDivider()
                DisclosureRow(title: "View log") { router.viewLog() }
                RowDivider()
                DisclosureRow(title: "Session history") { router.showSessionHistory() }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        section("About") {
            GroupedCard {
                KeyValueRow(key: "Version", value: appVersion)
                RowDivider()
                KeyValueRow(key: "Go backend", value: WIREGUARD_GO_VERSION)
            }
        }
    }

    private var appVersion: String {
        var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            version += " (\(build))"
        }
        version += " \(BUILD_COMMIT_HASH)"
        return version
    }

    // MARK: - Helpers

    private func settingsValueRow(title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.appSans(15))
                .foregroundColor(Palette.primaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(.appSans(14))
                .foregroundColor(Palette.secondaryText)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Palette.faintText)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private func section<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title)
            content()
        }
        .padding(.bottom, 18)
    }
}
