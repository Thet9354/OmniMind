//
//  OmniMindMigrationPlan.swift
//  OmniMind
//
//  Migration spine. V1 is the root; every future schema change adds a new
//  VersionedSchema and a MigrationStage here — shipped versions are never
//  mutated in place.
//

import SwiftData

nonisolated enum OmniMindMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            // V2 only ADDS optional columns (persisted AI outputs on
            // Meeting), so SwiftData can migrate rows in place.
            .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)
        ]
    }
}
