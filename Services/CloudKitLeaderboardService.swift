// CloudKitLeaderboardService.swift
// Services
// CloudKit-backed global leaderboard service (Public Database).
//
// Responsibilities:
// - Resolve a stable, privacy-preserving userHash for the current iCloud user.
// - Fetch top N GlobalScore records for a rulesetVersion (sorted by score, then duration).
// - Fetch the user's current best GlobalScore (to enforce "submit only if better").
// - Submit a new GlobalScore record, and upsert GlobalUserProfile (displayName).
//
// Notes:
// - CloudKit schema does not support "required" fields; we enforce completeness in code.
// - Indexes must exist in CloudKit Console for rulesetVersion (queryable) and score/durationSeconds (sortable).
//
// Debug Mode: Off by default.
// - Enable by passing debugEnabled=true to init.
// - When enabled, emits console logs for key operations and retry decisions.
//
// Section 1: Imports

import Foundation
import CloudKit
import CryptoKit

// Section 2: Public Models

struct GlobalLeaderboardEntry: Identifiable, Hashable {
    let id: String               // CKRecord.ID.recordName
    let displayName: String
    let score: Int64
    let durationSeconds: Double
    let playerId: String
    let levelNumber: Int
    let endedAt: Date
    let rulesetVersion: String
}

struct GlobalUserProfileSummary: Hashable {
    let userHash: String
    let displayName: String
}

// Section 3: Service

final class CloudKitLeaderboardService {

    // Section 3.1: Types

    enum ServiceError: Error, LocalizedError {
        // Expected / user-actionable
        case missingICloudAccount
        case missingDisplayName
        case invalidRun

        // Expected / environmental (tolerate quietly in gameplay paths)
        case offline
        case rateLimited(retryAfterSeconds: TimeInterval?)
        case temporarilyUnavailable

        // Unexpected / permission / schema
        case permissionDenied

        // Fallback
        case unknown(underlying: Error?)

        var errorDescription: String? {
            switch self {
            case .missingICloudAccount:
                return "iCloud is not available. Please sign into iCloud in Settings to use Global Leaderboards."
            case .missingDisplayName:
                return "Set a Global Leaderboard display name in Settings first."
            case .invalidRun:
                return "That run result is not valid for submission."
            case .offline:
                return "You appear to be offline. Global Leaderboards will update when you're back online."
            case .rateLimited(let retryAfter):
                if let retryAfter {
                    let secs = Int(max(0, retryAfter.rounded()))
                    return "CloudKit is rate-limiting requests. Please try again in about \(secs) seconds."
                }
                return "CloudKit is rate-limiting requests. Please try again shortly."
            case .temporarilyUnavailable:
                return "CloudKit is temporarily unavailable. Please try again shortly."
            case .permissionDenied:
                return "Global Leaderboards are not available due to a CloudKit permission or schema configuration issue."
            case .unknown(let underlying):
                return underlying?.localizedDescription ?? "An unknown CloudKit error occurred."
            }
        }
    }

    private enum RetryDecision {
        case doNotRetry(mapped: ServiceError)
        case retry(afterSeconds: TimeInterval, mapped: ServiceError)
    }

    // Section 3.2: Constants

    private let container: CKContainer
    private let db: CKDatabase
    private let rulesetVersion: String
    private let appSalt: String

    // Record Types / Fields
    private let scoreRecordType = "GlobalScore"
    private let profileRecordType = "GlobalUserProfile"

    // Retry tuning
    private let maxAttempts: Int = 3
    private let minBackoffSeconds: Double = 0.6
    private let maxBackoffSeconds: Double = 6.0

    // Debug
    private let debugEnabled: Bool

    // Section 3.3: Init

    init(
        containerIdentifier: String = "iCloud.com.DavidMWilcox.RunningFromPuppies",
        container: CKContainer? = nil,
        database: CKDatabase? = nil,
        rulesetVersion: String = "v1",
        appSalt: String = "RunningFromPuppies:v1",
        debugEnabled: Bool = false
    ) {
        let resolvedContainer = container ?? CKContainer(identifier: containerIdentifier)
        self.container = resolvedContainer
        self.db = database ?? resolvedContainer.publicCloudDatabase
        self.rulesetVersion = rulesetVersion
        self.appSalt = appSalt
        self.debugEnabled = debugEnabled
        dlog("Initialized (rulesetVersion=\(rulesetVersion))")
    }

    // Section 4: Identity

    /// Returns a stable, privacy-preserving user hash derived from the iCloud user record ID.
    /// We never expose raw recordName to the public leaderboard; we store only the hash.
    func resolveUserHash() async throws -> String {
        // Fail fast when the user is signed out of iCloud.
        let status = try await accountStatusAsync()
        switch status {
        case .available:
            break
        case .noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable:
            throw ServiceError.missingICloudAccount
        @unknown default:
            throw ServiceError.missingICloudAccount
        }

        let recordID: CKRecord.ID = try await withCloudKitRetries(label: "userRecordID") {
            try await self.container.userRecordID()
        }
        let raw = "\(recordID.recordName)|\(appSalt)"
        return sha256Hex(raw)
    }

