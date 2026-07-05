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
        [SchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []   // First shipped version — nothing to migrate from yet.
    }
}
