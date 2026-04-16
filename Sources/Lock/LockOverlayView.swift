import AppKit
import SwiftUI

struct LockOverlayView: View {
    let appName: String
    let appIcon: NSImage
    let touchIDAvailable: Bool
    let onUnlock: (String) -> Bool
    let onTouchID: () -> Void
    let onQuit: () -> Void

    @State private var password = ""
    @State private var errorMessage = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 360 || proxy.size.height < 270

            Group {
                if compact {
                    compactContent
                } else {
                    regularContent
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                passwordFocused = true
            }
        }
    }

    private var regularContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            header(iconSize: 48, titleSize: 20, appNameSize: 13)

            VStack(alignment: .leading, spacing: 8) {
                Text("Password")
                    .font(.callout.weight(.semibold))

                passwordRow(controlSize: .large, touchIDLabel: "Touch ID")

                errorText
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button("Quit App", action: onQuit)
                    .controlSize(.large)

                Spacer(minLength: 0)

                Button("Unlock", action: submit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 520, maxHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(iconSize: 30, titleSize: 15, appNameSize: 11)

            passwordRow(controlSize: .small, touchIDLabel: "Touch ID")

            errorText

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button("Quit", action: onQuit)
                    .controlSize(.small)

                Spacer(minLength: 0)

                Button("Unlock", action: submit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func header(iconSize: CGFloat, titleSize: CGFloat, appNameSize: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("Unlock Required")
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(appName)
                    .font(.system(size: appNameSize, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func passwordRow(controlSize: ControlSize, touchIDLabel: String) -> some View {
        HStack(spacing: 8) {
            SecureField("Enter password", text: $password)
                .textFieldStyle(.roundedBorder)
                .controlSize(controlSize)
                .focused($passwordFocused)
                .onSubmit(submit)

            if touchIDAvailable {
                Button(action: onTouchID) {
                    Label(touchIDLabel, systemImage: "touchid")
                }
                .controlSize(controlSize)
            }
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if !errorMessage.isEmpty {
            Text(errorMessage)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func submit() {
        guard !password.isEmpty else {
            errorMessage = "Enter the password first."
            return
        }

        if onUnlock(password) {
            errorMessage = ""
            password = ""
        } else {
            password = ""
            errorMessage = "Wrong password."
            passwordFocused = true
        }
    }
}
