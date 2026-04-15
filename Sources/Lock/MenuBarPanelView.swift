import SwiftUI

struct MenuBarPanelView: View {
    @EnvironmentObject private var lockStore: LockStore
    @EnvironmentObject private var mainWindowController: MainWindowController
    @EnvironmentObject private var adminAuthService: AdminAuthService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AppBrandMark(size: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Lock")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)

                    Text("\(lockStore.protectedApps.count) apps protected")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }

            Divider()

            Button(action: { mainWindowController.show(section: .apps) }) {
                menuRow(title: "Add Apps", symbolName: "plus.app.fill")
            }
            .buttonStyle(.plain)

            Button(action: { mainWindowController.show(section: .settings) }) {
                menuRow(title: "Settings", symbolName: "gearshape.fill")
            }
            .buttonStyle(.plain)

            Divider()

            Button(role: .destructive, action: {
                quitLock()
            }) {
                menuRow(title: "Quit", symbolName: "power")
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 240)
        .background(Color(red: 0.13, green: 0.13, blue: 0.16))
    }

    private func menuRow(title: String, symbolName: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 18)

            Text(title)
                .foregroundStyle(.white)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func quitLock() {
        guard lockStore.hasPassword else {
            NSApplication.shared.terminate(nil)
            return
        }

        adminAuthService.authorize(reason: "Quit Lock") { success in
            if success {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
