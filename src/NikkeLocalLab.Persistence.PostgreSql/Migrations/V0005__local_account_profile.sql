CREATE SCHEMA lab_profile;

CREATE FUNCTION lab_profile.valid_fact(
    status_value TEXT,
    has_value BOOLEAN,
    reason_code TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE status_value
        WHEN 'ready' THEN has_value AND reason_code IS NULL
        WHEN 'unresolved' THEN NOT has_value AND reason_code IS NOT NULL
        WHEN 'not_applicable' THEN NOT has_value AND reason_code IS NULL
        ELSE FALSE
    END;
$$;

ALTER TABLE lab_catalog.character_catalog_snapshot
    ADD CONSTRAINT uq_character_catalog_profile_binding
    UNIQUE (character_catalog_snapshot_id, dataset_snapshot_id, catalog_manifest_sha256);

ALTER TABLE lab_catalog.character_catalog_snapshot_member
    ADD CONSTRAINT uq_character_catalog_profile_member
    UNIQUE (
        character_catalog_snapshot_id,
        character_entity_id,
        character_definition_version_id
    );

ALTER TABLE lab_combat_support.catalog_snapshot
    ADD CONSTRAINT uq_support_catalog_profile_binding
    UNIQUE (catalog_snapshot_id, dataset_snapshot_id, catalog_manifest_sha256);

ALTER TABLE lab_combat_support.catalog_snapshot_member
    ADD CONSTRAINT uq_support_catalog_profile_member
    UNIQUE (
        catalog_snapshot_id,
        definition_entity_id,
        definition_version_id,
        definition_kind
    );

CREATE TABLE lab_profile.local_account (
    local_account_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    local_account_uid UUID NOT NULL UNIQUE CHECK (
        local_account_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    account_combat_state_uid UUID NOT NULL UNIQUE CHECK (
        account_combat_state_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    canonical_sha256 BYTEA NOT NULL CHECK (octet_length(canonical_sha256) = 32),
    current_account_state_revision_id BIGINT,
    current_squad_revision_id BIGINT,
    current_profile_template_revision_id BIGINT,
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (local_account_id, current_account_state_revision_id),
    UNIQUE (local_account_id, current_squad_revision_id),
    UNIQUE (local_account_id, current_profile_template_revision_id)
);

CREATE TABLE lab_profile.account_state_revision (
    account_state_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_state_revision_uid UUID NOT NULL UNIQUE CHECK (
        account_state_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_account_id BIGINT NOT NULL
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    revision_number INTEGER NOT NULL CHECK (revision_number >= 1),
    previous_account_state_revision_id BIGINT,
    character_catalog_snapshot_id BIGINT NOT NULL,
    character_dataset_snapshot_id BIGINT NOT NULL,
    character_catalog_manifest_sha256 BYTEA NOT NULL CHECK (
        octet_length(character_catalog_manifest_sha256) = 32
    ),
    support_catalog_snapshot_id BIGINT NOT NULL,
    support_dataset_snapshot_id BIGINT NOT NULL,
    support_catalog_manifest_sha256 BYTEA NOT NULL CHECK (
        octet_length(support_catalog_manifest_sha256) = 32
    ),
    synchro_level_status TEXT NOT NULL CHECK (
        synchro_level_status IN ('ready', 'unresolved')
    ),
    synchro_level INTEGER CHECK (synchro_level BETWEEN 1 AND 1000000),
    synchro_level_unresolved_reason_code TEXT CHECK (
        synchro_level_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    validation_mode TEXT NOT NULL CHECK (validation_mode IN ('research', 'game_legal')),
    combat_readiness_status TEXT NOT NULL CHECK (
        combat_readiness_status IN ('ready', 'unresolved')
    ),
    combat_readiness_issue_code TEXT CHECK (
        combat_readiness_issue_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    full_fidelity_status TEXT NOT NULL CHECK (
        full_fidelity_status IN ('ready', 'unresolved')
    ),
    full_fidelity_issue_code TEXT CHECK (
        full_fidelity_issue_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    game_legal_readiness_status TEXT NOT NULL CHECK (
        game_legal_readiness_status IN ('ready', 'unresolved')
    ),
    game_legal_issue_code TEXT CHECK (
        game_legal_issue_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    console_count SMALLINT NOT NULL CHECK (console_count = 9),
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    revision_origin TEXT NOT NULL CHECK (
        revision_origin IN ('user_edit', 'combat_max_v1', 'offline_sanitized_import', 'rebase')
    ),
    materialized_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (local_account_id, revision_number),
    UNIQUE (account_state_revision_id, local_account_id),
    UNIQUE (account_state_revision_id, support_catalog_snapshot_id),
    FOREIGN KEY (previous_account_state_revision_id, local_account_id)
        REFERENCES lab_profile.account_state_revision(
            account_state_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        character_catalog_snapshot_id,
        character_dataset_snapshot_id,
        character_catalog_manifest_sha256
    ) REFERENCES lab_catalog.character_catalog_snapshot(
        character_catalog_snapshot_id,
        dataset_snapshot_id,
        catalog_manifest_sha256
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        support_catalog_snapshot_id,
        support_dataset_snapshot_id,
        support_catalog_manifest_sha256
    ) REFERENCES lab_combat_support.catalog_snapshot(
        catalog_snapshot_id,
        dataset_snapshot_id,
        catalog_manifest_sha256
    ) ON DELETE RESTRICT,
    CHECK (lab_profile.valid_fact(
        synchro_level_status,
        synchro_level IS NOT NULL,
        synchro_level_unresolved_reason_code
    )),
    CHECK (
        (revision_number = 1 AND previous_account_state_revision_id IS NULL)
        OR (revision_number > 1 AND previous_account_state_revision_id IS NOT NULL)
    ),
    CHECK (
        (combat_readiness_status = 'ready' AND combat_readiness_issue_code IS NULL)
        OR (combat_readiness_status = 'unresolved'
            AND combat_readiness_issue_code IS NOT NULL)
    ),
    CHECK (
        (full_fidelity_status = 'ready' AND full_fidelity_issue_code IS NULL)
        OR (full_fidelity_status = 'unresolved' AND full_fidelity_issue_code IS NOT NULL)
    ),
    CHECK (
        (game_legal_readiness_status = 'ready' AND game_legal_issue_code IS NULL)
        OR (game_legal_readiness_status = 'unresolved' AND game_legal_issue_code IS NOT NULL)
    )
);

CREATE TABLE lab_profile.account_console_state (
    account_state_revision_id BIGINT NOT NULL,
    support_catalog_snapshot_id BIGINT NOT NULL,
    coordinate_code TEXT NOT NULL CHECK (
        coordinate_code IN (
            'common', 'attacker', 'defender', 'supporter',
            'elysion', 'missilis', 'tetra', 'pilgrim', 'abnormal'
        )
    ),
    definition_entity_id BIGINT NOT NULL,
    definition_version_id BIGINT NOT NULL,
    definition_kind TEXT NOT NULL CHECK (definition_kind = 'console'),
    level_status TEXT NOT NULL CHECK (level_status IN ('ready', 'unresolved')),
    level INTEGER CHECK (level BETWEEN 0 AND 1000000),
    level_unresolved_reason_code TEXT CHECK (
        level_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    observed_experience_status TEXT NOT NULL CHECK (
        observed_experience_status IN ('ready', 'unresolved')
    ),
    observed_experience BIGINT CHECK (observed_experience >= 0),
    observed_experience_unresolved_reason_code TEXT CHECK (
        observed_experience_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    PRIMARY KEY (account_state_revision_id, coordinate_code),
    UNIQUE (account_state_revision_id, definition_entity_id),
    FOREIGN KEY (account_state_revision_id, support_catalog_snapshot_id)
        REFERENCES lab_profile.account_state_revision(
            account_state_revision_id,
            support_catalog_snapshot_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        support_catalog_snapshot_id,
        definition_entity_id,
        definition_version_id,
        definition_kind
    ) REFERENCES lab_combat_support.catalog_snapshot_member(
        catalog_snapshot_id,
        definition_entity_id,
        definition_version_id,
        definition_kind
    ) ON DELETE RESTRICT,
    CHECK (lab_profile.valid_fact(
        level_status,
        level IS NOT NULL,
        level_unresolved_reason_code
    )),
    CHECK (lab_profile.valid_fact(
        observed_experience_status,
        observed_experience IS NOT NULL,
        observed_experience_unresolved_reason_code
    ))
);

CREATE TABLE lab_profile.character_build (
    character_build_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    character_build_uid UUID NOT NULL UNIQUE CHECK (
        character_build_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_account_id BIGINT NOT NULL
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    character_entity_id BIGINT NOT NULL
        REFERENCES lab_catalog.character_entity(character_entity_id) ON DELETE RESTRICT,
    current_build_revision_id BIGINT,
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (local_account_id, character_entity_id),
    UNIQUE (character_build_id, character_entity_id),
    UNIQUE (character_build_id, current_build_revision_id)
);

CREATE TABLE lab_profile.equipment_slot_entity (
    equipment_slot_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    equipment_slot_uid UUID NOT NULL UNIQUE CHECK (
        equipment_slot_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    character_build_id BIGINT NOT NULL
        REFERENCES lab_profile.character_build(character_build_id) ON DELETE RESTRICT,
    slot_code TEXT NOT NULL CHECK (slot_code IN ('head', 'torso', 'arms', 'legs')),
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (character_build_id, slot_code),
    UNIQUE (equipment_slot_id, character_build_id, slot_code)
);

CREATE TABLE lab_profile.character_build_revision (
    build_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    build_revision_uid UUID NOT NULL UNIQUE CHECK (
        build_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    character_build_id BIGINT NOT NULL,
    revision_number INTEGER NOT NULL CHECK (revision_number >= 1),
    previous_build_revision_id BIGINT,
    character_entity_id BIGINT NOT NULL,
    character_catalog_snapshot_id BIGINT NOT NULL,
    character_dataset_snapshot_id BIGINT NOT NULL,
    character_catalog_manifest_sha256 BYTEA NOT NULL CHECK (
        octet_length(character_catalog_manifest_sha256) = 32
    ),
    character_definition_version_id BIGINT NOT NULL,
    support_catalog_snapshot_id BIGINT NOT NULL,
    support_dataset_snapshot_id BIGINT NOT NULL,
    support_catalog_manifest_sha256 BYTEA NOT NULL CHECK (
        octet_length(support_catalog_manifest_sha256) = 32
    ),
    character_level INTEGER NOT NULL CHECK (character_level BETWEEN 1 AND 1000000),
    limit_break_status TEXT NOT NULL,
    limit_break_level INTEGER CHECK (limit_break_level BETWEEN 0 AND 1000000),
    limit_break_unresolved_reason_code TEXT CHECK (
        limit_break_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    core_level_status TEXT NOT NULL,
    core_level INTEGER CHECK (core_level BETWEEN 0 AND 1000000),
    core_level_unresolved_reason_code TEXT CHECK (
        core_level_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    bond_level_status TEXT NOT NULL,
    bond_level INTEGER CHECK (bond_level BETWEEN 0 AND 1000000),
    bond_level_unresolved_reason_code TEXT CHECK (
        bond_level_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    skill_1_status TEXT NOT NULL,
    skill_1_level INTEGER CHECK (skill_1_level BETWEEN 1 AND 1000000),
    skill_1_unresolved_reason_code TEXT CHECK (
        skill_1_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    skill_2_status TEXT NOT NULL,
    skill_2_level INTEGER CHECK (skill_2_level BETWEEN 1 AND 1000000),
    skill_2_unresolved_reason_code TEXT CHECK (
        skill_2_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    burst_status TEXT NOT NULL,
    burst_level INTEGER CHECK (burst_level BETWEEN 1 AND 1000000),
    burst_unresolved_reason_code TEXT CHECK (
        burst_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    materialization_policy TEXT NOT NULL CHECK (
        materialization_policy IN ('explicit_v1', 'combat_max_v1')
    ),
    cube_state TEXT NOT NULL CHECK (cube_state IN ('equipped', 'unequipped', 'unresolved')),
    cube_definition_entity_id BIGINT,
    cube_definition_version_id BIGINT,
    cube_definition_kind TEXT CHECK (cube_definition_kind = 'cube'),
    cube_level_status TEXT CHECK (cube_level_status IN ('ready', 'unresolved')),
    cube_level INTEGER CHECK (cube_level BETWEEN 1 AND 15),
    cube_level_unresolved_reason_code TEXT CHECK (
        cube_level_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    cube_unresolved_reason_code TEXT CHECK (
        cube_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    collection_kind TEXT NOT NULL CHECK (
        collection_kind IN (
            'detached', 'collection', 'favorite', 'unresolved', 'not_applicable'
        )
    ),
    collection_definition_entity_id BIGINT,
    collection_definition_version_id BIGINT,
    collection_definition_kind TEXT CHECK (
        collection_definition_kind IN ('collection', 'favorite')
    ),
    collection_level_status TEXT CHECK (
        collection_level_status IN ('ready', 'unresolved')
    ),
    collection_level INTEGER CHECK (collection_level BETWEEN 0 AND 1000000),
    collection_level_unresolved_reason_code TEXT CHECK (
        collection_level_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    collection_unresolved_reason_code TEXT CHECK (
        collection_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    validation_mode TEXT NOT NULL CHECK (validation_mode IN ('research', 'game_legal')),
    selection_readiness_status TEXT NOT NULL CHECK (
        selection_readiness_status IN ('ready', 'unresolved')
    ),
    selection_readiness_issue_code TEXT CHECK (
        selection_readiness_issue_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    combat_semantics_readiness_status TEXT NOT NULL CHECK (
        combat_semantics_readiness_status IN ('ready', 'unresolved')
    ),
    combat_semantics_readiness_issue_code TEXT CHECK (
        combat_semantics_readiness_issue_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    game_legal_readiness_status TEXT NOT NULL CHECK (
        game_legal_readiness_status IN ('ready', 'unresolved')
    ),
    game_legal_issue_code TEXT CHECK (
        game_legal_issue_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    equipment_count SMALLINT NOT NULL CHECK (equipment_count = 4),
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    revision_origin TEXT NOT NULL CHECK (
        revision_origin IN ('user_edit', 'combat_max_v1', 'offline_sanitized_import', 'rebase')
    ),
    materialized_at_utc TIMESTAMPTZ NOT NULL,
    CHECK (
        (materialization_policy = 'combat_max_v1') =
        (revision_origin = 'combat_max_v1')
    ),
    UNIQUE (character_build_id, revision_number),
    UNIQUE (build_revision_id, character_build_id),
    UNIQUE (build_revision_id, support_catalog_snapshot_id),
    FOREIGN KEY (previous_build_revision_id, character_build_id)
        REFERENCES lab_profile.character_build_revision(
            build_revision_id,
            character_build_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (character_build_id, character_entity_id)
        REFERENCES lab_profile.character_build(
            character_build_id,
            character_entity_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        character_catalog_snapshot_id,
        character_dataset_snapshot_id,
        character_catalog_manifest_sha256
    ) REFERENCES lab_catalog.character_catalog_snapshot(
        character_catalog_snapshot_id,
        dataset_snapshot_id,
        catalog_manifest_sha256
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        character_catalog_snapshot_id,
        character_entity_id,
        character_definition_version_id
    ) REFERENCES lab_catalog.character_catalog_snapshot_member(
        character_catalog_snapshot_id,
        character_entity_id,
        character_definition_version_id
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        support_catalog_snapshot_id,
        support_dataset_snapshot_id,
        support_catalog_manifest_sha256
    ) REFERENCES lab_combat_support.catalog_snapshot(
        catalog_snapshot_id,
        dataset_snapshot_id,
        catalog_manifest_sha256
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        support_catalog_snapshot_id,
        cube_definition_entity_id,
        cube_definition_version_id,
        cube_definition_kind
    ) REFERENCES lab_combat_support.catalog_snapshot_member(
        catalog_snapshot_id,
        definition_entity_id,
        definition_version_id,
        definition_kind
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        support_catalog_snapshot_id,
        collection_definition_entity_id,
        collection_definition_version_id,
        collection_definition_kind
    ) REFERENCES lab_combat_support.catalog_snapshot_member(
        catalog_snapshot_id,
        definition_entity_id,
        definition_version_id,
        definition_kind
    ) ON DELETE RESTRICT,
    CHECK (lab_profile.valid_fact(
        limit_break_status,
        limit_break_level IS NOT NULL,
        limit_break_unresolved_reason_code
    )),
    CHECK (
        (revision_number = 1 AND previous_build_revision_id IS NULL)
        OR (revision_number > 1 AND previous_build_revision_id IS NOT NULL)
    ),
    CHECK (lab_profile.valid_fact(
        core_level_status,
        core_level IS NOT NULL,
        core_level_unresolved_reason_code
    )),
    CHECK (lab_profile.valid_fact(
        bond_level_status,
        bond_level IS NOT NULL,
        bond_level_unresolved_reason_code
    )),
    CHECK (lab_profile.valid_fact(
        skill_1_status,
        skill_1_level IS NOT NULL,
        skill_1_unresolved_reason_code
    )),
    CHECK (lab_profile.valid_fact(
        skill_2_status,
        skill_2_level IS NOT NULL,
        skill_2_unresolved_reason_code
    )),
    CHECK (lab_profile.valid_fact(
        burst_status,
        burst_level IS NOT NULL,
        burst_unresolved_reason_code
    )),
    CHECK (
        (cube_state = 'equipped'
            AND cube_definition_entity_id IS NOT NULL
            AND cube_definition_version_id IS NOT NULL
            AND cube_definition_kind IS NOT NULL
            AND cube_definition_kind = 'cube'
            AND cube_level_status IS NOT NULL
            AND lab_profile.valid_fact(
                cube_level_status,
                cube_level IS NOT NULL,
                cube_level_unresolved_reason_code
            )
            AND cube_unresolved_reason_code IS NULL)
        OR (cube_state = 'unequipped'
            AND cube_definition_entity_id IS NULL
            AND cube_definition_version_id IS NULL
            AND cube_definition_kind IS NULL
            AND cube_level_status IS NULL
            AND cube_level IS NULL
            AND cube_level_unresolved_reason_code IS NULL
            AND cube_unresolved_reason_code IS NULL)
        OR (cube_state = 'unresolved'
            AND cube_definition_entity_id IS NULL
            AND cube_definition_version_id IS NULL
            AND cube_definition_kind IS NULL
            AND cube_level_status IS NULL
            AND cube_level IS NULL
            AND cube_level_unresolved_reason_code IS NULL
            AND cube_unresolved_reason_code IS NOT NULL)
    ),
    CHECK (
        (collection_kind IN ('collection', 'favorite')
            AND collection_definition_entity_id IS NOT NULL
            AND collection_definition_version_id IS NOT NULL
            AND collection_definition_kind IS NOT NULL
            AND collection_definition_kind = collection_kind
            AND collection_level_status IS NOT NULL
            AND lab_profile.valid_fact(
                collection_level_status,
                collection_level IS NOT NULL,
                collection_level_unresolved_reason_code
            )
            AND collection_unresolved_reason_code IS NULL)
        OR (collection_kind = 'detached'
            AND collection_definition_entity_id IS NULL
            AND collection_definition_version_id IS NULL
            AND collection_definition_kind IS NULL
            AND collection_level_status IS NULL
            AND collection_level IS NULL
            AND collection_level_unresolved_reason_code IS NULL
            AND collection_unresolved_reason_code IS NULL)
        OR (collection_kind = 'not_applicable'
            AND collection_definition_entity_id IS NULL
            AND collection_definition_version_id IS NULL
            AND collection_definition_kind IS NULL
            AND collection_level_status IS NULL
            AND collection_level IS NULL
            AND collection_level_unresolved_reason_code IS NULL
            AND collection_unresolved_reason_code IS NULL)
        OR (collection_kind = 'unresolved'
            AND collection_definition_entity_id IS NULL
            AND collection_definition_version_id IS NULL
            AND collection_definition_kind IS NULL
            AND collection_level_status IS NULL
            AND collection_level IS NULL
            AND collection_level_unresolved_reason_code IS NULL
            AND collection_unresolved_reason_code IS NOT NULL)
    ),
    CHECK (
        (selection_readiness_status = 'ready' AND selection_readiness_issue_code IS NULL)
        OR (selection_readiness_status = 'unresolved'
            AND selection_readiness_issue_code IS NOT NULL)
    ),
    CHECK (
        (combat_semantics_readiness_status = 'ready'
            AND combat_semantics_readiness_issue_code IS NULL)
        OR (combat_semantics_readiness_status = 'unresolved'
            AND combat_semantics_readiness_issue_code IS NOT NULL)
    ),
    CHECK (
        (game_legal_readiness_status = 'ready' AND game_legal_issue_code IS NULL)
        OR (game_legal_readiness_status = 'unresolved' AND game_legal_issue_code IS NOT NULL)
    )
);

ALTER TABLE lab_profile.character_build
    ADD CONSTRAINT fk_character_build_current_revision
    FOREIGN KEY (current_build_revision_id, character_build_id)
    REFERENCES lab_profile.character_build_revision(
        build_revision_id,
        character_build_id
    ) DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE lab_profile.build_equipment_state (
    build_equipment_state_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    build_revision_id BIGINT NOT NULL,
    character_build_id BIGINT NOT NULL,
    equipment_slot_id BIGINT NOT NULL,
    slot_code TEXT NOT NULL CHECK (slot_code IN ('head', 'torso', 'arms', 'legs')),
    support_catalog_snapshot_id BIGINT NOT NULL,
    equipment_state TEXT NOT NULL CHECK (
        equipment_state IN ('equipped', 'unequipped', 'unresolved')
    ),
    definition_entity_id BIGINT,
    definition_version_id BIGINT,
    definition_kind TEXT CHECK (definition_kind = 'equipment'),
    enhancement_level_status TEXT CHECK (
        enhancement_level_status IN ('ready', 'unresolved')
    ),
    enhancement_level SMALLINT CHECK (enhancement_level BETWEEN 0 AND 5),
    enhancement_level_unresolved_reason_code TEXT CHECK (
        enhancement_level_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    manufacturer_matched_status TEXT CHECK (
        manufacturer_matched_status IN ('ready', 'unresolved', 'not_applicable')
    ),
    manufacturer_matched BOOLEAN,
    manufacturer_matched_unresolved_reason_code TEXT CHECK (
        manufacturer_matched_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    equipment_unresolved_reason_code TEXT CHECK (
        equipment_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    overload_line_count SMALLINT NOT NULL CHECK (overload_line_count BETWEEN 0 AND 3),
    UNIQUE (build_revision_id, equipment_slot_id),
    UNIQUE (build_revision_id, slot_code),
    UNIQUE (build_equipment_state_id, support_catalog_snapshot_id),
    FOREIGN KEY (build_revision_id, character_build_id)
        REFERENCES lab_profile.character_build_revision(
            build_revision_id,
            character_build_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (build_revision_id, support_catalog_snapshot_id)
        REFERENCES lab_profile.character_build_revision(
            build_revision_id,
            support_catalog_snapshot_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (equipment_slot_id, character_build_id, slot_code)
        REFERENCES lab_profile.equipment_slot_entity(
            equipment_slot_id,
            character_build_id,
            slot_code
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        support_catalog_snapshot_id,
        definition_entity_id,
        definition_version_id,
        definition_kind
    ) REFERENCES lab_combat_support.catalog_snapshot_member(
        catalog_snapshot_id,
        definition_entity_id,
        definition_version_id,
        definition_kind
    ) ON DELETE RESTRICT,
    CHECK (
        (equipment_state = 'equipped'
            AND definition_entity_id IS NOT NULL
            AND definition_version_id IS NOT NULL
            AND definition_kind IS NOT NULL
            AND definition_kind = 'equipment'
            AND enhancement_level_status IS NOT NULL
            AND lab_profile.valid_fact(
                enhancement_level_status,
                enhancement_level IS NOT NULL,
                enhancement_level_unresolved_reason_code
            )
            AND manufacturer_matched_status IS NOT NULL
            AND manufacturer_matched_status IN ('ready', 'unresolved')
            AND equipment_unresolved_reason_code IS NULL)
        OR (equipment_state = 'unequipped'
            AND definition_entity_id IS NULL
            AND definition_version_id IS NULL
            AND definition_kind IS NULL
            AND enhancement_level_status IS NULL
            AND enhancement_level IS NULL
            AND enhancement_level_unresolved_reason_code IS NULL
            AND manufacturer_matched_status IS NOT NULL
            AND manufacturer_matched_status = 'not_applicable'
            AND equipment_unresolved_reason_code IS NULL
            AND overload_line_count = 0)
        OR (equipment_state = 'unresolved'
            AND definition_entity_id IS NULL
            AND definition_version_id IS NULL
            AND definition_kind IS NULL
            AND enhancement_level_status IS NULL
            AND enhancement_level IS NULL
            AND enhancement_level_unresolved_reason_code IS NULL
            AND manufacturer_matched_status IS NULL
            AND manufacturer_matched IS NULL
            AND manufacturer_matched_unresolved_reason_code IS NULL
            AND equipment_unresolved_reason_code IS NOT NULL
            AND overload_line_count = 0)
    ),
    CHECK (
        manufacturer_matched_status IS NULL
        OR lab_profile.valid_fact(
            manufacturer_matched_status,
            manufacturer_matched IS NOT NULL,
            manufacturer_matched_unresolved_reason_code
        )
    )
);

CREATE TABLE lab_profile.build_overload_line (
    build_equipment_state_id BIGINT NOT NULL,
    support_catalog_snapshot_id BIGINT NOT NULL,
    line_index SMALLINT NOT NULL CHECK (line_index BETWEEN 1 AND 3),
    definition_entity_id BIGINT NOT NULL,
    definition_version_id BIGINT NOT NULL,
    definition_kind TEXT NOT NULL CHECK (definition_kind = 'overload_option'),
    unit_code TEXT NOT NULL CHECK (unit_code IN ('absolute', 'ratio', 'percent', 'count')),
    exact_unscaled_value BIGINT NOT NULL,
    exact_decimal_scale SMALLINT NOT NULL CHECK (exact_decimal_scale BETWEEN 0 AND 9),
    PRIMARY KEY (build_equipment_state_id, line_index),
    FOREIGN KEY (build_equipment_state_id, support_catalog_snapshot_id)
        REFERENCES lab_profile.build_equipment_state(
            build_equipment_state_id,
            support_catalog_snapshot_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        support_catalog_snapshot_id,
        definition_entity_id,
        definition_version_id,
        definition_kind
    ) REFERENCES lab_combat_support.catalog_snapshot_member(
        catalog_snapshot_id,
        definition_entity_id,
        definition_version_id,
        definition_kind
    ) ON DELETE RESTRICT
);

CREATE TABLE lab_profile.local_squad (
    local_squad_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    local_squad_uid UUID NOT NULL UNIQUE CHECK (
        local_squad_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_account_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    current_squad_revision_id BIGINT,
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (local_squad_id, local_account_id),
    UNIQUE (local_squad_id, current_squad_revision_id)
);

CREATE TABLE lab_profile.squad_revision (
    squad_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    squad_revision_uid UUID NOT NULL UNIQUE CHECK (
        squad_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_squad_id BIGINT NOT NULL,
    local_account_id BIGINT NOT NULL,
    revision_number INTEGER NOT NULL CHECK (revision_number >= 1),
    previous_squad_revision_id BIGINT,
    character_catalog_snapshot_id BIGINT NOT NULL,
    character_dataset_snapshot_id BIGINT NOT NULL,
    character_catalog_manifest_sha256 BYTEA NOT NULL CHECK (
        octet_length(character_catalog_manifest_sha256) = 32
    ),
    support_catalog_snapshot_id BIGINT NOT NULL,
    support_dataset_snapshot_id BIGINT NOT NULL,
    support_catalog_manifest_sha256 BYTEA NOT NULL CHECK (
        octet_length(support_catalog_manifest_sha256) = 32
    ),
    selection_readiness_status TEXT NOT NULL CHECK (
        selection_readiness_status IN ('ready', 'unresolved')
    ),
    selection_readiness_issue_code TEXT CHECK (
        selection_readiness_issue_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    combat_semantics_readiness_status TEXT NOT NULL CHECK (
        combat_semantics_readiness_status IN ('ready', 'unresolved')
    ),
    combat_semantics_readiness_issue_code TEXT CHECK (
        combat_semantics_readiness_issue_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    member_count SMALLINT NOT NULL CHECK (member_count = 5),
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    revision_origin TEXT NOT NULL CHECK (
        revision_origin IN ('user_edit', 'combat_max_v1', 'offline_sanitized_import', 'rebase')
    ),
    materialized_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (local_squad_id, revision_number),
    UNIQUE (squad_revision_id, local_squad_id),
    UNIQUE (squad_revision_id, local_account_id),
    FOREIGN KEY (previous_squad_revision_id, local_squad_id)
        REFERENCES lab_profile.squad_revision(
            squad_revision_id,
            local_squad_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (local_squad_id, local_account_id)
        REFERENCES lab_profile.local_squad(
            local_squad_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        character_catalog_snapshot_id,
        character_dataset_snapshot_id,
        character_catalog_manifest_sha256
    ) REFERENCES lab_catalog.character_catalog_snapshot(
        character_catalog_snapshot_id,
        dataset_snapshot_id,
        catalog_manifest_sha256
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        support_catalog_snapshot_id,
        support_dataset_snapshot_id,
        support_catalog_manifest_sha256
    ) REFERENCES lab_combat_support.catalog_snapshot(
        catalog_snapshot_id,
        dataset_snapshot_id,
        catalog_manifest_sha256
    ) ON DELETE RESTRICT,
    CHECK (
        (revision_number = 1 AND previous_squad_revision_id IS NULL)
        OR (revision_number > 1 AND previous_squad_revision_id IS NOT NULL)
    ),
    CHECK (
        (selection_readiness_status = 'ready' AND selection_readiness_issue_code IS NULL)
        OR (selection_readiness_status = 'unresolved'
            AND selection_readiness_issue_code IS NOT NULL)
    ),
    CHECK (
        (combat_semantics_readiness_status = 'ready'
            AND combat_semantics_readiness_issue_code IS NULL)
        OR (combat_semantics_readiness_status = 'unresolved'
            AND combat_semantics_readiness_issue_code IS NOT NULL)
    )
);

ALTER TABLE lab_profile.local_squad
    ADD CONSTRAINT fk_local_squad_current_revision
    FOREIGN KEY (current_squad_revision_id, local_squad_id)
    REFERENCES lab_profile.squad_revision(squad_revision_id, local_squad_id)
    DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE lab_profile.squad_revision_member (
    squad_revision_id BIGINT NOT NULL,
    position SMALLINT NOT NULL CHECK (position BETWEEN 1 AND 5),
    character_build_id BIGINT NOT NULL,
    build_revision_id BIGINT NOT NULL,
    PRIMARY KEY (squad_revision_id, position),
    UNIQUE (squad_revision_id, character_build_id),
    FOREIGN KEY (squad_revision_id)
        REFERENCES lab_profile.squad_revision(squad_revision_id) ON DELETE RESTRICT,
    FOREIGN KEY (build_revision_id, character_build_id)
        REFERENCES lab_profile.character_build_revision(
            build_revision_id,
            character_build_id
        ) ON DELETE RESTRICT
);

CREATE TABLE lab_profile.profile_template (
    profile_template_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    profile_template_uid UUID NOT NULL UNIQUE CHECK (
        profile_template_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_account_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    current_profile_template_revision_id BIGINT,
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (profile_template_id, local_account_id),
    UNIQUE (profile_template_id, current_profile_template_revision_id)
);

CREATE TABLE lab_profile.profile_template_revision (
    profile_template_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    profile_template_revision_uid UUID NOT NULL UNIQUE CHECK (
        profile_template_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    profile_template_id BIGINT NOT NULL,
    local_account_id BIGINT NOT NULL,
    revision_number INTEGER NOT NULL CHECK (revision_number >= 1),
    previous_profile_template_revision_id BIGINT,
    character_catalog_snapshot_id BIGINT NOT NULL,
    character_dataset_snapshot_id BIGINT NOT NULL,
    character_catalog_manifest_sha256 BYTEA NOT NULL CHECK (
        octet_length(character_catalog_manifest_sha256) = 32
    ),
    support_catalog_snapshot_id BIGINT NOT NULL,
    support_dataset_snapshot_id BIGINT NOT NULL,
    support_catalog_manifest_sha256 BYTEA NOT NULL CHECK (
        octet_length(support_catalog_manifest_sha256) = 32
    ),
    account_state_revision_id BIGINT NOT NULL,
    squad_revision_id BIGINT,
    build_count INTEGER NOT NULL CHECK (build_count >= 0),
    is_combat_ready BOOLEAN NOT NULL,
    has_complete_combat_semantics BOOLEAN NOT NULL,
    game_legal_readiness_status TEXT NOT NULL CHECK (
        game_legal_readiness_status IN ('ready', 'unresolved')
    ),
    game_legal_issue_code TEXT CHECK (
        game_legal_issue_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    revision_origin TEXT NOT NULL CHECK (
        revision_origin IN ('user_edit', 'combat_max_v1', 'offline_sanitized_import', 'rebase')
    ),
    materialized_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (profile_template_id, revision_number),
    UNIQUE (profile_template_revision_id, profile_template_id),
    UNIQUE (profile_template_revision_id, local_account_id),
    UNIQUE (profile_template_revision_uid, local_account_id),
    FOREIGN KEY (previous_profile_template_revision_id, profile_template_id)
        REFERENCES lab_profile.profile_template_revision(
            profile_template_revision_id,
            profile_template_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (profile_template_id, local_account_id)
        REFERENCES lab_profile.profile_template(
            profile_template_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (account_state_revision_id, local_account_id)
        REFERENCES lab_profile.account_state_revision(
            account_state_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (squad_revision_id, local_account_id)
        REFERENCES lab_profile.squad_revision(
            squad_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        character_catalog_snapshot_id,
        character_dataset_snapshot_id,
        character_catalog_manifest_sha256
    ) REFERENCES lab_catalog.character_catalog_snapshot(
        character_catalog_snapshot_id,
        dataset_snapshot_id,
        catalog_manifest_sha256
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        support_catalog_snapshot_id,
        support_dataset_snapshot_id,
        support_catalog_manifest_sha256
    ) REFERENCES lab_combat_support.catalog_snapshot(
        catalog_snapshot_id,
        dataset_snapshot_id,
        catalog_manifest_sha256
    ) ON DELETE RESTRICT,
    CHECK (
        (revision_number = 1 AND previous_profile_template_revision_id IS NULL)
        OR (revision_number > 1 AND previous_profile_template_revision_id IS NOT NULL)
    ),
    CHECK (
        (game_legal_readiness_status = 'ready' AND game_legal_issue_code IS NULL)
        OR (game_legal_readiness_status = 'unresolved' AND game_legal_issue_code IS NOT NULL)
    )
);

ALTER TABLE lab_profile.profile_template
    ADD CONSTRAINT fk_profile_template_current_revision
    FOREIGN KEY (current_profile_template_revision_id, profile_template_id)
    REFERENCES lab_profile.profile_template_revision(
        profile_template_revision_id,
        profile_template_id
    ) DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE lab_profile.profile_template_revision_build (
    profile_template_revision_id BIGINT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    character_build_id BIGINT NOT NULL,
    build_revision_id BIGINT NOT NULL,
    PRIMARY KEY (profile_template_revision_id, ordinal),
    UNIQUE (profile_template_revision_id, character_build_id),
    FOREIGN KEY (profile_template_revision_id)
        REFERENCES lab_profile.profile_template_revision(profile_template_revision_id)
        ON DELETE RESTRICT,
    FOREIGN KEY (build_revision_id, character_build_id)
        REFERENCES lab_profile.character_build_revision(
            build_revision_id,
            character_build_id
        ) ON DELETE RESTRICT
);

ALTER TABLE lab_profile.local_account
    ADD CONSTRAINT fk_local_account_current_state
    FOREIGN KEY (current_account_state_revision_id, local_account_id)
    REFERENCES lab_profile.account_state_revision(
        account_state_revision_id,
        local_account_id
    ) DEFERRABLE INITIALLY DEFERRED,
    ADD CONSTRAINT fk_local_account_current_squad
    FOREIGN KEY (current_squad_revision_id, local_account_id)
    REFERENCES lab_profile.squad_revision(
        squad_revision_id,
        local_account_id
    ) DEFERRABLE INITIALLY DEFERRED,
    ADD CONSTRAINT fk_local_account_current_template
    FOREIGN KEY (current_profile_template_revision_id, local_account_id)
    REFERENCES lab_profile.profile_template_revision(
        profile_template_revision_id,
        local_account_id
    ) DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE lab_profile.profile_write_operation (
    profile_write_operation_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_uid UUID NOT NULL UNIQUE CHECK (
        operation_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    operation_kind TEXT NOT NULL CHECK (operation_kind IN ('create', 'save')),
    request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256) = 32),
    local_account_id BIGINT NOT NULL
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    expected_profile_template_revision_uid UUID,
    result_profile_template_revision_id BIGINT NOT NULL,
    completed_at_utc TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (result_profile_template_revision_id, local_account_id)
        REFERENCES lab_profile.profile_template_revision(
            profile_template_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (expected_profile_template_revision_uid, local_account_id)
        REFERENCES lab_profile.profile_template_revision(
            profile_template_revision_uid,
            local_account_id
        ) ON DELETE RESTRICT,
    CHECK (
        (operation_kind = 'create' AND expected_profile_template_revision_uid IS NULL)
        OR (operation_kind = 'save' AND expected_profile_template_revision_uid IS NOT NULL)
    )
);

CREATE TABLE lab_profile.local_session (
    local_session_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    local_session_uid UUID NOT NULL UNIQUE CHECK (
        local_session_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_account_id BIGINT NOT NULL
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    issued_at_utc TIMESTAMPTZ NOT NULL,
    expires_at_utc TIMESTAMPTZ NOT NULL,
    revoked_at_utc TIMESTAMPTZ,
    CHECK (expires_at_utc > issued_at_utc),
    CHECK (
        revoked_at_utc IS NULL
        OR (revoked_at_utc >= issued_at_utc AND revoked_at_utc < expires_at_utc)
    )
);

CREATE VIEW lab_profile.local_session_status AS
SELECT
    local_session_uid,
    local_account_id,
    issued_at_utc,
    expires_at_utc,
    revoked_at_utc,
    CASE
        WHEN revoked_at_utc IS NOT NULL THEN 'revoked'
        WHEN expires_at_utc <= CURRENT_TIMESTAMP THEN 'expired'
        ELSE 'active'
    END AS status
FROM lab_profile.local_session;

CREATE FUNCTION lab_profile.reject_immutable_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'immutable_profile_row';
END;
$$;

CREATE FUNCTION lab_profile.guard_account_state_lineage()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    current_revision_id BIGINT;
    current_revision_number INTEGER;
BEGIN
    SELECT current_account_state_revision_id INTO current_revision_id
    FROM lab_profile.local_account
    WHERE local_account_id = NEW.local_account_id
    FOR UPDATE;
    IF current_revision_id IS NULL THEN
        IF NEW.revision_number <> 1 OR NEW.previous_account_state_revision_id IS NOT NULL THEN
            RAISE EXCEPTION 'profile_revision_lineage_invalid';
        END IF;
    ELSE
        SELECT revision_number INTO current_revision_number
        FROM lab_profile.account_state_revision
        WHERE account_state_revision_id = current_revision_id
          AND local_account_id = NEW.local_account_id;
        IF current_revision_number IS NULL
           OR NEW.previous_account_state_revision_id IS DISTINCT FROM current_revision_id
           OR NEW.revision_number <> current_revision_number + 1 THEN
            RAISE EXCEPTION 'profile_revision_lineage_invalid';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.guard_build_revision_lineage()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    current_revision_id BIGINT;
    current_revision_number INTEGER;
BEGIN
    SELECT current_build_revision_id INTO current_revision_id
    FROM lab_profile.character_build
    WHERE character_build_id = NEW.character_build_id
    FOR UPDATE;
    IF current_revision_id IS NULL THEN
        IF NEW.revision_number <> 1 OR NEW.previous_build_revision_id IS NOT NULL THEN
            RAISE EXCEPTION 'profile_revision_lineage_invalid';
        END IF;
    ELSE
        SELECT revision_number INTO current_revision_number
        FROM lab_profile.character_build_revision
        WHERE build_revision_id = current_revision_id
          AND character_build_id = NEW.character_build_id;
        IF current_revision_number IS NULL
           OR NEW.previous_build_revision_id IS DISTINCT FROM current_revision_id
           OR NEW.revision_number <> current_revision_number + 1 THEN
            RAISE EXCEPTION 'profile_revision_lineage_invalid';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.guard_squad_revision_lineage()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    current_revision_id BIGINT;
    current_revision_number INTEGER;
BEGIN
    SELECT current_squad_revision_id INTO current_revision_id
    FROM lab_profile.local_squad
    WHERE local_squad_id = NEW.local_squad_id
    FOR UPDATE;
    IF current_revision_id IS NULL THEN
        IF NEW.revision_number <> 1 OR NEW.previous_squad_revision_id IS NOT NULL THEN
            RAISE EXCEPTION 'profile_revision_lineage_invalid';
        END IF;
    ELSE
        SELECT revision_number INTO current_revision_number
        FROM lab_profile.squad_revision
        WHERE squad_revision_id = current_revision_id
          AND local_squad_id = NEW.local_squad_id;
        IF current_revision_number IS NULL
           OR NEW.previous_squad_revision_id IS DISTINCT FROM current_revision_id
           OR NEW.revision_number <> current_revision_number + 1 THEN
            RAISE EXCEPTION 'profile_revision_lineage_invalid';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.guard_template_revision_lineage()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    current_revision_id BIGINT;
    current_revision_number INTEGER;
BEGIN
    SELECT current_profile_template_revision_id INTO current_revision_id
    FROM lab_profile.profile_template
    WHERE profile_template_id = NEW.profile_template_id
    FOR UPDATE;
    IF current_revision_id IS NULL THEN
        IF NEW.revision_number <> 1
           OR NEW.previous_profile_template_revision_id IS NOT NULL THEN
            RAISE EXCEPTION 'profile_revision_lineage_invalid';
        END IF;
    ELSE
        SELECT revision_number INTO current_revision_number
        FROM lab_profile.profile_template_revision
        WHERE profile_template_revision_id = current_revision_id
          AND profile_template_id = NEW.profile_template_id;
        IF current_revision_number IS NULL
           OR NEW.previous_profile_template_revision_id IS DISTINCT FROM current_revision_id
           OR NEW.revision_number <> current_revision_number + 1 THEN
            RAISE EXCEPTION 'profile_revision_lineage_invalid';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.require_account_state_revision_current()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM lab_profile.local_account AS account
        WHERE account.local_account_id = NEW.local_account_id
          AND account.current_account_state_revision_id =
              NEW.account_state_revision_id
    ) THEN
        RAISE EXCEPTION 'profile_revision_not_published';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_profile.require_build_revision_current()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM lab_profile.character_build AS build
        WHERE build.character_build_id = NEW.character_build_id
          AND build.current_build_revision_id = NEW.build_revision_id
    ) THEN
        RAISE EXCEPTION 'profile_revision_not_published';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_profile.require_squad_revision_current()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM lab_profile.local_squad AS squad
        JOIN lab_profile.local_account AS account
          ON account.local_account_id = squad.local_account_id
        WHERE squad.local_squad_id = NEW.local_squad_id
          AND squad.current_squad_revision_id = NEW.squad_revision_id
          AND account.current_squad_revision_id = NEW.squad_revision_id
    ) THEN
        RAISE EXCEPTION 'profile_revision_not_published';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_profile.require_template_revision_current()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM lab_profile.profile_template AS template
        JOIN lab_profile.local_account AS account
          ON account.local_account_id = template.local_account_id
        WHERE template.profile_template_id = NEW.profile_template_id
          AND template.current_profile_template_revision_id =
              NEW.profile_template_revision_id
          AND account.current_profile_template_revision_id =
              NEW.profile_template_revision_id
    ) THEN
        RAISE EXCEPTION 'profile_revision_not_published';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_profile.require_profile_operation_topology()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.operation_kind = 'create' AND NOT EXISTS (
        SELECT 1
        FROM lab_profile.profile_template_revision AS result
        WHERE result.profile_template_revision_id =
              NEW.result_profile_template_revision_id
          AND result.local_account_id = NEW.local_account_id
          AND result.revision_number = 1
          AND result.previous_profile_template_revision_id IS NULL
    ) THEN
        RAISE EXCEPTION 'profile_operation_lineage_invalid';
    ELSIF NEW.operation_kind = 'save' AND NOT EXISTS (
        SELECT 1
        FROM lab_profile.profile_template_revision AS result
        LEFT JOIN lab_profile.profile_template_revision AS previous
          ON previous.profile_template_revision_id =
             result.previous_profile_template_revision_id
        WHERE result.profile_template_revision_id =
              NEW.result_profile_template_revision_id
          AND result.local_account_id = NEW.local_account_id
          AND (
              result.profile_template_revision_uid =
                  NEW.expected_profile_template_revision_uid
              OR previous.profile_template_revision_uid =
                  NEW.expected_profile_template_revision_uid
          )
    ) THEN
        RAISE EXCEPTION 'profile_operation_lineage_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_profile.guard_account_console_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_count INTEGER;
BEGIN
    SELECT console_count INTO expected_count
    FROM lab_profile.account_state_revision
    WHERE account_state_revision_id = NEW.account_state_revision_id
    FOR UPDATE;

    IF expected_count IS NULL OR expected_count <= (
        SELECT count(*) FROM lab_profile.account_console_state
        WHERE account_state_revision_id = NEW.account_state_revision_id
    ) THEN
        RAISE EXCEPTION 'immutable_profile_row';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.require_complete_account_state()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.console_count <> (
        SELECT count(*) FROM lab_profile.account_console_state
        WHERE account_state_revision_id = NEW.account_state_revision_id
    ) THEN
        RAISE EXCEPTION 'profile_account_state_incomplete';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM lab_profile.account_console_state AS state
        JOIN lab_combat_support.console_definition_detail AS definition
          ON definition.definition_version_id = state.definition_version_id
        WHERE state.account_state_revision_id = NEW.account_state_revision_id
          AND definition.coordinate_code <> state.coordinate_code
    ) THEN
        RAISE EXCEPTION 'profile_console_coordinate_mismatch';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_profile.guard_build_equipment_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_count INTEGER;
    equipment_tier INTEGER;
    overload_allowed BOOLEAN;
BEGIN
    SELECT equipment_count INTO expected_count
    FROM lab_profile.character_build_revision
    WHERE build_revision_id = NEW.build_revision_id
    FOR UPDATE;

    IF expected_count IS NULL OR expected_count <= (
        SELECT count(*) FROM lab_profile.build_equipment_state
        WHERE build_revision_id = NEW.build_revision_id
    ) THEN
        RAISE EXCEPTION 'immutable_profile_row';
    END IF;

    IF NEW.overload_line_count > 0 THEN
        SELECT tier_value, overload_eligible
        INTO equipment_tier, overload_allowed
        FROM lab_combat_support.equipment_definition_detail
        WHERE definition_version_id = NEW.definition_version_id
          AND tier_status = 'ready'
          AND overload_eligible_status = 'ready';

        IF equipment_tier IS DISTINCT FROM 10 OR overload_allowed IS DISTINCT FROM TRUE THEN
            RAISE EXCEPTION 'profile_overload_equipment_invalid';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.require_complete_build()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.equipment_count <> (
        SELECT count(*) FROM lab_profile.build_equipment_state
        WHERE build_revision_id = NEW.build_revision_id
    ) THEN
        RAISE EXCEPTION 'profile_build_incomplete';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_profile.guard_overload_line_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_count INTEGER;
BEGIN
    SELECT overload_line_count INTO expected_count
    FROM lab_profile.build_equipment_state
    WHERE build_equipment_state_id = NEW.build_equipment_state_id
    FOR UPDATE;

    IF expected_count IS NULL OR expected_count <= (
        SELECT count(*) FROM lab_profile.build_overload_line
        WHERE build_equipment_state_id = NEW.build_equipment_state_id
    ) THEN
        RAISE EXCEPTION 'immutable_profile_row';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.require_complete_overload_lines()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.overload_line_count <> (
        SELECT count(*) FROM lab_profile.build_overload_line
        WHERE build_equipment_state_id = NEW.build_equipment_state_id
    ) THEN
        RAISE EXCEPTION 'profile_overload_lines_incomplete';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_profile.guard_squad_member_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_count INTEGER;
BEGIN
    SELECT member_count INTO expected_count
    FROM lab_profile.squad_revision
    WHERE squad_revision_id = NEW.squad_revision_id
    FOR UPDATE;

    IF expected_count IS NULL OR expected_count <= (
        SELECT count(*) FROM lab_profile.squad_revision_member
        WHERE squad_revision_id = NEW.squad_revision_id
    ) THEN
        RAISE EXCEPTION 'immutable_profile_row';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.require_complete_squad()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.member_count <> (
        SELECT count(*) FROM lab_profile.squad_revision_member
        WHERE squad_revision_id = NEW.squad_revision_id
    ) THEN
        RAISE EXCEPTION 'profile_squad_incomplete';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM lab_profile.squad_revision_member AS member
        JOIN lab_profile.character_build AS build
          ON build.character_build_id = member.character_build_id
        WHERE member.squad_revision_id = NEW.squad_revision_id
          AND build.local_account_id <> NEW.local_account_id
    ) OR NEW.member_count <> (
        SELECT count(DISTINCT build.character_entity_id)
        FROM lab_profile.squad_revision_member AS member
        JOIN lab_profile.character_build AS build
          ON build.character_build_id = member.character_build_id
        WHERE member.squad_revision_id = NEW.squad_revision_id
    ) THEN
        RAISE EXCEPTION 'profile_squad_membership_invalid';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM lab_profile.squad_revision_member AS member
        JOIN lab_profile.character_build_revision AS build
          ON build.build_revision_id = member.build_revision_id
        WHERE member.squad_revision_id = NEW.squad_revision_id
          AND (
              build.character_catalog_snapshot_id <>
                  NEW.character_catalog_snapshot_id
              OR build.character_dataset_snapshot_id <>
                  NEW.character_dataset_snapshot_id
              OR build.character_catalog_manifest_sha256 <>
                  NEW.character_catalog_manifest_sha256
              OR build.support_catalog_snapshot_id <> NEW.support_catalog_snapshot_id
              OR build.support_dataset_snapshot_id <> NEW.support_dataset_snapshot_id
              OR build.support_catalog_manifest_sha256 <>
                  NEW.support_catalog_manifest_sha256
          )
    ) THEN
        RAISE EXCEPTION 'profile_squad_catalog_binding_mismatch';
    END IF;
    IF (NEW.selection_readiness_status IS DISTINCT FROM (CASE
        WHEN EXISTS (
            SELECT 1
            FROM lab_profile.squad_revision_member AS member
            JOIN lab_profile.character_build_revision AS build
              ON build.build_revision_id = member.build_revision_id
            WHERE member.squad_revision_id = NEW.squad_revision_id
              AND build.selection_readiness_status <> 'ready'
        ) THEN 'unresolved'
        ELSE 'ready'
    END)) OR (NEW.combat_semantics_readiness_status IS DISTINCT FROM (CASE
        WHEN EXISTS (
            SELECT 1
            FROM lab_profile.squad_revision_member AS member
            JOIN lab_profile.character_build_revision AS build
              ON build.build_revision_id = member.build_revision_id
            WHERE member.squad_revision_id = NEW.squad_revision_id
              AND build.combat_semantics_readiness_status <> 'ready'
        ) THEN 'unresolved'
        ELSE 'ready'
    END)) THEN
        RAISE EXCEPTION 'profile_squad_readiness_mismatch';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_profile.guard_template_build_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_count INTEGER;
BEGIN
    SELECT build_count INTO expected_count
    FROM lab_profile.profile_template_revision
    WHERE profile_template_revision_id = NEW.profile_template_revision_id
    FOR UPDATE;

    IF expected_count IS NULL OR expected_count <= (
        SELECT count(*) FROM lab_profile.profile_template_revision_build
        WHERE profile_template_revision_id = NEW.profile_template_revision_id
    ) THEN
        RAISE EXCEPTION 'immutable_profile_row';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.require_complete_template()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.build_count <> (
        SELECT count(*) FROM lab_profile.profile_template_revision_build
        WHERE profile_template_revision_id = NEW.profile_template_revision_id
    ) THEN
        RAISE EXCEPTION 'profile_template_incomplete';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM lab_profile.profile_template_revision_build AS member
        JOIN lab_profile.character_build AS build
          ON build.character_build_id = member.character_build_id
        WHERE member.profile_template_revision_id = NEW.profile_template_revision_id
          AND build.local_account_id <> NEW.local_account_id
    ) OR NEW.build_count <> (
        SELECT count(DISTINCT build.character_entity_id)
        FROM lab_profile.profile_template_revision_build AS member
        JOIN lab_profile.character_build AS build
          ON build.character_build_id = member.character_build_id
        WHERE member.profile_template_revision_id = NEW.profile_template_revision_id
    ) THEN
        RAISE EXCEPTION 'profile_template_membership_invalid';
    END IF;

    IF NEW.is_combat_ready IS DISTINCT FROM (
        NEW.squad_revision_id IS NOT NULL
        AND EXISTS (
            SELECT 1
            FROM lab_profile.account_state_revision AS state
            WHERE state.account_state_revision_id = NEW.account_state_revision_id
              AND state.combat_readiness_status = 'ready'
        )
        AND NOT EXISTS (
            SELECT 1
            FROM lab_profile.squad_revision_member AS squad_member
            JOIN lab_profile.character_build_revision AS build
              ON build.build_revision_id = squad_member.build_revision_id
            WHERE squad_member.squad_revision_id = NEW.squad_revision_id
              AND (
                  build.selection_readiness_status <> 'ready'
              )
        )
    ) THEN
        RAISE EXCEPTION 'profile_combat_readiness_mismatch';
    END IF;

    IF NEW.has_complete_combat_semantics IS DISTINCT FROM (
        NEW.squad_revision_id IS NOT NULL
        AND EXISTS (
            SELECT 1
            FROM lab_profile.account_state_revision AS state
            WHERE state.account_state_revision_id = NEW.account_state_revision_id
              AND state.combat_readiness_status = 'ready'
        )
        AND NOT EXISTS (
            SELECT 1
            FROM lab_profile.squad_revision_member AS squad_member
            JOIN lab_profile.character_build_revision AS build
              ON build.build_revision_id = squad_member.build_revision_id
            WHERE squad_member.squad_revision_id = NEW.squad_revision_id
              AND (
                  build.selection_readiness_status <> 'ready'
                  OR build.combat_semantics_readiness_status <> 'ready'
              )
        )
    ) THEN
        RAISE EXCEPTION 'profile_combat_semantics_readiness_mismatch';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM lab_profile.account_state_revision AS state
        WHERE state.account_state_revision_id = NEW.account_state_revision_id
          AND (
              state.character_catalog_snapshot_id <>
                  NEW.character_catalog_snapshot_id
              OR state.character_dataset_snapshot_id <>
                  NEW.character_dataset_snapshot_id
              OR state.character_catalog_manifest_sha256 <>
                  NEW.character_catalog_manifest_sha256
              OR state.support_catalog_snapshot_id <> NEW.support_catalog_snapshot_id
              OR state.support_dataset_snapshot_id <> NEW.support_dataset_snapshot_id
              OR state.support_catalog_manifest_sha256 <>
                  NEW.support_catalog_manifest_sha256
          )
    ) OR EXISTS (
        SELECT 1
        FROM lab_profile.profile_template_revision_build AS member
        JOIN lab_profile.character_build_revision AS build
          ON build.build_revision_id = member.build_revision_id
        WHERE member.profile_template_revision_id = NEW.profile_template_revision_id
          AND (
              build.character_catalog_snapshot_id <>
                  NEW.character_catalog_snapshot_id
              OR build.character_dataset_snapshot_id <>
                  NEW.character_dataset_snapshot_id
              OR build.character_catalog_manifest_sha256 <>
                  NEW.character_catalog_manifest_sha256
              OR build.support_catalog_snapshot_id <> NEW.support_catalog_snapshot_id
              OR build.support_dataset_snapshot_id <> NEW.support_dataset_snapshot_id
              OR build.support_catalog_manifest_sha256 <>
                  NEW.support_catalog_manifest_sha256
          )
    ) OR (
        NEW.squad_revision_id IS NOT NULL AND EXISTS (
            SELECT 1
            FROM lab_profile.squad_revision AS squad
            WHERE squad.squad_revision_id = NEW.squad_revision_id
              AND (
                  squad.character_catalog_snapshot_id <>
                      NEW.character_catalog_snapshot_id
                  OR squad.character_dataset_snapshot_id <>
                      NEW.character_dataset_snapshot_id
                  OR squad.character_catalog_manifest_sha256 <>
                      NEW.character_catalog_manifest_sha256
                  OR squad.support_catalog_snapshot_id <>
                      NEW.support_catalog_snapshot_id
                  OR squad.support_dataset_snapshot_id <> NEW.support_dataset_snapshot_id
                  OR squad.support_catalog_manifest_sha256 <>
                      NEW.support_catalog_manifest_sha256
              )
        )
    ) THEN
        RAISE EXCEPTION 'profile_catalog_binding_mismatch';
    END IF;

    IF NEW.squad_revision_id IS NOT NULL AND EXISTS (
        SELECT 1
        FROM lab_profile.squad_revision_member AS squad_member
        WHERE squad_member.squad_revision_id = NEW.squad_revision_id
          AND NOT EXISTS (
              SELECT 1
              FROM lab_profile.profile_template_revision_build AS profile_build
              WHERE profile_build.profile_template_revision_id =
                    NEW.profile_template_revision_id
                AND profile_build.character_build_id = squad_member.character_build_id
                AND profile_build.build_revision_id = squad_member.build_revision_id
          )
    ) THEN
        RAISE EXCEPTION 'profile_squad_not_in_template';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_profile.guard_local_account_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.local_account_id <> OLD.local_account_id
       OR NEW.local_account_uid <> OLD.local_account_uid
       OR NEW.account_combat_state_uid <> OLD.account_combat_state_uid
       OR NEW.canonical_sha256 <> OLD.canonical_sha256
       OR NEW.created_at_utc <> OLD.created_at_utc
       OR NEW.current_account_state_revision_id IS NULL
       OR NEW.current_profile_template_revision_id IS NULL THEN
        RAISE EXCEPTION 'immutable_profile_row';
    END IF;
    IF OLD.current_account_state_revision_id IS NOT NULL
       AND NEW.current_account_state_revision_id <>
           OLD.current_account_state_revision_id
       AND NOT EXISTS (
           SELECT 1 FROM lab_profile.account_state_revision AS revision
           WHERE revision.account_state_revision_id =
                 NEW.current_account_state_revision_id
             AND revision.previous_account_state_revision_id =
                 OLD.current_account_state_revision_id
       ) THEN
        RAISE EXCEPTION 'profile_revision_lineage_invalid';
    END IF;
    IF OLD.current_profile_template_revision_id IS NOT NULL
       AND NEW.current_profile_template_revision_id <>
           OLD.current_profile_template_revision_id
       AND NOT EXISTS (
           SELECT 1 FROM lab_profile.profile_template_revision AS revision
           WHERE revision.profile_template_revision_id =
                 NEW.current_profile_template_revision_id
             AND revision.previous_profile_template_revision_id =
                 OLD.current_profile_template_revision_id
       ) THEN
        RAISE EXCEPTION 'profile_revision_lineage_invalid';
    END IF;
    IF OLD.current_squad_revision_id IS NOT NULL
       AND NEW.current_squad_revision_id IS NOT NULL
       AND NEW.current_squad_revision_id <> OLD.current_squad_revision_id
       AND NOT EXISTS (
           SELECT 1 FROM lab_profile.squad_revision AS revision
           WHERE revision.squad_revision_id = NEW.current_squad_revision_id
             AND revision.previous_squad_revision_id = OLD.current_squad_revision_id
       ) THEN
        RAISE EXCEPTION 'profile_revision_lineage_invalid';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.guard_character_build_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.character_build_id <> OLD.character_build_id
       OR NEW.character_build_uid <> OLD.character_build_uid
       OR NEW.local_account_id <> OLD.local_account_id
       OR NEW.character_entity_id <> OLD.character_entity_id
       OR NEW.created_at_utc <> OLD.created_at_utc
       OR NEW.current_build_revision_id IS NULL THEN
        RAISE EXCEPTION 'immutable_profile_row';
    END IF;
    IF OLD.current_build_revision_id IS NOT NULL
       AND NEW.current_build_revision_id <> OLD.current_build_revision_id
       AND NOT EXISTS (
           SELECT 1 FROM lab_profile.character_build_revision AS revision
           WHERE revision.build_revision_id = NEW.current_build_revision_id
             AND revision.previous_build_revision_id = OLD.current_build_revision_id
       ) THEN
        RAISE EXCEPTION 'profile_revision_lineage_invalid';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.guard_local_squad_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.local_squad_id <> OLD.local_squad_id
       OR NEW.local_squad_uid <> OLD.local_squad_uid
       OR NEW.local_account_id <> OLD.local_account_id
       OR NEW.created_at_utc <> OLD.created_at_utc
       OR NEW.current_squad_revision_id IS NULL THEN
        RAISE EXCEPTION 'immutable_profile_row';
    END IF;
    IF OLD.current_squad_revision_id IS NOT NULL
       AND NEW.current_squad_revision_id <> OLD.current_squad_revision_id
       AND NOT EXISTS (
           SELECT 1 FROM lab_profile.squad_revision AS revision
           WHERE revision.squad_revision_id = NEW.current_squad_revision_id
             AND revision.previous_squad_revision_id = OLD.current_squad_revision_id
       ) THEN
        RAISE EXCEPTION 'profile_revision_lineage_invalid';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.guard_profile_template_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.profile_template_id <> OLD.profile_template_id
       OR NEW.profile_template_uid <> OLD.profile_template_uid
       OR NEW.local_account_id <> OLD.local_account_id
       OR NEW.created_at_utc <> OLD.created_at_utc
       OR NEW.current_profile_template_revision_id IS NULL THEN
        RAISE EXCEPTION 'immutable_profile_row';
    END IF;
    IF OLD.current_profile_template_revision_id IS NOT NULL
       AND NEW.current_profile_template_revision_id <>
           OLD.current_profile_template_revision_id
       AND NOT EXISTS (
           SELECT 1 FROM lab_profile.profile_template_revision AS revision
           WHERE revision.profile_template_revision_id =
                 NEW.current_profile_template_revision_id
             AND revision.previous_profile_template_revision_id =
                 OLD.current_profile_template_revision_id
       ) THEN
        RAISE EXCEPTION 'profile_revision_lineage_invalid';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.require_current_graph_consistency()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    account_row lab_profile.local_account%ROWTYPE;
BEGIN
    SELECT * INTO account_row
    FROM lab_profile.local_account
    WHERE local_account_id = NEW.local_account_id;

    IF account_row.current_account_state_revision_id IS NULL
       OR account_row.current_profile_template_revision_id IS NULL
       OR NOT EXISTS (
          SELECT 1
          FROM lab_profile.profile_template AS template
          WHERE template.local_account_id = account_row.local_account_id
            AND template.current_profile_template_revision_id =
                account_row.current_profile_template_revision_id
       )
       OR (account_row.current_squad_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1
          FROM lab_profile.local_squad AS squad
          WHERE squad.local_account_id = account_row.local_account_id
            AND squad.current_squad_revision_id =
                account_row.current_squad_revision_id
       ))
       OR NOT EXISTS (
          SELECT 1
          FROM lab_profile.profile_template_revision revision
          WHERE revision.profile_template_revision_id =
                    account_row.current_profile_template_revision_id
            AND revision.account_state_revision_id =
                    account_row.current_account_state_revision_id
            AND revision.squad_revision_id IS NOT DISTINCT FROM
                    account_row.current_squad_revision_id
       )
       OR EXISTS (
          SELECT 1
          FROM lab_profile.profile_template_revision_build member
          JOIN lab_profile.character_build build
            ON build.character_build_id = member.character_build_id
          WHERE member.profile_template_revision_id =
                    account_row.current_profile_template_revision_id
            AND build.current_build_revision_id IS DISTINCT FROM member.build_revision_id
       )
       OR (account_row.current_squad_revision_id IS NOT NULL AND EXISTS (
          SELECT 1
          FROM lab_profile.squad_revision_member member
          JOIN lab_profile.character_build build
            ON build.character_build_id = member.character_build_id
          WHERE member.squad_revision_id = account_row.current_squad_revision_id
            AND build.current_build_revision_id IS DISTINCT FROM member.build_revision_id
       )) THEN
        RAISE EXCEPTION 'profile_current_graph_inconsistent';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_profile.guard_session_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE'
       OR NEW.local_session_id <> OLD.local_session_id
       OR NEW.local_session_uid <> OLD.local_session_uid
       OR NEW.local_account_id <> OLD.local_account_id
       OR NEW.issued_at_utc <> OLD.issued_at_utc
       OR NEW.expires_at_utc <> OLD.expires_at_utc
       OR OLD.revoked_at_utc IS NOT NULL
       OR NEW.revoked_at_utc IS NULL THEN
        RAISE EXCEPTION 'immutable_session_row';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_account_console_guard_insert
BEFORE INSERT ON lab_profile.account_console_state
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_account_console_insert();
CREATE TRIGGER trg_account_state_lineage
BEFORE INSERT ON lab_profile.account_state_revision
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_account_state_lineage();
CREATE CONSTRAINT TRIGGER trg_account_state_current
AFTER INSERT ON lab_profile.account_state_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_account_state_revision_current();
CREATE CONSTRAINT TRIGGER trg_account_state_complete
AFTER INSERT ON lab_profile.account_state_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_complete_account_state();

CREATE TRIGGER trg_build_equipment_guard_insert
BEFORE INSERT ON lab_profile.build_equipment_state
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_build_equipment_insert();
CREATE TRIGGER trg_build_revision_lineage
BEFORE INSERT ON lab_profile.character_build_revision
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_build_revision_lineage();
CREATE CONSTRAINT TRIGGER trg_build_revision_current
AFTER INSERT ON lab_profile.character_build_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_build_revision_current();
CREATE CONSTRAINT TRIGGER trg_build_complete
AFTER INSERT ON lab_profile.character_build_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_complete_build();

CREATE TRIGGER trg_overload_line_guard_insert
BEFORE INSERT ON lab_profile.build_overload_line
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_overload_line_insert();
CREATE CONSTRAINT TRIGGER trg_overload_lines_complete
AFTER INSERT ON lab_profile.build_equipment_state
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_complete_overload_lines();

CREATE TRIGGER trg_squad_member_guard_insert
BEFORE INSERT ON lab_profile.squad_revision_member
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_squad_member_insert();
CREATE TRIGGER trg_squad_revision_lineage
BEFORE INSERT ON lab_profile.squad_revision
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_squad_revision_lineage();
CREATE CONSTRAINT TRIGGER trg_squad_revision_current
AFTER INSERT ON lab_profile.squad_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_squad_revision_current();
CREATE CONSTRAINT TRIGGER trg_squad_complete
AFTER INSERT ON lab_profile.squad_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_complete_squad();

CREATE TRIGGER trg_template_build_guard_insert
BEFORE INSERT ON lab_profile.profile_template_revision_build
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_template_build_insert();
CREATE TRIGGER trg_template_revision_lineage
BEFORE INSERT ON lab_profile.profile_template_revision
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_template_revision_lineage();
CREATE CONSTRAINT TRIGGER trg_template_revision_current
AFTER INSERT ON lab_profile.profile_template_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_template_revision_current();
CREATE CONSTRAINT TRIGGER trg_template_complete
AFTER INSERT ON lab_profile.profile_template_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_complete_template();

CREATE CONSTRAINT TRIGGER trg_profile_operation_topology
AFTER INSERT ON lab_profile.profile_write_operation
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_profile_operation_topology();

CREATE TRIGGER trg_local_account_guard_update
BEFORE UPDATE ON lab_profile.local_account
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_local_account_update();
CREATE TRIGGER trg_local_account_reject_delete
BEFORE DELETE ON lab_profile.local_account
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE CONSTRAINT TRIGGER trg_current_graph_consistent
AFTER INSERT OR UPDATE ON lab_profile.local_account
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_current_graph_consistency();

CREATE TRIGGER trg_character_build_guard_update
BEFORE UPDATE ON lab_profile.character_build
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_character_build_update();
CREATE CONSTRAINT TRIGGER trg_character_build_current_graph_consistent
AFTER UPDATE ON lab_profile.character_build
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_current_graph_consistency();
CREATE TRIGGER trg_character_build_reject_delete
BEFORE DELETE ON lab_profile.character_build
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE TRIGGER trg_local_squad_guard_update
BEFORE UPDATE ON lab_profile.local_squad
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_local_squad_update();
CREATE CONSTRAINT TRIGGER trg_local_squad_current_graph_consistent
AFTER UPDATE ON lab_profile.local_squad
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_current_graph_consistency();
CREATE TRIGGER trg_local_squad_reject_delete
BEFORE DELETE ON lab_profile.local_squad
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE TRIGGER trg_profile_template_guard_update
BEFORE UPDATE ON lab_profile.profile_template
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_profile_template_update();
CREATE CONSTRAINT TRIGGER trg_profile_template_current_graph_consistent
AFTER UPDATE ON lab_profile.profile_template
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_profile.require_current_graph_consistency();
CREATE TRIGGER trg_profile_template_reject_delete
BEFORE DELETE ON lab_profile.profile_template
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();

CREATE TRIGGER trg_equipment_slot_entity_immutable
BEFORE UPDATE OR DELETE ON lab_profile.equipment_slot_entity
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE TRIGGER trg_account_state_revision_immutable
BEFORE UPDATE OR DELETE ON lab_profile.account_state_revision
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE TRIGGER trg_account_console_state_immutable
BEFORE UPDATE OR DELETE ON lab_profile.account_console_state
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE TRIGGER trg_build_revision_immutable
BEFORE UPDATE OR DELETE ON lab_profile.character_build_revision
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE TRIGGER trg_build_equipment_state_immutable
BEFORE UPDATE OR DELETE ON lab_profile.build_equipment_state
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE TRIGGER trg_build_overload_line_immutable
BEFORE UPDATE OR DELETE ON lab_profile.build_overload_line
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE TRIGGER trg_squad_revision_immutable
BEFORE UPDATE OR DELETE ON lab_profile.squad_revision
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE TRIGGER trg_squad_member_immutable
BEFORE UPDATE OR DELETE ON lab_profile.squad_revision_member
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE TRIGGER trg_template_revision_immutable
BEFORE UPDATE OR DELETE ON lab_profile.profile_template_revision
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE TRIGGER trg_template_revision_build_immutable
BEFORE UPDATE OR DELETE ON lab_profile.profile_template_revision_build
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE TRIGGER trg_profile_operation_immutable
BEFORE UPDATE OR DELETE ON lab_profile.profile_write_operation
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();

CREATE TRIGGER trg_local_session_mutation
BEFORE UPDATE OR DELETE ON lab_profile.local_session
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_session_mutation();

CREATE INDEX ix_profile_account_state_account
    ON lab_profile.account_state_revision(local_account_id);
CREATE INDEX ix_profile_build_account
    ON lab_profile.character_build(local_account_id);
CREATE INDEX ix_profile_build_revision_build
    ON lab_profile.character_build_revision(character_build_id);
CREATE INDEX ix_profile_operation_account
    ON lab_profile.profile_write_operation(local_account_id);
CREATE INDEX ix_profile_session_account
    ON lab_profile.local_session(local_account_id);
