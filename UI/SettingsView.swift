// SettingsView.swift
// UI
// Settings screen for Running From Puppies.
//
// Responsibilities:
// - Allow the player to configure persisted preferences.
// - Stage edits locally and only persist when the user taps Save.
//
// Presentation notes:
// - Presented inside StartScreenView's translucent ModalOverlay container (same as LeaderboardsView).
// - Uses the same HUD-style cards and ScrollView layout as LeaderboardsView to match translucency.
//
// Current settings:
// - Global leaderboard display name (used for Cloud leaderboard submissions)
//
// Debug Mode: Off by default.
//
// Section 1: Imports

import SwiftUI

struct SettingsView: View {

    // Section 2: Debug toggle
    private let debugMode: Bool = false

    // Section 3: Stored settings (persisted)
    @AppStorage("globalDisplayName") private var globalDisplayName: String = ""

    // Section 3.1: Draft settings (staged, not persisted until Save)
    @State private var draftGlobalDisplayName: String = ""
    @State private var hasUnsavedChanges: Bool = false

    // Section 4: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Top padding so controls do not sit beneath overlay nav bar/title (matches LeaderboardsView).
                Color.clear.frame(height: 56)

                globalLeaderboardCard

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            // Initialize draft from persisted settings
            draftGlobalDisplayName = globalDisplayName
            hasUnsavedChanges = false
            if debugMode { print("[SettingsView] onAppear -> loaded draftGlobalDisplayName=\(draftGlobalDisplayName)") }
        }
    }

    // Section 5: Components

    private var globalLeaderboardCard: some View {
        HudCard(title: "Global Leaderboard", subtitle: "Used for CloudKit submissions") {
            VStack(alignment: .leading, spacing: 10) {
                // Display name editor row (matches the row pill style used in LeaderboardsView tables)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Display Name")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.black.opacity(0.65))

                    TextField("Enter a display name", text: $draftGlobalDisplayName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(false)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.white.opacity(0.10), lineWidth: 1)
                        )
                        .onChange(of: draftGlobalDisplayName) { _, newValue in
                            hasUnsavedChanges = (newValue != globalDisplayName)
                            if debugMode { print("[SettingsView] draftGlobalDisplayName updated: \(newValue) (dirty=\(hasUnsavedChanges))") }
                        }
                }

                Text("Scores submit automatically at run end when you set a display name. Tap Save to apply changes.")
                    .font(.caption)
                    .foregroundStyle(.black.opacity(0.55))

                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        if debugMode { print("[SettingsView] Clear draftGlobalDisplayName tapped") }
                        draftGlobalDisplayName = ""
                        hasUnsavedChanges = (draftGlobalDisplayName != globalDisplayName)
                    } label: {
                        Text("Clear")
                    }
                    .buttonStyle(.bordered)
                    .disabled(draftGlobalDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    Button {
                        saveDraft()
                    } label: {
                        Text("Save")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasUnsavedChanges)
                }

                if hasUnsavedChanges {
                    Text("Unsaved changes")
                        .font(.footnote)
                        .foregroundStyle(.black.opacity(0.65))
                } else if !globalDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Currently saved: \(globalDisplayName)")
                        .font(.footnote)
                        .foregroundStyle(.black.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    // Section 6: Save

    private func saveDraft() {
        globalDisplayName = draftGlobalDisplayName
        hasUnsavedChanges = false
        if debugMode { print("[SettingsView] Save tapped -> globalDisplayName persisted: \(globalDisplayName)") }
    }
}

// Section 7: HUD Card (copied to match LeaderboardsView translucency)

private struct HudCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.black)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.black.opacity(0.55))
                }
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
    }
}

// End of SettingsView.swift
