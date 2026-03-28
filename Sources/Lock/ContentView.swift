import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var lockStore: LockStore
    @EnvironmentObject private var discoveryService: AppDiscoveryService
    @EnvironmentObject private var navigation: AppNavigation
    @EnvironmentObject private var permissionService: PermissionService
    @EnvironmentObject private var startupService: StartupService
    @EnvironmentObject private var activityLog: ActivityLogStore

    @State private var searchText = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var passwordMessage = ""
    @State private var passwordMessageIsError = false
    @State private var showPasswords = false

    private var filteredApps: [InstalledApp] {
        if searchText.isEmpty {
            return discoveryService.installedApps
        }

        return discoveryService.installedApps.filter { app in
            app.displayName.localizedCaseInsensitiveContains(searchText)
                || app.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.11, blue: 0.14)
                .ignoresSafeArea()

            NavigationSplitView {
                sidebar
            } detail: {
                ScrollView {
                    detailView
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.visible)
                .background(Color(red: 0.12, green: 0.13, blue: 0.17))
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar(removing: .sidebarToggle)
        }
        .task {
            discoveryService.refreshIfNeeded()
            permissionService.refreshStatuses()
            startupService.refresh()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppBrandMark(size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Lock")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)

                    Text("Menu bar app locker")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)

            List(SidebarSection.allCases, selection: $navigation.selectedSection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
                    .foregroundStyle(.white)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(red: 0.13, green: 0.13, blue: 0.16))
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 220)
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigation.selectedSection {
        case .apps:
            appsView
        case .settings:
            settingsView
        case .logs:
            logsView
        }
    }

    private var appsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(
                title: "App List",
                subtitle: "Choose which apps should require your password before they can be used."
            )

            card {
                HStack(spacing: 12) {
                    TextField("Search installed apps", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)

                    Button(discoveryService.isRefreshing ? "Refreshing..." : "Refresh", action: discoveryService.refresh)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(discoveryService.isRefreshing)
                }

                HStack {
                    Text("\(lockStore.protectedApps.count) locked")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.orange.opacity(0.9))

                    Spacer()

                    if !lockStore.hasPassword {
                        Text("Set your password first in Settings.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }

                if discoveryService.installedApps.isEmpty && discoveryService.isRefreshing {
                    ContentUnavailableView(
                        "Scanning applications...",
                        systemImage: "app.connected.to.app.below.fill",
                        description: Text("Installed apps will appear here in a moment.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 420)
                } else if filteredApps.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, minHeight: 420)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredApps) { app in
                                AppRow(
                                    app: app,
                                    icon: discoveryService.icon(for: app),
                                    isProtected: Binding(
                                        get: { lockStore.isProtected(app.bundleIdentifier) },
                                        set: { newValue in
                                            lockStore.setProtection(for: app, isProtected: newValue)
                                        }
                                    ),
                                    canProtect: lockStore.hasPassword
                                )

                                Divider()
                                    .overlay(Color.white.opacity(0.05))
                            }
                        }
                    }
                    .frame(minHeight: 420)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(
                title: "Settings",
                subtitle: "Startup, permissions, and password."
            )

            startupCard

            permissionsCard

            passwordCard
        }
    }

    private var logsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                header(
                    title: "Logs",
                    subtitle: "Recent app protection and settings activity."
                )

                Spacer()

                if !activityLog.entries.isEmpty {
                    Button("Clear", action: activityLog.clear)
                        .buttonStyle(.bordered)
                }
            }

            card {
                if activityLog.entries.isEmpty {
                    ContentUnavailableView(
                        "No Logs Yet",
                        systemImage: "clock.badge.exclamationmark",
                        description: Text("Events like password changes, lock attempts, unlocks, and permission requests will show up here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(activityLog.entries) { entry in
                            HStack(alignment: .top, spacing: 14) {
                                AppBrandMark(size: 28)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(entry.title)
                                            .font(.headline)
                                            .foregroundStyle(.white)

                                        Spacer()

                                        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.48))
                                    }

                                    if !entry.detail.isEmpty {
                                        Text(entry.detail)
                                            .font(.callout)
                                            .foregroundStyle(.white.opacity(0.65))
                                    }
                                }
                            }
                            .padding(16)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private var canSavePassword: Bool {
        !password.isEmpty && password == confirmPassword
    }

    private var startupCard: some View {
        card(title: "Startup", symbolName: "power") {
            SettingsToggleRow(
                title: "Launch Lock at login",
                subtitle: "Best used from the packaged `.app` bundle so it starts detached from Terminal.",
                isOn: Binding(
                    get: { startupService.isEnabled },
                    set: { startupService.setEnabled($0) }
                )
            )

            if !startupService.lastErrorMessage.isEmpty {
                Text(startupService.lastErrorMessage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.red.opacity(0.95))
            }
        }
    }

    private var permissionsCard: some View {
        card(title: "Permissions", symbolName: "lock.shield.fill") {
            Text("Grant the permissions needed for reliable app locking.")
                .foregroundStyle(.white.opacity(0.68))

            PermissionRow(
                title: "Accessibility",
                symbolName: "hand.raised.fill",
                granted: permissionService.accessibilityGranted,
                actionTitle: permissionService.accessibilityGranted ? "Open Settings..." : "Grant Access..."
            ) {
                if permissionService.accessibilityGranted {
                    permissionService.openAccessibilitySettings()
                } else {
                    permissionService.requestAccessibility()
                }
            }

            PermissionRow(
                title: "Screen Recording",
                symbolName: "display",
                granted: permissionService.screenRecordingGranted,
                actionTitle: permissionService.screenRecordingGranted ? "Open Settings..." : "Grant Access..."
            ) {
                if permissionService.screenRecordingGranted {
                    permissionService.openScreenRecordingSettings()
                } else {
                    permissionService.requestScreenRecording()
                }
            }
        }
    }

    private var passwordCard: some View {
        card(title: "Password", symbolName: "key.fill") {
            Text("Stored in your Keychain. Set it once, then update it whenever you want. Touch ID is also available on the lock screen when your Mac supports it.")
                .foregroundStyle(.white.opacity(0.68))

            SettingsToggleRow(
                title: "Show password while typing",
                subtitle: nil,
                isOn: $showPasswords
            )

            LabeledField(title: "Password") {
                if showPasswords {
                    TextField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                } else {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                }
            }

            LabeledField(title: "Confirm Password") {
                if showPasswords {
                    TextField("Confirm Password", text: $confirmPassword)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                } else {
                    SecureField("Confirm Password", text: $confirmPassword)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                }
            }

            HStack(spacing: 12) {
                Spacer()

                if !passwordMessage.isEmpty {
                    Text(passwordMessage)
                        .foregroundStyle(passwordMessageIsError ? Color.red.opacity(0.95) : Color.green.opacity(0.95))
                        .font(.callout.weight(.semibold))
                }

                Button(lockStore.hasPassword ? "Update Password" : "Save Password", action: savePassword)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSavePassword)
            }
        }
    }

    private func savePassword() {
        guard canSavePassword else {
            passwordMessage = "Passwords do not match."
            passwordMessageIsError = true
            return
        }

        do {
            try lockStore.updatePassword(password)
            password = ""
            confirmPassword = ""
            passwordMessage = "Password updated."
            passwordMessageIsError = false
        } catch {
            passwordMessage = "Could not save password."
            passwordMessageIsError = true
        }
    }

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<Content: View>(
        title: String? = nil,
        symbolName: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title, let symbolName {
                Label(title, systemImage: symbolName)
                    .font(.headline)
                    .foregroundStyle(.white)
            }

            content()
        }
        .padding(20)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let icon: NSImage
    @Binding var isProtected: Bool
    let canProtect: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName)
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))

                Text(app.path)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.48))
            }

            Spacer()

            Toggle("", isOn: $isProtected)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!canProtect)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.56))

            content
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundStyle(.white)

                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.58))
                }
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PermissionRow: View {
    let title: String
    let symbolName: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)

            Text(title)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)

            Spacer()

            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.green.opacity(0.95))
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
