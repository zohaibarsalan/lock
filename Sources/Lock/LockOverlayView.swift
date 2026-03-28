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
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.58))
                .ignoresSafeArea()

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.07),
                            Color.clear,
                            Color.black.opacity(0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .ignoresSafeArea()

            VStack(spacing: 26) {
                VStack(spacing: 16) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 78, height: 78)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    VStack(spacing: 10) {
                        Text("Locked")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(appName)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))

                        Text("Enter your password to keep using this app.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.64))
                            .multilineTextAlignment(.center)
                    }
                }

                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        SecureField("Enter password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .focused($passwordFocused)
                            .onSubmit(submit)

                        if touchIDAvailable {
                            Button(action: onTouchID) {
                                Image(systemName: "touchid")
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.48))
                    }

                    HStack(spacing: 10) {
                        Button("Quit App", action: onQuit)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .tint(.white.opacity(0.2))

                        Button("Unlock", action: submit)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .frame(maxWidth: 360)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 28, x: 0, y: 18)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                passwordFocused = true
            }
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
