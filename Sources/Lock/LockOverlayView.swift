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

      VStack {
        Spacer(minLength: 32)

        VStack(spacing: 22) {
          header
          formSection
          actionSection
        }
        .frame(maxWidth: 340)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)

        Spacer(minLength: 32)
      }
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        passwordFocused = true
      }
    }
  }

  private var header: some View {
    VStack(spacing: 8) {
      Image(nsImage: appIcon)
        .resizable()
        .interpolation(.high)
        .frame(width: 64, height: 64)

      Text(appName)
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)

      Text("Unlock to continue")
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  private var formSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Password")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)

      SecureField("Enter your password", text: $password)
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .font(.system(size: 15))
        .focused($passwordFocused)
        .onSubmit(submit)
        .frame(maxWidth: .infinity)
        .frame(height: 38)

      if !errorMessage.isEmpty {
        Text(errorMessage)
          .font(.system(size: 12))
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var actionSection: some View {
    VStack(spacing: 14) {
      HStack(spacing: 14) {
        if touchIDAvailable {
          Button(action: onTouchID) {
            Label("Touch ID", systemImage: "touchid")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.large)
        }

        Button(action: submit) {
          Text("Unlock")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
      }

      Button("Quit App", action: onQuit)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  private func submit() {
    let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedPassword.isEmpty else {
      errorMessage = "Enter the password first."
      passwordFocused = true
      return
    }

    if onUnlock(trimmedPassword) {
      errorMessage = ""
      password = ""
    } else {
      password = ""
      errorMessage = "Incorrect password."
      passwordFocused = true
    }
  }
}
