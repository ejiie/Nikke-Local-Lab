CREATE SCHEMA lab_catalog;
CREATE SCHEMA lab_private;

REVOKE ALL ON SCHEMA lab_private FROM PUBLIC;

CREATE TABLE lab_meta.character_identity_key_binding (
    binding_id SMALLINT PRIMARY KEY CHECK (binding_id = 1),
    encoder_version TEXT NOT NULL CHECK (encoder_version = 'hmac_sha256_v1'),
    key_check_sha256 BYTEA NOT NULL CHECK (octet_length(key_check_sha256) = 32),
    created_at_utc TIMESTAMPTZ NOT NULL
);

CREATE TABLE lab_catalog.character_entity (
    character_entity_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    character_uid UUID NOT NULL UNIQUE CHECK (
        character_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    created_at_utc TIMESTAMPTZ NOT NULL
);

CREATE TABLE lab_private.character_source_alias (
    alias_fingerprint BYTEA PRIMARY KEY CHECK (octet_length(alias_fingerprint) = 32),
    character_entity_id BIGINT NOT NULL
        REFERENCES lab_catalog.character_entity(character_entity_id) ON DELETE RESTRICT,
    created_at_utc TIMESTAMPTZ NOT NULL
);

REVOKE ALL ON TABLE lab_private.character_source_alias FROM PUBLIC;

CREATE TABLE lab_catalog.character_definition_version (
    character_definition_version_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    character_definition_version_uid UUID NOT NULL UNIQUE CHECK (
        character_definition_version_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    character_entity_id BIGINT NOT NULL
        REFERENCES lab_catalog.character_entity(character_entity_id) ON DELETE RESTRICT,
    definition_content_sha256 BYTEA NOT NULL CHECK (octet_length(definition_content_sha256) = 32),
    normalized_shape_sha256 BYTEA NOT NULL CHECK (octet_length(normalized_shape_sha256) = 32),
    display_name_status TEXT NOT NULL CHECK (display_name_status IN ('ready', 'unresolved')),
    display_name TEXT,
    display_name_unresolved_reason_code TEXT CHECK (
        display_name_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    rarity_status TEXT NOT NULL CHECK (rarity_status IN ('ready', 'unresolved')),
    rarity_code TEXT CHECK (rarity_code IN ('r', 'sr', 'ssr')),
    rarity_unresolved_reason_code TEXT CHECK (
        rarity_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    combat_class_status TEXT NOT NULL CHECK (combat_class_status IN ('ready', 'unresolved')),
    combat_class_code TEXT CHECK (combat_class_code IN ('attacker', 'defender', 'supporter')),
    combat_class_unresolved_reason_code TEXT CHECK (
        combat_class_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    weapon_status TEXT NOT NULL CHECK (weapon_status IN ('ready', 'unresolved')),
    weapon_code TEXT CHECK (
        weapon_code IN (
            'assault_rifle', 'machine_gun', 'rocket_launcher',
            'shotgun', 'sniper_rifle', 'submachine_gun'
        )
    ),
    weapon_unresolved_reason_code TEXT CHECK (
        weapon_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    element_status TEXT NOT NULL CHECK (element_status IN ('ready', 'unresolved')),
    element_code TEXT CHECK (element_code IN ('electric', 'fire', 'iron', 'water', 'wind')),
    element_unresolved_reason_code TEXT CHECK (
        element_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    manufacturer_status TEXT NOT NULL CHECK (manufacturer_status IN ('ready', 'unresolved')),
    manufacturer_code TEXT CHECK (
        manufacturer_code IN ('abnormal', 'elysion', 'missilis', 'pilgrim', 'tetra')
    ),
    manufacturer_unresolved_reason_code TEXT CHECK (
        manufacturer_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    readiness_status TEXT NOT NULL CHECK (readiness_status IN ('ready', 'unresolved')),
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (character_entity_id, normalized_shape_sha256),
    UNIQUE (character_definition_version_id, character_entity_id),
    CHECK (
        (display_name_status = 'ready' AND display_name IS NOT NULL
            AND char_length(display_name) BETWEEN 1 AND 128
            AND display_name_unresolved_reason_code IS NULL)
        OR (display_name_status = 'unresolved' AND display_name IS NULL
            AND display_name_unresolved_reason_code IS NOT NULL)
    ),
    CHECK (
        (rarity_status = 'ready' AND rarity_code IS NOT NULL
            AND rarity_unresolved_reason_code IS NULL)
        OR (rarity_status = 'unresolved' AND rarity_code IS NULL
            AND rarity_unresolved_reason_code IS NOT NULL)
    ),
    CHECK (
        (combat_class_status = 'ready' AND combat_class_code IS NOT NULL
            AND combat_class_unresolved_reason_code IS NULL)
        OR (combat_class_status = 'unresolved' AND combat_class_code IS NULL
            AND combat_class_unresolved_reason_code IS NOT NULL)
    ),
    CHECK (
        (weapon_status = 'ready' AND weapon_code IS NOT NULL
            AND weapon_unresolved_reason_code IS NULL)
        OR (weapon_status = 'unresolved' AND weapon_code IS NULL
            AND weapon_unresolved_reason_code IS NOT NULL)
    ),
    CHECK (
        (element_status = 'ready' AND element_code IS NOT NULL
            AND element_unresolved_reason_code IS NULL)
        OR (element_status = 'unresolved' AND element_code IS NULL
            AND element_unresolved_reason_code IS NOT NULL)
    ),
    CHECK (
        (manufacturer_status = 'ready' AND manufacturer_code IS NOT NULL
            AND manufacturer_unresolved_reason_code IS NULL)
        OR (manufacturer_status = 'unresolved' AND manufacturer_code IS NULL
            AND manufacturer_unresolved_reason_code IS NOT NULL)
    )
);

CREATE TABLE lab_catalog.character_definition_capability (
    character_definition_version_id BIGINT NOT NULL
        REFERENCES lab_catalog.character_definition_version(character_definition_version_id) ON DELETE RESTRICT,
    capability_code TEXT NOT NULL CHECK (
        capability_code IN (
            'character_level', 'limit_break', 'core_level', 'bond_level',
            'cube', 'skill_1', 'skill_2', 'burst',
            'collection_item', 'favorite_item'
        )
    ),
    resolution_status TEXT NOT NULL CHECK (
        resolution_status IN ('ready', 'unresolved', 'not_applicable')
    ),
    unresolved_reason_code TEXT CHECK (
        unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    maximum_level INTEGER CHECK (maximum_level BETWEEN 0 AND 1000000),
    PRIMARY KEY (character_definition_version_id, capability_code),
    CHECK (
        (resolution_status = 'ready' AND unresolved_reason_code IS NULL
            AND maximum_level IS NOT NULL)
        OR (resolution_status = 'unresolved' AND unresolved_reason_code IS NOT NULL
            AND maximum_level IS NULL)
        OR (resolution_status = 'not_applicable' AND unresolved_reason_code IS NULL
            AND maximum_level IS NULL)
    ),
    CHECK (
        resolution_status <> 'not_applicable'
        OR capability_code IN ('core_level', 'cube', 'collection_item', 'favorite_item')
    ),
    CHECK (
        resolution_status <> 'ready'
        OR capability_code IN ('limit_break', 'core_level')
        OR maximum_level > 0
    )
);

CREATE TABLE lab_catalog.character_definition_equipment_capability (
    character_definition_version_id BIGINT NOT NULL
        REFERENCES lab_catalog.character_definition_version(character_definition_version_id) ON DELETE RESTRICT,
    equipment_slot TEXT NOT NULL CHECK (equipment_slot IN ('head', 'torso', 'arms', 'legs')),
    equipment_definition_status TEXT NOT NULL CHECK (
        equipment_definition_status IN ('ready', 'unresolved')
    ),
    equipment_definition_uid UUID,
    equipment_definition_unresolved_reason_code TEXT CHECK (
        equipment_definition_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    maximum_tier_status TEXT NOT NULL CHECK (maximum_tier_status IN ('ready', 'unresolved')),
    maximum_tier INTEGER CHECK (maximum_tier BETWEEN 0 AND 1000000),
    maximum_tier_unresolved_reason_code TEXT CHECK (
        maximum_tier_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    maximum_tier_ten_enhancement_status TEXT NOT NULL CHECK (
        maximum_tier_ten_enhancement_status IN ('ready', 'unresolved')
    ),
    maximum_tier_ten_enhancement_level INTEGER CHECK (
        maximum_tier_ten_enhancement_level BETWEEN 0 AND 1000000
    ),
    maximum_tier_ten_enhancement_unresolved_reason_code TEXT CHECK (
        maximum_tier_ten_enhancement_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    manufacturer_match_status TEXT NOT NULL CHECK (
        manufacturer_match_status IN ('ready', 'unresolved', 'not_applicable')
    ),
    manufacturer_match BOOLEAN,
    manufacturer_match_unresolved_reason_code TEXT CHECK (
        manufacturer_match_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    PRIMARY KEY (character_definition_version_id, equipment_slot),
    CHECK (
        (equipment_definition_status = 'ready' AND equipment_definition_uid IS NOT NULL
            AND equipment_definition_uid <> '00000000-0000-0000-0000-000000000000'::uuid
            AND equipment_definition_unresolved_reason_code IS NULL)
        OR (equipment_definition_status = 'unresolved' AND equipment_definition_uid IS NULL
            AND equipment_definition_unresolved_reason_code IS NOT NULL)
    ),
    CHECK (
        (maximum_tier_status = 'ready' AND maximum_tier IS NOT NULL
            AND maximum_tier_unresolved_reason_code IS NULL)
        OR (maximum_tier_status = 'unresolved' AND maximum_tier IS NULL
            AND maximum_tier_unresolved_reason_code IS NOT NULL)
    ),
    CHECK (
        (maximum_tier_ten_enhancement_status = 'ready'
            AND maximum_tier_ten_enhancement_level IS NOT NULL
            AND maximum_tier_ten_enhancement_unresolved_reason_code IS NULL)
        OR (maximum_tier_ten_enhancement_status = 'unresolved'
            AND maximum_tier_ten_enhancement_level IS NULL
            AND maximum_tier_ten_enhancement_unresolved_reason_code IS NOT NULL)
    ),
    CHECK (
        (manufacturer_match_status = 'ready' AND manufacturer_match IS NOT NULL
            AND manufacturer_match_unresolved_reason_code IS NULL)
        OR (manufacturer_match_status = 'unresolved' AND manufacturer_match IS NULL
            AND manufacturer_match_unresolved_reason_code IS NOT NULL)
        OR (manufacturer_match_status = 'not_applicable' AND manufacturer_match IS NULL
            AND manufacturer_match_unresolved_reason_code IS NULL)
    )
);

CREATE TABLE lab_catalog.character_catalog_snapshot (
    character_catalog_snapshot_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    character_catalog_snapshot_uid UUID NOT NULL UNIQUE CHECK (
        character_catalog_snapshot_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    dataset_snapshot_id BIGINT NOT NULL
        REFERENCES lab_import.dataset_snapshot(dataset_snapshot_id) ON DELETE RESTRICT,
    request_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(request_sha256) = 32),
    output_manifest_sha256 BYTEA NOT NULL CHECK (octet_length(output_manifest_sha256) = 32),
    catalog_manifest_sha256 BYTEA NOT NULL CHECK (octet_length(catalog_manifest_sha256) = 32),
    published_by_import_run_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_import.import_run(import_run_id) ON DELETE RESTRICT,
    created_at_utc TIMESTAMPTZ NOT NULL
);

CREATE TABLE lab_catalog.character_catalog_snapshot_member (
    character_catalog_snapshot_id BIGINT NOT NULL
        REFERENCES lab_catalog.character_catalog_snapshot(character_catalog_snapshot_id) ON DELETE RESTRICT,
    character_entity_id BIGINT NOT NULL
        REFERENCES lab_catalog.character_entity(character_entity_id) ON DELETE RESTRICT,
    character_definition_version_id BIGINT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    PRIMARY KEY (character_catalog_snapshot_id, character_entity_id),
    UNIQUE (character_catalog_snapshot_id, ordinal),
    FOREIGN KEY (character_definition_version_id, character_entity_id)
        REFERENCES lab_catalog.character_definition_version(
            character_definition_version_id,
            character_entity_id
        ) ON DELETE RESTRICT
);

CREATE INDEX ix_character_definition_version_entity
    ON lab_catalog.character_definition_version(character_entity_id);

CREATE INDEX ix_character_catalog_snapshot_member_version
    ON lab_catalog.character_catalog_snapshot_member(character_definition_version_id);

CREATE FUNCTION lab_catalog.reject_immutable_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'immutable_catalog_row';
END;
$$;

CREATE TRIGGER trg_character_definition_version_immutable
BEFORE UPDATE OR DELETE ON lab_catalog.character_definition_version
FOR EACH ROW EXECUTE FUNCTION lab_catalog.reject_immutable_mutation();

CREATE TRIGGER trg_character_identity_key_binding_immutable
BEFORE UPDATE OR DELETE ON lab_meta.character_identity_key_binding
FOR EACH ROW EXECUTE FUNCTION lab_catalog.reject_immutable_mutation();

CREATE TRIGGER trg_character_entity_immutable
BEFORE UPDATE OR DELETE ON lab_catalog.character_entity
FOR EACH ROW EXECUTE FUNCTION lab_catalog.reject_immutable_mutation();

CREATE TRIGGER trg_character_source_alias_immutable
BEFORE UPDATE OR DELETE ON lab_private.character_source_alias
FOR EACH ROW EXECUTE FUNCTION lab_catalog.reject_immutable_mutation();

CREATE TRIGGER trg_character_definition_capability_immutable
BEFORE UPDATE OR DELETE ON lab_catalog.character_definition_capability
FOR EACH ROW EXECUTE FUNCTION lab_catalog.reject_immutable_mutation();

CREATE TRIGGER trg_character_definition_equipment_capability_immutable
BEFORE UPDATE OR DELETE ON lab_catalog.character_definition_equipment_capability
FOR EACH ROW EXECUTE FUNCTION lab_catalog.reject_immutable_mutation();

CREATE TRIGGER trg_character_catalog_snapshot_immutable
BEFORE UPDATE OR DELETE ON lab_catalog.character_catalog_snapshot
FOR EACH ROW EXECUTE FUNCTION lab_catalog.reject_immutable_mutation();

CREATE TRIGGER trg_character_catalog_snapshot_member_immutable
BEFORE UPDATE OR DELETE ON lab_catalog.character_catalog_snapshot_member
FOR EACH ROW EXECUTE FUNCTION lab_catalog.reject_immutable_mutation();
