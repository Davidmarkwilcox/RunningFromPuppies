// LeaderboardsView.swift
// UI
// Leaderboards screen for Running From Puppies.
//
// Responsibilities:
// - Local: Show overall best and Top 10 overall from Core Data.
// - Global: Fetch and display Top 25 from CloudKit Public Database; allow submitting the user's best run.
//
// Interactions:
// - Presented inside StartScreenView's translucent ModalOverlay container.
// - Local reads: CoreDataLocalScoreboardStore
// - Global reads/writes: CloudKitLeaderboardService
//
// Debug Mode: Off by default.
//
// Section 1: Imports

import SwiftUI
import CoreData

// Section 2: Types

private enum LeaderboardScope: String, CaseIterable, Identifiable {
    case local = "Local"
    case global = "Global"

    var id: String { rawValue }
}

// Section 3: View

struct LeaderboardsView: View {

    // Section 3.1: Environment
    @Environment(\.managedObjectContext) private var viewContext

    // Section 3.2: Stored settings (used for global submissions)
    @AppStorage("globalDisplayName") private var globalDisplayName: String = ""

    // Section 3.3: UI State
    @State private var scope: LeaderboardScope = .local

    // Section 3.4: Data State (Local)
    @State private var overallBest: LocalScoreSummary?
    @State private var top10Overall: [LocalScoreSummary] = []
    @State private var localLoadError: String?

    // Section 3.5: Data State (Global)
    @State private var globalTop: [GlobalLeaderboardEntry] = []
    @State private var globalLoadError: String?
    @State private var isGlobalBusy: Bool = false
    @State private var isAdvancedExpanded: Bool = false
    @State private var lastGlobalSubmitMessage: String?

    // Section 3.6: Constants
    private let rulesetVersion: String = "v1"

    // Section 4: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Top padding so controls do not sit beneath overlay nav bar/title.
                Color.clear.frame(height: 56)

                segmentedScopePicker

                if scope == .local {
                    overallBestCard
                    top10OverallCard
                    if let localLoadError {
                        errorText(localLoadError)
                    }
                }

