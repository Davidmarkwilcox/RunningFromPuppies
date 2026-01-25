// LocalScoreboardStore.swift
// Persistence
// Manages local (on-device) scoreboard storage in Core Data.
//
// Responsibilities:
// - Insert a new ScoreEntry for a completed run.
// - Prune to Top 10 scores overall (per rulesetVersion).
// - Fetch Top 10 overall (per rulesetVersion).
// - Fetch Overall Best across all players/levels for a rulesetVersion.
//
// Interactions:
// - UI/LeaderboardsView will call fetch methods (later, via a ViewModel).
// - Game end-of-run pipeline will call recordRun(...) (later, likely from GameHostView or a coordinator).
//
// Debug Mode:
// - Off by default.
// - When enabled, logs to console and can optionally write a text file to Documents for troubleshooting.
//
// Section 1: Imports

import Foundation
import CoreData

// Section 2: Public Models

struct LocalScoreSummary: Identifiable, Hashable {
    // Section 2.1: Identity
    let id: UUID

    // Section 2.2: Score fields
    let score: Int64
    let durationSeconds: Double
    let endedAt: Date

    // Section 2.3: Partition fields
    let playerId: String
    let levelNumber: Int16
    let rulesetVersion: String
}

// Section 3: Store Protocol

protocol LocalScoreboardStore {
    // Section 3.1: Writes
    func recordRun(
        playerId: String,
        levelNumber: Int16,
        score: Int64,
        durationSeconds: Double,
        endedAt: Date,
        rulesetVersion: String
    ) throws

    // Section 3.2: Reads
    func fetchTop10Overall(rulesetVersion: String) throws -> [LocalScoreSummary]

    func fetchOverallBest(rulesetVersion: String) throws -> LocalScoreSummary?
}

// Section 4: Core Data Implementation

final class CoreDataLocalScoreboardStore: LocalScoreboardStore {

    // Section 4.1: Debug
    private let debugEnabled: Bool
    private let debugFileEnabled: Bool
    private let debugFileName: String = "LocalScoreboardStore_DebugLog.txt"

    // Section 4.2: Dependencies
    private let context: NSManagedObjectContext

    // Section 4.3: Init
    init(
        context: NSManagedObjectContext,
        debugEnabled: Bool = false,
        debugFileEnabled: Bool = false
    ) {
        self.context = context
        self.debugEnabled = debugEnabled
        self.debugFileEnabled = debugFileEnabled
        dlog("Initialized (debugEnabled=\(debugEnabled), debugFileEnabled=\(debugFileEnabled))")
    }

    // Section 4.4: Public API - recordRun
    func recordRun(
        playerId: String,
        levelNumber: Int16,
        score: Int64,
        durationSeconds: Double,
        endedAt: Date,
        rulesetVersion: String = "v1"
    ) throws {
        dlog("recordRun(playerId=\(playerId), level=\(levelNumber), score=\(score), duration=\(durationSeconds), rules=\(rulesetVersion))")

        let entry = ScoreEntry(context: context)
        entry.id = UUID()
        entry.playerId = playerId
        entry.levelNumber = levelNumber
        entry.score = score
        entry.durationSeconds = durationSeconds
        entry.endedAt = endedAt
        entry.rulesetVersion = rulesetVersion

        try saveContext()

        // Prune to Top 10 for this partition.
        try pruneToTop10Overall(rulesetVersion: rulesetVersion)
    }

    // Section 4.5: Public API - fetchTop10
    func fetchTop10Overall(rulesetVersion: String = "v1") throws -> [LocalScoreSummary] {
        let request: NSFetchRequest<ScoreEntry> = ScoreEntry.fetchRequest()
        request.predicate = NSPredicate(format: "rulesetVersion == %@", rulesetVersion)
        request.sortDescriptors = scoreSortDescriptors()
        request.fetchLimit = 10

        let results = try context.fetch(request)
        dlog("fetchTop10Overall -> \(results.count) rows")
        return results.compactMap { $0.toSummary() }
    }

    // Section 4.6: Public API - fetchOverallBest
    func fetchOverallBest(rulesetVersion: String = "v1") throws -> LocalScoreSummary? {
        let request: NSFetchRequest<ScoreEntry> = ScoreEntry.fetchRequest()
        request.predicate = NSPredicate(format: "rulesetVersion == %@", rulesetVersion)
        request.sortDescriptors = scoreSortDescriptors()
        request.fetchLimit = 1

        let results = try context.fetch(request)
        let best = results.first?.toSummary()
        dlog("fetchOverallBest -> \(best?.score ?? -1)")

        return best
    }

    // Section 5: Pruning

    private func pruneToTop10Overall(rulesetVersion: String) throws {
        let request: NSFetchRequest<ScoreEntry> = ScoreEntry.fetchRequest()
        request.predicate = NSPredicate(format: "rulesetVersion == %@", rulesetVersion)
        request.sortDescriptors = scoreSortDescriptors()
        // Fetch more than 10 so we can delete overflow.
        request.fetchLimit = 200

        let results = try context.fetch(request)
        if results.count <= 10 {
            dlog("pruneToTop10Overall: no-op (count=\(results.count))")
            return
        }

        let overflow = results.dropFirst(10)
        dlog("pruneToTop10Overall: deleting \(overflow.count) overflow rows")

        overflow.forEach { context.delete($0) }
        try saveContext()
    }

    // Section 6: Fetch Request Builders
    private func scoreSortDescriptors() -> [NSSortDescriptor] {
        // Sort order:
        // 1) score DESC
        // 2) durationSeconds DESC
        // 3) endedAt ASC (stable tie-breaker)
        [
            NSSortDescriptor(key: "score", ascending: false),
            NSSortDescriptor(key: "durationSeconds", ascending: false),
            NSSortDescriptor(key: "endedAt", ascending: true)
        ]
    }

    // Section 7: Save & Error Handling

    private func saveContext() throws {
        if context.hasChanges {
            do {
                try context.save()
                dlog("context.save() OK")
            } catch {
                dlog("context.save() ERROR: \(error)")
                throw error
            }
        }
    }

    // Section 8: Debug Logging

    private func dlog(_ msg: String) {
        guard debugEnabled else { return }
        let line = "[LocalScoreboardStore] \(msg)"
        print(line)

        guard debugFileEnabled else { return }
        appendToDebugFile(line)
    }

    private func appendToDebugFile(_ line: String) {
        guard let url = debugFileURL() else { return }
        let stamped = "\(Date().iso8601String)  \(line)\n"

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                if let data = stamped.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } else {
                try stamped.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            // Avoid throwing from debug logger.
            print("[LocalScoreboardStore] Failed writing debug file: \(error)")
        }
    }

    private func debugFileURL() -> URL? {
        do {
            let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return docs.appendingPathComponent(debugFileName)
        } catch {
            return nil
        }
    }
}

// Section 9: NSManagedObject Helpers

private extension ScoreEntry {
    func toSummary() -> LocalScoreSummary? {
        guard let id = self.id,
              let endedAt = self.endedAt,
              let playerId = self.playerId,
              let rules = self.rulesetVersion
        else {
            return nil
        }

        return LocalScoreSummary(
            id: id,
            score: self.score,
            durationSeconds: self.durationSeconds,
            endedAt: endedAt,
            playerId: playerId,
            levelNumber: self.levelNumber,
            rulesetVersion: rules
        )
    }
}

// Section 10: Date Helpers

private extension Date {
    var iso8601String: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: self)
    }
}

// End of LocalScoreboardStore.swift
