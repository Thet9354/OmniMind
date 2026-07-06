//
//  ModelContainerFactory.swift
//  OmniMind
//
//  Single construction point for the app-wide ModelContainer.
//

import SwiftData

nonisolated enum ModelContainerFactory {
    /// Builds the app-wide container. Pass `inMemory: true` from tests and
    /// SwiftUI previews so they never touch the on-disk store.
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV2.self)
        // cloudKitDatabase MUST stay .none: with the CloudKit entitlement
        // present (Groups, Phase 14), the default .automatic silently turns
        // on CloudKit mirroring for this store — which rejects our schema
        // (unique constraints, non-optional attributes) and fails the whole
        // container at launch. Meetings are local by design; Groups sync
        // through raw CloudKit records, never through SwiftData.
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: OmniMindMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