                if scope == .global {
                    globalActionsCard
                    globalTopCard
                    if let globalLoadError {
                        errorText(globalLoadError)
                    }
}

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            reloadLocal(force: true)
            Task { await reloadGlobal(force: true) }
        }
        .onChange(of: scope) { _, newScope in
            if newScope == .local {
                reloadLocal(force: true)
            } else {
                Task { await reloadGlobal(force: true) }
            }
        }
    }

    // Section 5: Components

    private var segmentedScopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(LeaderboardScope.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var overallBestCard: some View {
        HudCard(title: "Overall Best", subtitle: "Your best run across all sessions") {
            if let best = overallBest {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(formatScore(best.score))
                            .font(.system(size: 44, weight: .bold, design: .default))
                            .foregroundStyle(.black)

                        HStack(spacing: 8) {
                            tagPill(best.playerId)
                            tagPill("Level \(best.levelNumber)")
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 10) {
                        Text(formatDuration(best.durationSeconds))
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(.black.opacity(0.65))
                            .monospacedDigit()

                        Text(formatDate(best.endedAt))
                            .font(.footnote)
                            .foregroundStyle(.black.opacity(0.55))
                    }
                }
            } else {
                Text("No runs recorded yet.")
                    .foregroundStyle(.black.opacity(0.7))
                    .padding(.vertical, 8)
            }
        }
    }

    private var top10OverallCard: some View {
        HudCard(title: "Top 10 (Local)", subtitle: "Best sessions (no filtering)") {
            if top10Overall.isEmpty {
                Text("No local scores yet.")
                    .foregroundStyle(.black.opacity(0.7))
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(top10Overall.enumerated()), id: \.element.id) { index, item in
                        localRow(rank: index + 1, item: item)
                    }
                }
            }
        }
    }

    private var globalActionsCard: some View {
        HudCard(title: "Global", subtitle: "Public leaderboard (CloudKit)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button {
                        Task { await reloadGlobal(force: true) }
                    } label: {
                        Text(isGlobalBusy ? "Refreshing…" : "Refresh Global")
                    }
                    .disabled(isGlobalBusy)
                    .buttonStyle(.bordered)

                    Spacer()
                }

                Text("Scores are submitted automatically at run end when you set a display name in Settings. Manual submit is available for troubleshooting.")
                    .font(.caption)
                    .foregroundStyle(.black.opacity(0.55))

                DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            Task { await submitOverallBestIfPossible() }
                        } label: {
                            Text("Submit Now (Manual)")
                        }
                        .disabled(isGlobalBusy)
                        .buttonStyle(.bordered)

                        if let lastGlobalSubmitMessage {
                            Text(lastGlobalSubmitMessage)
                                .font(.footnote)
                                .foregroundStyle(.black.opacity(0.65))
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

private var globalTopCard: some View {
        HudCard(title: "Top 25 (Global)", subtitle: "") {
            if isGlobalBusy && globalTop.isEmpty {
                Text("Loading…")
                    .foregroundStyle(.black.opacity(0.7))
                    .padding(.vertical, 6)
            } else if globalTop.isEmpty {
                Text("No global scores yet.")
                    .foregroundStyle(.black.opacity(0.7))
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(globalTop.enumerated()), id: \.element.id) { index, item in
                        globalRow(rank: index + 1, item: item)
                    }
                }
            }
        }
    }

    private func localRow(rank: Int, item: LocalScoreSummary) -> some View {
        HStack(spacing: 10) {
            rankBadge(rank)

            VStack(alignment: .leading, spacing: 2) {
                Text(formatScore(item.score))
                    .font(.headline)
                    .foregroundStyle(.black)
                    .monospacedDigit()
                Text("\(item.playerId) • Level \(item.levelNumber)")
                    .font(.caption2)
                    .foregroundStyle(.black.opacity(0.55))
            }

            Spacer()

            Text(formatDuration(item.durationSeconds))
                .font(.subheadline)
                .foregroundStyle(.black.opacity(0.65))
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func globalRow(rank: Int, item: GlobalLeaderboardEntry) -> some View {
        HStack(spacing: 10) {
            rankBadge(rank)

            VStack(alignment: .leading, spacing: 2) {
                Text(formatScore(item.score))
                    .font(.headline)
                    .foregroundStyle(.black)
                    .monospacedDigit()

                Text("\(item.displayName) • \(item.playerId) • Level \(item.levelNumber)")
                    .font(.caption2)
                    .foregroundStyle(.black.opacity(0.55))
            }

            Spacer()

            Text(formatDuration(item.durationSeconds))
                .font(.subheadline)
                .foregroundStyle(.black.opacity(0.65))
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func errorText(_ msg: String) -> some View {
        Text(msg)
            .font(.footnote)
            .foregroundStyle(.red.opacity(0.95))
            .padding(.top, 6)
    }

    // Section 6: Local Loading (Core Data)

    private func reloadLocal(force: Bool) {
        let store = CoreDataLocalScoreboardStore(context: viewContext)

        do {
            // Overall best (single row for the header card)
            overallBest = try store.fetchOverallBest(rulesetVersion: rulesetVersion)

            // Top 10 overall (for the list card)
            top10Overall = try store.fetchTop10Overall(rulesetVersion: rulesetVersion)

            localLoadError = nil
        } catch {
            localLoadError = "Failed loading local scores: \(error.localizedDescription)"
            top10Overall = []
            overallBest = nil
        }
    }


// Section 7: Global Loading / Submission (CloudKit)

    private func reloadGlobal(force: Bool) async {
        guard !isGlobalBusy else { return }
        isGlobalBusy = true
        defer { isGlobalBusy = false }

        do {
            let svc = CloudKitLeaderboardService(rulesetVersion: rulesetVersion)
            globalTop = try await svc.fetchTopScores(limit: 25)
            globalLoadError = nil
        } catch {
            globalLoadError = "Failed loading global scores: \(error.localizedDescription)"
        }
    }

    private func submitOverallBestIfPossible() async {
        guard !isGlobalBusy else { return }

        let name = globalDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            lastGlobalSubmitMessage = "Set a Global Leaderboard display name in Settings first."
            return
        }
        guard let best = overallBest else {
            lastGlobalSubmitMessage = "No local best score found yet."
            return
        }

        isGlobalBusy = true
        defer { isGlobalBusy = false }

        do {
            let svc = CloudKitLeaderboardService(rulesetVersion: rulesetVersion)
            let didSubmit = try await svc.submitIfNewBest(
                displayName: name,
                playerId: best.playerId,
                levelNumber: Int(best.levelNumber),
                score: best.score,
                durationSeconds: best.durationSeconds,
                endedAt: best.endedAt
            )
            lastGlobalSubmitMessage = didSubmit ? "Submitted new global best." : "No submission: your global best is already higher (or equal)."
            await reloadGlobal(force: true)
        } catch {
            lastGlobalSubmitMessage = "Submit failed: \(error.localizedDescription)"
        }
    }

    // Section 8: Styling Helpers

    private func rankBadge(_ rank: Int) -> some View {
        Text("#\(rank)")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.black.opacity(0.85))
            .frame(width: 38, height: 26)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            )
    }

    private func tagPill(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(.black.opacity(0.75))
            .background(.white.opacity(0.22), in: Capsule())
    }

    private func formatScore(_ score: Int64) -> String {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        return n.string(from: NSNumber(value: score)) ?? "\(score)"
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00.0" }
        let mins = Int(seconds) / 60
        let secs = seconds - Double(mins * 60)
        return String(format: "%02d:%04.1f", mins, secs)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// Section 9: HUD Card

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

// End of LeaderboardsView.swift
