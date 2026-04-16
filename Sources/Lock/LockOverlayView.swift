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
      Color(nsColor: .windowBackgroundColor)
        .ignoresSafeArea()

      VStack(spacing: 0) {
        Spacer(minLength: 0)

        VStack(spacing: 16) {
          Image(nsImage: appIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: 48, height: 48)

          Text(appName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          VStack(spacing: 6) {
            passwordField

            if !errorMessage.isEmpty {
              Text(errorMessage)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }

          HStack(spacing: 10) {
            if touchIDAvailable {
              Button(action: onTouchID) {
                Label("Touch ID", systemImage: "touchid")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(LockSecondaryButtonStyle())
            }

            Button("Unlock", action: submit)
              .frame(maxWidth: .infinity)
              .buttonStyle(LockPrimaryButtonStyle())
              .keyboardShortcut(.defaultAction)
          }

          Button("Quit App", action: onQuit)
            .buttonStyle(LockQuitButtonStyle())
            .padding(.top, 2)
        }
        .frame(maxWidth: 340)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)

        Spacer(minLength: 0)
      }
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        passwordFocused = true
      }
    }
  }

  private var passwordField: some View {
    SecureField("Enter password", text: $password)
      .textFieldStyle(.plain)
      .font(.system(size: 14, weight: .regular))
      .focused($passwordFocused)
      .onSubmit(submit)
      .padding(.horizontal, 12)
      .frame(height: 36)
      .background(Color(nsColor: .controlBackgroundColor))
      .overlay(
        Rectangle()
          .stroke(
            passwordFocused
              ? Color.accentColor
              : Color(nsColor: .separatorColor),
            lineWidth: passwordFocused ? 2 : 1
          )
      )
  }

  private func submit() {
    guard !password.isEmpty else {
      errorMessage = "Enter the password first."
      passwordFocused = true
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

private struct LockPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(.white)
      .frame(height: 34)
      .background(
        Rectangle()
          .fill(Color.accentColor.opacity(configuration.isPressed ? 0.82 : 1))
      )
      .contentShape(Rectangle())
  }
}

private struct LockSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(.primary)
      .frame(height: 34)
      .background(
        Rectangle()
          .fill(Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        Rectangle()
          .stroke(
            Color(nsColor: .separatorColor).opacity(configuration.isPressed ? 0.75 : 1),
            lineWidth: 1
          )
      )
      .contentShape(Rectangle())
  }
}

private struct LockQuitButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(.secondary.opacity(configuration.isPressed ? 0.65 : 1))
      .contentShape(Rectangle())
  }
}
