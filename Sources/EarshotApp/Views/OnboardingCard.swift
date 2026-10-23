import SwiftUI

struct OnboardingCard: View {
    var outdated: Bool
    var install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(outdated ? "Update Claude Code hooks" : "Connect Claude Code")
                .font(.system(size: 13, weight: .semibold))
            Text(outdated
                 ? "The hooks in settings.json point to another copy of Earshot. Reinstall them for this one."
                 : "Earshot listens to Claude Code hooks. Install them once to see live status and answer permission requests from the notch.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(outdated ? "Reinstall hooks" : "Install hooks", action: install)
                    .buttonStyle(PillButtonStyle(kind: .primary))
                Text("Running sessions show live status after a restart.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.module))
    }
}

struct JumpHint: View {
    var problem: JumpProblem
    var fix: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow Earshot to control \(problem.app)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.clayLabel)
                Text("Needed to switch to the right tab")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Later", action: dismiss)
                .buttonStyle(PillButtonStyle(kind: .ghost, height: 26))
            Button("Open Settings", action: fix)
                .buttonStyle(PillButtonStyle(kind: .primary, height: 26))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.module))
    }
}
