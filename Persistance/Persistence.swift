// Persistence.swift
// Persistence
// Provides the Core Data stack for Running From Puppies.
//
// Interaction notes:
// - RunningFromPuppiesApp injects the viewContext into SwiftUI environment.
// - Local scoreboards will be stored in Core Data entities (e.g., ScoreEntry).
// - Global leaderboards will use CloudKit directly (public database) and are intentionally NOT mirrored via Core Data.
//
// Debug Mode:
// - Off by default. When enabled, prints key lifecycle events to console.
//
// Section 1: Imports

import CoreData

// Section 2: PersistenceController

struct PersistenceController {

    // Section 2.1: Debug
    private static let debugEnabled: Bool = false
    private static func dlog(_ msg: String) {
        guard debugEnabled else { return }
        print("[PersistenceController] \(msg)")
    }

    // Section 2.2: Shared
    static let shared = PersistenceController()

    // Section 2.3: Preview (in-memory)
    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext

        // NOTE: The default SwiftUI Core Data template uses an Item entity.
        // If you are no longer using Item, you can remove this block.
        for _ in 0..<10 {
            let newItem = Item(context: viewContext)
            newItem.timestamp = Date()
        }

        do {
            try viewContext.save()
        } catch {
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }
        return result
    }()

    // Section 2.4: Container
    //
    // IMPORTANT:
    // We intentionally use NSPersistentContainer (NOT NSPersistentCloudKitContainer).
    // Global leaderboards will be stored in CloudKit public database directly, not via Core Data mirroring.
    let container: NSPersistentContainer

    // Section 2.5: Init
    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "RunningFromPuppies")

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                // Typical reasons for an error here include:
                // * The parent directory does not exist, cannot be created, or disallows writing.
                // * The persistent store is not accessible due to permissions or data protection when the device is locked.
                // * The device is out of space.
                // * The store could not be migrated to the current model version.
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }

            Self.dlog("Loaded store: \(storeDescription.url?.absoluteString ?? "(nil)")")
        }

        // Merge changes when background contexts write.
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}

// End of Persistence.swift
