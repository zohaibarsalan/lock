import AppKit
import SwiftUI

struct LockOverlayView: View {
    let appName: String
    let appIcon: NSImage
    let touchIDAvailable: Bool
    let showsControls: Bool
    let onUnlock: (String) -> Bool
    let onTouchID: () -> Void
    let onQuit: () -> Void

    @State private var password = ""
    @State private var errorMessage = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            overlayContent(isCompact: proxy.size.width < 520 || proxy.size.height < 380)
        }
        .onAppear {
            if showsControls {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    passwordFocused = true
                }
            }
        }
    }

    private func overlayContent(isCompact: Bool) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.84))
                .ignoresSafeArea()

            VStack(spacing: isCompact ? 12 : 22) {
                VStack(spacing: isCompact ? 8 : 14) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: isCompact ? 40 : 72, height: isCompact ? 40 : 72)
                        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 10 : 18, style: .continuous))

                    VStack(spacing: isCompact ? 4 : 8) {
                        Text("Locked")
                            .font(.system(size: isCompact ? 22 : 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(appName)
                            .font(.system(size: isCompact ? 13 : 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)

                        if !isCompact {
                            Text("Enter your password to keep using this app.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.64))
                                .multilineTextAlignment(.center)
                        }
                    }
                }

                if showsControls {
                    VStack(spacing: isCompact ? 8 : 12) {
                        HStack(spacing: 10) {
                            SecureField("Enter password", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(isCompact ? .regular : .large)
                                .focused($passwordFocused)
                                .onSubmit(submit)

                            if touchIDAvailable {
                                Button(action: onTouchID) {
                                    Image(systemName: "touchid")
                                        .frame(width: 18, height: 18)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(isCompact ? .regular : .large)
                            }
                        }

                        if !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font((isCompact ? Font.caption : Font.callout).weight(.semibold))
                                .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.48))
                        }

                        HStack(spacing: 10) {
                            Button("Quit App", action: onQuit)
                                .buttonStyle(.bordered)
                                .controlSize(isCompact ? .small : .large)
                                .tint(.white.opacity(0.2))

                            Button("Unlock", action: submit)
                                .buttonStyle(.borderedProminent)
                                .controlSize(isCompact ? .small : .large)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .frame(maxWidth: isCompact ? 280 : 360)
                }
            }
            .padding(.horizontal, isCompact ? 18 : 34)
            .padding(.vertical, isCompact ? 14 : 26)
            .background(
                RoundedRectangle(cornerRadius: isCompact ? 8 : 12, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: isCompact ? 8 : 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.32), radius: isCompact ? 12 : 24, x: 0, y: isCompact ? 6 : 14)
            .padding(isCompact ? 8 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
