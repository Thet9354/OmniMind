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
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: OmniMindMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