    // Section 5: Reads

    func fetchTopScores(limit: Int = 25) async throws -> [GlobalLeaderboardEntry] {
        let predicate = NSPredicate(format: "rulesetVersion == %@", rulesetVersion)
        let query = CKQuery(recordType: scoreRecordType, predicate: predicate)
        query.sortDescriptors = [
            NSSortDescriptor(key: "score", ascending: false),
            NSSortDescriptor(key: "durationSeconds", ascending: false),
            NSSortDescriptor(key: "endedAt", ascending: true)
        ]

        let records = try await withCloudKitRetries(label: "fetchTopScores") {
            try await self.performQuery(query: query, resultsLimit: limit)
        }
        return records.compactMap { mapScoreRecord($0) }
    }

    func fetchUserBestScore(userHash: String) async throws -> GlobalLeaderboardEntry? {
        let predicate = NSPredicate(format: "rulesetVersion == %@ AND userHash == %@", rulesetVersion, userHash)
        let query = CKQuery(recordType: scoreRecordType, predicate: predicate)
        query.sortDescriptors = [
            NSSortDescriptor(key: "score", ascending: false),
            NSSortDescriptor(key: "durationSeconds", ascending: false),
            NSSortDescriptor(key: "endedAt", ascending: true)
        ]

        let records = try await withCloudKitRetries(label: "fetchUserBestScore") {
            try await self.performQuery(query: query, resultsLimit: 1)
        }
        return records.first.flatMap { mapScoreRecord($0) }
    }

    // Section 6: Writes

    /// Upserts the user's public profile (GlobalUserProfile) and conditionally submits a new GlobalScore.
    /// Rule: submit only if score > user's current global best score (for this rulesetVersion).
    func submitIfNewBest(
        displayName: String,
        playerId: String,
        levelNumber: Int,
        score: Int64,
        durationSeconds: Double,
        endedAt: Date
    ) async throws -> Bool {

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ServiceError.missingDisplayName }
        guard !playerId.isEmpty, levelNumber > 0, score >= 0, durationSeconds >= 0 else { throw ServiceError.invalidRun }

        let userHash = try await resolveUserHash()

        // Ensure profile exists/updated.
        try await withCloudKitRetries(label: "upsertUserProfile") {
            try await self.upsertUserProfile(userHash: userHash, displayName: trimmedName)
        }

        // Fetch current global best for this user.
        let best = try await fetchUserBestScore(userHash: userHash)
        if let best, score <= best.score {
            // Only update global leaderboard on strict improvement.
            return false
        }

        // Create a new score record (append-only; easy to audit).
        let record = CKRecord(recordType: scoreRecordType)
        record["score"] = score as CKRecordValue
        record["durationSeconds"] = durationSeconds as CKRecordValue
        record["playerId"] = playerId as CKRecordValue
        record["levelNumber"] = Int64(levelNumber) as CKRecordValue
        record["endedAt"] = endedAt as CKRecordValue
        record["rulesetVersion"] = rulesetVersion as CKRecordValue
        record["displayName"] = trimmedName as CKRecordValue
        record["userHash"] = userHash as CKRecordValue

