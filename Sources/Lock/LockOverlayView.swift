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
                .fill(Color(red: 0.035, green: 0.037, blue: 0.043))
                .ignoresSafeArea()

            VStack(spacing: isCompact ? 12 : 18) {
                VStack(spacing: isCompact ? 8 : 12) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: isCompact ? 38 : 64, height: isCompact ? 38 : 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(spacing: isCompact ? 3 : 6) {
                        Text("App Locked")
                            .font(.system(size: isCompact ? 20 : 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(appName)
                            .font(.system(size: isCompact ? 12 : 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)

                        if !isCompact {
                            Text("Unlock with your password or Touch ID.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.54))
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
                                    if isCompact {
                                        Image(systemName: "touchid")
                                            .frame(minWidth: 24)
                                    } else {
                                        Label("Touch ID", systemImage: "touchid")
                                            .frame(minWidth: 74)
                                    }
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
                                .tint(.gray)

                            Button("Unlock", action: submit)
                                .buttonStyle(.borderedProminent)
                                .controlSize(isCompact ? .small : .large)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .frame(maxWidth: isCompact ? 300 : 380)
                }
            }
            .padding(.horizontal, isCompact ? 16 : 30)
            .padding(.vertical, isCompact ? 14 : 24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(height: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.38), radius: isCompact ? 12 : 22, x: 0, y: isCompact ? 6 : 12)
            .padding(isCompact ? 10 : 24)
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