        _ = try await withCloudKitRetries(label: "save(GlobalScore)") {
            try await self.db.save(record)
        }
        return true
    }

    // Section 7: Profile Upsert

    private func upsertUserProfile(userHash: String, displayName: String) async throws {
        // Look for existing profile by userHash.
        let predicate = NSPredicate(format: "userHash == %@", userHash)
        let query = CKQuery(recordType: profileRecordType, predicate: predicate)

        let existing = try await performQuery(query: query, resultsLimit: 1).first

        let record: CKRecord
        if let existing {
            record = existing
        } else {
            record = CKRecord(recordType: profileRecordType)
            record["userHash"] = userHash as CKRecordValue
        }

        record["displayName"] = displayName as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue

        _ = try await db.save(record)
    }

    // Section 8: Query Operation Wrapper

    private func performQuery(query: CKQuery, resultsLimit: Int) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { continuation in
            var fetched: [CKRecord] = []

            let op = CKQueryOperation(query: query)
            op.resultsLimit = resultsLimit

            if #available(iOS 15.0, *) {
                op.recordMatchedBlock = { _, result in
                    switch result {
                    case .success(let record):
                        fetched.append(record)
                    case .failure:
                        break
                    }
                }
                op.queryResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: fetched)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            } else {
                op.recordFetchedBlock = { record in
                    fetched.append(record)
                }
                op.queryCompletionBlock = { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: fetched)
                    }
                }
            }

            self.db.add(op)
        }
    }

    // Section 9: Retry Wrapper + Error Mapping

    private func withCloudKitRetries<T>(
        label: String,
        operation: @escaping () async throws -> T
    ) async throws -> T {

        var attempt = 0
        var lastMapped: ServiceError = .unknown(underlying: nil)

        while attempt < maxAttempts {
            attempt += 1
            do {
                dlog("\(label): attempt \(attempt)/\(maxAttempts)")
                let value = try await operation()
                if attempt > 1 { dlog("\(label): recovered on attempt \(attempt)") }
                return value
            } catch {
                let decision = retryDecision(for: error, attempt: attempt)
                switch decision {
                case .doNotRetry(let mapped):
                    dlog("\(label): not retrying (\(mapped))")
                    throw mapped

                case .retry(let afterSeconds, let mapped):
                    lastMapped = mapped
                    if attempt >= maxAttempts {
                        dlog("\(label): exhausted retries; throwing \(mapped)")
                        throw mapped
                    }

                    // Clamp, add a small jitter to avoid herd effects.
                    let jitter = Double.random(in: 0.0...0.25)
                    let sleepSeconds = min(max(afterSeconds + jitter, minBackoffSeconds), maxBackoffSeconds)
                    dlog("\(label): retrying in ~\(String(format: "%.2f", sleepSeconds))s due to \(mapped)")

                    let nanos = UInt64(sleepSeconds * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanos)
                }
            }
        }

        // Defensive fallback (shouldn't happen).
        throw lastMapped
    }

    private func retryDecision(for error: Error, attempt: Int) -> RetryDecision {
        // Prefer explicit CloudKit error codes.
        if let ck = error as? CKError {
            switch ck.code {

            // Signed out / no account
            case .notAuthenticated:
                return .doNotRetry(mapped: .missingICloudAccount)

            // Offline / network problems
            case .networkUnavailable, .networkFailure:
                return .doNotRetry(mapped: .offline)

            // Transient server-side issues
            case .serviceUnavailable, .zoneBusy, .requestRateLimited, .limitExceeded:
                let retryAfter = retryAfterSeconds(from: ck)
                let base = retryAfter ?? exponentialBackoffSeconds(forAttempt: attempt)
                let mapped: ServiceError = (ck.code == .requestRateLimited || ck.code == .limitExceeded)
                    ? .rateLimited(retryAfterSeconds: retryAfter)
                    : .temporarilyUnavailable
                return .retry(afterSeconds: base, mapped: mapped)

            // Permission / schema problems
            case .permissionFailure, .notAuthenticated, .badContainer, .badDatabase, .invalidArguments:
                return .doNotRetry(mapped: .permissionDenied)

            default:
                // Unknown CKError — don't retry blindly.
                return .doNotRetry(mapped: .unknown(underlying: ck))
            }
        }

        // Non-CloudKit error type — pass through.
        return .doNotRetry(mapped: .unknown(underlying: error))
    }

    private func retryAfterSeconds(from ckError: CKError) -> TimeInterval? {
        // CloudKit uses CKErrorRetryAfterKey for throttling/backoff hints.
        if let n = ckError.userInfo[CKErrorRetryAfterKey] as? NSNumber {
            return n.doubleValue
        }
        if let d = ckError.userInfo[CKErrorRetryAfterKey] as? Double {
            return d
        }
        return nil
    }

    private func exponentialBackoffSeconds(forAttempt attempt: Int) -> TimeInterval {
        // attempt: 1 => ~0.6s, 2 => ~1.2s, 3 => ~2.4s (clamped elsewhere)
        let pow2 = pow(2.0, Double(max(0, attempt - 1)))
        return minBackoffSeconds * pow2
    }

    private func accountStatusAsync() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { status, error in
                if let error {
                    // If account status cannot be determined, treat as "missing account" upstream.
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    // Section 10: Mapping

    private func mapScoreRecord(_ r: CKRecord) -> GlobalLeaderboardEntry? {
        guard let displayName = r["displayName"] as? String,
              let score = r["score"] as? Int64,
              let durationSeconds = r["durationSeconds"] as? Double,
              let playerId = r["playerId"] as? String,
              let levelNumber = r["levelNumber"] as? Int64,
              let endedAt = r["endedAt"] as? Date,
              let rules = r["rulesetVersion"] as? String
        else { return nil }

        return GlobalLeaderboardEntry(
            id: r.recordID.recordName,
            displayName: displayName,
            score: score,
            durationSeconds: durationSeconds,
            playerId: playerId,
            levelNumber: Int(levelNumber),
            endedAt: endedAt,
            rulesetVersion: rules
        )
    }

    // Section 11: Hashing

    private func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // Section 12: Debug Logging

    private func dlog(_ msg: String) {
        guard debugEnabled else { return }
        print("[CloudKitLeaderboardService] \(msg)")
    }
}

// End of CloudKitLeaderboardService.swift
