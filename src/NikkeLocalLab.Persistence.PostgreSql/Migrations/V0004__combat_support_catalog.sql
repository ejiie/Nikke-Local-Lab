CREATE SCHEMA lab_combat_support;

CREATE FUNCTION lab_combat_support.valid_fact(
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

CREATE TABLE lab_meta.combat_support_identity_key_binding (
    binding_id SMALLINT PRIMARY KEY CHECK (binding_id = 1),
    encoder_version TEXT NOT NULL CHECK (encoder_version = 'hmac_sha256_v1'),
    key_check_sha256 BYTEA NOT NULL CHECK (octet_length(key_check_sha256) = 32),
    created_at_utc TIMESTAMPTZ NOT NULL
);

CREATE TABLE lab_combat_support.definition_entity (
    definition_entity_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    definition_uid UUID NOT NULL UNIQUE CHECK (
        definition_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    definition_kind TEXT NOT NULL CHECK (
        definition_kind IN (
            'equipment', 'cube', 'collection', 'favorite', 'console', 'overload_option'
        )
    ),
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (definition_entity_id, definition_kind)
);

CREATE TABLE lab_private.combat_support_source_alias (
    alias_fingerprint BYTEA PRIMARY KEY CHECK (octet_length(alias_fingerprint) = 32),
    definition_entity_id BIGINT NOT NULL UNIQUE,
    definition_kind TEXT NOT NULL,
    created_at_utc TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (definition_entity_id, definition_kind)
        REFERENCES lab_combat_support.definition_entity(
            definition_entity_id,
            definition_kind
        ) ON DELETE RESTRICT
);

REVOKE ALL ON TABLE lab_private.combat_support_source_alias FROM PUBLIC;

CREATE TABLE lab_combat_support.definition_version (
    definition_version_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    definition_version_uid UUID NOT NULL UNIQUE CHECK (
        definition_version_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    definition_entity_id BIGINT NOT NULL,
    definition_kind TEXT NOT NULL,
    definition_content_sha256 BYTEA NOT NULL CHECK (
        octet_length(definition_content_sha256) = 32
    ),
    domain_canonical_sha256 BYTEA NOT NULL CHECK (
        octet_length(domain_canonical_sha256) = 32
    ),
    display_name_status TEXT NOT NULL CHECK (
        display_name_status IN ('ready', 'unresolved')
    ),
    display_name TEXT,
    display_name_unresolved_reason_code TEXT CHECK (
        display_name_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    contribution_status TEXT NOT NULL CHECK (
        contribution_status IN ('ready', 'unresolved', 'not_applicable')
    ),
    contribution_unresolved_reason_code TEXT CHECK (
        contribution_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    stat_contribution_count INTEGER NOT NULL CHECK (stat_contribution_count >= 0),
    skill_coordinate_count INTEGER NOT NULL CHECK (skill_coordinate_count >= 0),
    level_coordinate_count INTEGER NOT NULL CHECK (level_coordinate_count >= 0),
    equipment_option_slot_count INTEGER NOT NULL CHECK (equipment_option_slot_count >= 0),
    legal_level_count INTEGER NOT NULL CHECK (legal_level_count >= 0),
    overload_legal_band_count INTEGER NOT NULL CHECK (overload_legal_band_count >= 0),
    overload_legal_value_count INTEGER NOT NULL CHECK (overload_legal_value_count >= 0),
    source_readiness_status TEXT NOT NULL CHECK (
        source_readiness_status IN ('ready', 'unresolved')
    ),
    profile_selectable_status TEXT NOT NULL CHECK (
        profile_selectable_status IN ('ready', 'unresolved')
    ),
    game_legal_readiness_status TEXT NOT NULL CHECK (
        game_legal_readiness_status IN ('ready', 'unresolved')
    ),
    complete_semantics_status TEXT NOT NULL CHECK (
        complete_semantics_status IN ('ready', 'unresolved')
    ),
    duplicate_policy_readiness_status TEXT NOT NULL CHECK (
        duplicate_policy_readiness_status IN ('ready', 'unresolved')
    ),
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (definition_entity_id, definition_content_sha256),
    UNIQUE (definition_version_id, definition_entity_id),
    UNIQUE (definition_version_id, definition_entity_id, definition_kind),
    FOREIGN KEY (definition_entity_id, definition_kind)
        REFERENCES lab_combat_support.definition_entity(
            definition_entity_id,
            definition_kind
        ) ON DELETE RESTRICT,
    CHECK (
        lab_combat_support.valid_fact(
            display_name_status,
            display_name IS NOT NULL,
            display_name_unresolved_reason_code
        )
    ),
    CHECK (display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 128),
    CHECK (
        (contribution_status = 'ready' AND contribution_unresolved_reason_code IS NULL)
        OR (contribution_status = 'unresolved'
            AND stat_contribution_count = 0
            AND skill_coordinate_count = 0
            AND contribution_unresolved_reason_code IS NOT NULL)
        OR (contribution_status = 'not_applicable'
            AND stat_contribution_count = 0
            AND skill_coordinate_count = 0
            AND contribution_unresolved_reason_code IS NULL)
    ),
    CHECK (definition_kind = 'equipment' OR equipment_option_slot_count = 0),
    CHECK (definition_kind = 'console' OR legal_level_count = 0),
    CHECK (
        definition_kind IN ('cube', 'collection', 'favorite') OR level_coordinate_count = 0
    ),
    CHECK (
        definition_kind = 'overload_option'
        OR (overload_legal_band_count = 0 AND overload_legal_value_count = 0)
    ),
    CHECK (game_legal_readiness_status <> 'ready' OR (
        source_readiness_status = 'ready' AND profile_selectable_status = 'ready'
    )),
    CHECK (complete_semantics_status <> 'ready' OR game_legal_readiness_status = 'ready'),
    CHECK (
        definition_kind = 'overload_option'
        OR duplicate_policy_readiness_status = 'ready'
    )
);

CREATE TABLE lab_combat_support.equipment_definition_detail (
    definition_version_id BIGINT PRIMARY KEY,
    definition_entity_id BIGINT NOT NULL,
    definition_kind TEXT NOT NULL CHECK (definition_kind = 'equipment'),
    equipment_slot TEXT NOT NULL CHECK (equipment_slot IN ('head', 'torso', 'arms', 'legs')),
    combat_class_status TEXT NOT NULL,
    combat_class_code TEXT CHECK (combat_class_code IN ('attacker', 'defender', 'supporter')),
    combat_class_unresolved_reason_code TEXT CHECK (
        combat_class_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    manufacturer_status TEXT NOT NULL,
    manufacturer_code TEXT CHECK (
        manufacturer_code IN ('abnormal', 'elysion', 'missilis', 'pilgrim', 'tetra')
    ),
    manufacturer_unresolved_reason_code TEXT CHECK (
        manufacturer_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    tier_status TEXT NOT NULL,
    tier_value INTEGER CHECK (tier_value IN (9, 10)),
    tier_unresolved_reason_code TEXT CHECK (
        tier_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    enhancement_grade_status TEXT NOT NULL,
    enhancement_grade INTEGER CHECK (enhancement_grade BETWEEN 0 AND 1000000),
    enhancement_grade_unresolved_reason_code TEXT CHECK (
        enhancement_grade_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    enhancement_status TEXT NOT NULL,
    maximum_enhancement_level INTEGER CHECK (maximum_enhancement_level BETWEEN 0 AND 1000000),
    enhancement_unresolved_reason_code TEXT CHECK (
        enhancement_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    overload_eligible_status TEXT NOT NULL,
    overload_eligible BOOLEAN,
    overload_eligible_unresolved_reason_code TEXT CHECK (
        overload_eligible_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    FOREIGN KEY (definition_version_id, definition_entity_id, definition_kind)
        REFERENCES lab_combat_support.definition_version(
            definition_version_id,
            definition_entity_id,
            definition_kind
        ) ON DELETE RESTRICT,
    CHECK (lab_combat_support.valid_fact(
        combat_class_status, combat_class_code IS NOT NULL,
        combat_class_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        manufacturer_status, manufacturer_code IS NOT NULL,
        manufacturer_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        tier_status, tier_value IS NOT NULL, tier_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        enhancement_grade_status, enhancement_grade IS NOT NULL,
        enhancement_grade_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        enhancement_status, maximum_enhancement_level IS NOT NULL,
        enhancement_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        overload_eligible_status, overload_eligible IS NOT NULL,
        overload_eligible_unresolved_reason_code))
);

CREATE TABLE lab_combat_support.cube_definition_detail (
    definition_version_id BIGINT PRIMARY KEY,
    definition_entity_id BIGINT NOT NULL,
    definition_kind TEXT NOT NULL CHECK (definition_kind = 'cube'),
    rarity_status TEXT NOT NULL,
    rarity_code TEXT CHECK (rarity_code IN ('r', 'sr', 'ssr')),
    rarity_unresolved_reason_code TEXT CHECK (
        rarity_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    applicable_combat_class_status TEXT NOT NULL,
    applicable_combat_class_code TEXT CHECK (
        applicable_combat_class_code IN ('attacker', 'defender', 'supporter')
    ),
    applicable_combat_class_unresolved_reason_code TEXT CHECK (
        applicable_combat_class_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    maximum_level_status TEXT NOT NULL,
    maximum_level INTEGER CHECK (maximum_level BETWEEN 1 AND 1000000),
    maximum_level_unresolved_reason_code TEXT CHECK (
        maximum_level_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    skill_semantics_status TEXT NOT NULL CHECK (skill_semantics_status IN ('ready', 'unresolved')),
    skill_semantics BOOLEAN,
    skill_semantics_unresolved_reason_code TEXT CHECK (
        skill_semantics_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    FOREIGN KEY (definition_version_id, definition_entity_id, definition_kind)
        REFERENCES lab_combat_support.definition_version(
            definition_version_id,
            definition_entity_id,
            definition_kind
        ) ON DELETE RESTRICT,
    CHECK (lab_combat_support.valid_fact(
        rarity_status, rarity_code IS NOT NULL, rarity_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        applicable_combat_class_status, applicable_combat_class_code IS NOT NULL,
        applicable_combat_class_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        maximum_level_status, maximum_level IS NOT NULL,
        maximum_level_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        skill_semantics_status, skill_semantics IS NOT NULL,
        skill_semantics_unresolved_reason_code)),
    CHECK (skill_semantics IS NULL OR skill_semantics)
);

CREATE TABLE lab_combat_support.collection_definition_detail (
    definition_version_id BIGINT PRIMARY KEY,
    definition_entity_id BIGINT NOT NULL,
    definition_kind TEXT NOT NULL CHECK (definition_kind = 'collection'),
    weapon_class_status TEXT NOT NULL,
    weapon_class_code TEXT CHECK (
        weapon_class_code IN (
            'assault_rifle', 'machine_gun', 'rocket_launcher',
            'shotgun', 'sniper_rifle', 'submachine_gun'
        )
    ),
    weapon_class_unresolved_reason_code TEXT CHECK (
        weapon_class_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    rarity_status TEXT NOT NULL,
    rarity_code TEXT CHECK (rarity_code IN ('r', 'sr', 'ssr')),
    rarity_unresolved_reason_code TEXT CHECK (
        rarity_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    maximum_level_status TEXT NOT NULL,
    maximum_level INTEGER CHECK (maximum_level BETWEEN 1 AND 1000000),
    maximum_level_unresolved_reason_code TEXT CHECK (
        maximum_level_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    skill_semantics_status TEXT NOT NULL CHECK (skill_semantics_status IN ('ready', 'unresolved')),
    skill_semantics BOOLEAN,
    skill_semantics_unresolved_reason_code TEXT CHECK (
        skill_semantics_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    FOREIGN KEY (definition_version_id, definition_entity_id, definition_kind)
        REFERENCES lab_combat_support.definition_version(
            definition_version_id,
            definition_entity_id,
            definition_kind
        ) ON DELETE RESTRICT,
    CHECK (lab_combat_support.valid_fact(
        weapon_class_status, weapon_class_code IS NOT NULL,
        weapon_class_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        rarity_status, rarity_code IS NOT NULL, rarity_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        maximum_level_status, maximum_level IS NOT NULL,
        maximum_level_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        skill_semantics_status, skill_semantics IS NOT NULL,
        skill_semantics_unresolved_reason_code)),
    CHECK (skill_semantics IS NULL OR skill_semantics)
);

CREATE TABLE lab_combat_support.favorite_definition_detail (
    definition_version_id BIGINT PRIMARY KEY,
    definition_entity_id BIGINT NOT NULL,
    definition_kind TEXT NOT NULL CHECK (definition_kind = 'favorite'),
    maximum_level_status TEXT NOT NULL,
    maximum_level INTEGER CHECK (maximum_level BETWEEN 1 AND 1000000),
    maximum_level_unresolved_reason_code TEXT CHECK (
        maximum_level_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    rarity_status TEXT NOT NULL,
    rarity_code TEXT CHECK (rarity_code IN ('r', 'sr', 'ssr')),
    rarity_unresolved_reason_code TEXT CHECK (
        rarity_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    applicable_character_status TEXT NOT NULL CHECK (
        applicable_character_status IN ('ready', 'unresolved')
    ),
    applicable_character_entity_id BIGINT
        REFERENCES lab_catalog.character_entity(character_entity_id) ON DELETE RESTRICT,
    applicable_character_unresolved_reason_code TEXT CHECK (
        applicable_character_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    skill_semantics_status TEXT NOT NULL CHECK (skill_semantics_status IN ('ready', 'unresolved')),
    skill_semantics BOOLEAN,
    skill_semantics_unresolved_reason_code TEXT CHECK (
        skill_semantics_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    FOREIGN KEY (definition_version_id, definition_entity_id, definition_kind)
        REFERENCES lab_combat_support.definition_version(
            definition_version_id,
            definition_entity_id,
            definition_kind
        ) ON DELETE RESTRICT,
    CHECK (lab_combat_support.valid_fact(
        maximum_level_status, maximum_level IS NOT NULL,
        maximum_level_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        rarity_status, rarity_code IS NOT NULL, rarity_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        applicable_character_status, applicable_character_entity_id IS NOT NULL,
        applicable_character_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        skill_semantics_status, skill_semantics IS NOT NULL,
        skill_semantics_unresolved_reason_code)),
    CHECK (skill_semantics IS NULL OR skill_semantics)
);

CREATE TABLE lab_combat_support.console_definition_detail (
    definition_version_id BIGINT PRIMARY KEY,
    definition_entity_id BIGINT NOT NULL,
    definition_kind TEXT NOT NULL CHECK (definition_kind = 'console'),
    coordinate_code TEXT NOT NULL CHECK (
        coordinate_code IN (
            'common', 'attacker', 'defender', 'supporter',
            'elysion', 'missilis', 'tetra', 'pilgrim', 'abnormal'
        )
    ),
    maximum_level_status TEXT NOT NULL,
    maximum_level INTEGER CHECK (maximum_level BETWEEN 1 AND 1000000),
    maximum_level_unresolved_reason_code TEXT CHECK (
        maximum_level_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    FOREIGN KEY (definition_version_id, definition_entity_id, definition_kind)
        REFERENCES lab_combat_support.definition_version(
            definition_version_id,
            definition_entity_id,
            definition_kind
        ) ON DELETE RESTRICT,
    CHECK (lab_combat_support.valid_fact(
        maximum_level_status, maximum_level IS NOT NULL,
        maximum_level_unresolved_reason_code))
);

CREATE TABLE lab_combat_support.overload_option_definition_detail (
    definition_version_id BIGINT PRIMARY KEY,
    definition_entity_id BIGINT NOT NULL,
    definition_kind TEXT NOT NULL CHECK (definition_kind = 'overload_option'),
    option_type_status TEXT NOT NULL CHECK (option_type_status IN ('ready', 'unresolved')),
    option_type_code TEXT CHECK (
        option_type_code IN (
            'attack', 'defence', 'maximum_ammunition', 'critical_rate',
            'critical_damage', 'charge_damage', 'charge_speed',
            'elemental_damage', 'hit_rate'
        )
    ),
    option_type_unresolved_reason_code TEXT CHECK (
        option_type_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    unit_status TEXT NOT NULL CHECK (unit_status IN ('ready', 'unresolved')),
    unit_code TEXT CHECK (unit_code IN ('absolute', 'ratio', 'percent', 'count')),
    unit_unresolved_reason_code TEXT CHECK (
        unit_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    kind_probability_unscaled_value BIGINT NOT NULL,
    kind_probability_decimal_scale SMALLINT NOT NULL CHECK (
        kind_probability_decimal_scale BETWEEN 0 AND 9
    ),
    duplicate_policy_status TEXT NOT NULL CHECK (
        duplicate_policy_status IN ('ready', 'unresolved')
    ),
    duplicate_policy_code TEXT CHECK (
        duplicate_policy_code IN ('allow_same_type', 'forbid_same_type')
    ),
    duplicate_policy_unresolved_reason_code TEXT CHECK (
        duplicate_policy_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    FOREIGN KEY (definition_version_id, definition_entity_id, definition_kind)
        REFERENCES lab_combat_support.definition_version(
            definition_version_id,
            definition_entity_id,
            definition_kind
        ) ON DELETE RESTRICT,
    CHECK (lab_combat_support.valid_fact(
        option_type_status, option_type_code IS NOT NULL,
        option_type_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        unit_status, unit_code IS NOT NULL, unit_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        duplicate_policy_status, duplicate_policy_code IS NOT NULL,
        duplicate_policy_unresolved_reason_code)),
    CHECK (
        kind_probability_unscaled_value >= 0
        AND kind_probability_unscaled_value::numeric
            <= power(10::numeric, kind_probability_decimal_scale)
    )
);

CREATE TABLE lab_combat_support.definition_stat_contribution (
    definition_version_id BIGINT NOT NULL
        REFERENCES lab_combat_support.definition_version(definition_version_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    unlock_level INTEGER NOT NULL CHECK (unlock_level BETWEEN 0 AND 1000000),
    stat_status TEXT NOT NULL,
    stat_code TEXT CHECK (stat_code IN (
        'attack', 'defence', 'hp', 'energy_resistance',
        'metal_resistance', 'bio_resistance'
    )),
    stat_unresolved_reason_code TEXT CHECK (
        stat_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    unit_status TEXT NOT NULL,
    unit_code TEXT CHECK (unit_code IN ('absolute', 'ratio', 'percent', 'count')),
    unit_unresolved_reason_code TEXT CHECK (
        unit_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    exact_unscaled_value BIGINT NOT NULL,
    exact_decimal_scale SMALLINT NOT NULL CHECK (exact_decimal_scale BETWEEN 0 AND 9),
    PRIMARY KEY (definition_version_id, ordinal),
    CHECK (lab_combat_support.valid_fact(
        stat_status, stat_code IS NOT NULL, stat_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        unit_status, unit_code IS NOT NULL, unit_unresolved_reason_code))
);

CREATE TABLE lab_combat_support.definition_skill_coordinate (
    definition_version_id BIGINT NOT NULL
        REFERENCES lab_combat_support.definition_version(definition_version_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    unlock_level INTEGER NOT NULL CHECK (unlock_level BETWEEN 0 AND 1000000),
    skill_slot_ordinal INTEGER NOT NULL CHECK (skill_slot_ordinal BETWEEN 0 AND 1000000),
    skill_level INTEGER NOT NULL CHECK (skill_level BETWEEN 0 AND 1000000),
    PRIMARY KEY (definition_version_id, ordinal),
    UNIQUE (definition_version_id, unlock_level, skill_slot_ordinal)
);

CREATE TABLE lab_combat_support.definition_level_coordinate (
    definition_version_id BIGINT NOT NULL
        REFERENCES lab_combat_support.definition_version(definition_version_id) ON DELETE RESTRICT,
    level INTEGER NOT NULL CHECK (level BETWEEN 0 AND 1000000),
    grade_status TEXT NOT NULL,
    grade_value INTEGER CHECK (grade_value BETWEEN 0 AND 1000000),
    grade_unresolved_reason_code TEXT CHECK (
        grade_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    capacity_status TEXT NOT NULL,
    capacity_value INTEGER CHECK (capacity_value BETWEEN 0 AND 1000000),
    capacity_unresolved_reason_code TEXT CHECK (
        capacity_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    minimum_synchro_status TEXT NOT NULL,
    minimum_synchro_level INTEGER CHECK (minimum_synchro_level BETWEEN 0 AND 1000000),
    minimum_synchro_unresolved_reason_code TEXT CHECK (
        minimum_synchro_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    PRIMARY KEY (definition_version_id, level),
    CHECK (lab_combat_support.valid_fact(
        grade_status, grade_value IS NOT NULL, grade_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        capacity_status, capacity_value IS NOT NULL, capacity_unresolved_reason_code)),
    CHECK (lab_combat_support.valid_fact(
        minimum_synchro_status, minimum_synchro_level IS NOT NULL,
        minimum_synchro_unresolved_reason_code))
);

CREATE TABLE lab_combat_support.equipment_option_slot (
    definition_version_id BIGINT NOT NULL
        REFERENCES lab_combat_support.equipment_definition_detail(definition_version_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    success_ratio_unscaled_value BIGINT NOT NULL,
    success_ratio_decimal_scale SMALLINT NOT NULL CHECK (
        success_ratio_decimal_scale BETWEEN 0 AND 9
    ),
    PRIMARY KEY (definition_version_id, ordinal),
    CHECK (
        success_ratio_unscaled_value >= 0
        AND success_ratio_unscaled_value::numeric
            <= power(10::numeric, success_ratio_decimal_scale)
    )
);

CREATE TABLE lab_combat_support.console_legal_level (
    definition_version_id BIGINT NOT NULL
        REFERENCES lab_combat_support.console_definition_detail(definition_version_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    level INTEGER NOT NULL CHECK (level BETWEEN 1 AND 1000000),
    minimum_synchro_level INTEGER NOT NULL CHECK (
        minimum_synchro_level BETWEEN 0 AND 1000000
    ),
    PRIMARY KEY (definition_version_id, ordinal),
    UNIQUE (definition_version_id, level),
    CHECK (level = ordinal + 1)
);

CREATE TABLE lab_combat_support.overload_legal_band (
    definition_version_id BIGINT NOT NULL
        REFERENCES lab_combat_support.overload_option_definition_detail(definition_version_id)
        ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    probability_unscaled_value BIGINT NOT NULL,
    probability_decimal_scale SMALLINT NOT NULL CHECK (
        probability_decimal_scale BETWEEN 0 AND 9
    ),
    PRIMARY KEY (definition_version_id, ordinal),
    CHECK (
        probability_unscaled_value >= 0
        AND probability_unscaled_value::numeric
            <= power(10::numeric, probability_decimal_scale)
    )
);

CREATE TABLE lab_combat_support.overload_legal_value (
    definition_version_id BIGINT NOT NULL,
    band_ordinal INTEGER NOT NULL CHECK (band_ordinal >= 0),
    value_ordinal INTEGER NOT NULL CHECK (value_ordinal >= 0),
    roll_level INTEGER NOT NULL CHECK (roll_level BETWEEN 1 AND 15),
    source_raw_value BIGINT NOT NULL,
    magnitude_basis_points INTEGER NOT NULL CHECK (magnitude_basis_points > 0),
    engine_fraction_unscaled_value BIGINT NOT NULL,
    engine_fraction_decimal_scale SMALLINT NOT NULL CHECK (
        engine_fraction_decimal_scale BETWEEN 0 AND 9
    ),
    PRIMARY KEY (definition_version_id, band_ordinal, value_ordinal),
    UNIQUE (definition_version_id, roll_level),
    FOREIGN KEY (definition_version_id, band_ordinal)
        REFERENCES lab_combat_support.overload_legal_band(definition_version_id, ordinal)
        ON DELETE RESTRICT,
    CHECK (source_raw_value <> '-9223372036854775808'::bigint),
    CHECK (abs(source_raw_value) = magnitude_basis_points),
    CHECK (
        engine_fraction_unscaled_value = magnitude_basis_points
        AND engine_fraction_decimal_scale = 4
    )
);

CREATE TABLE lab_private.overload_legal_value_source_alias (
    alias_fingerprint BYTEA NOT NULL CHECK (octet_length(alias_fingerprint) = 32),
    definition_entity_id BIGINT NOT NULL,
    definition_version_id BIGINT NOT NULL,
    definition_kind TEXT NOT NULL DEFAULT 'overload_option' CHECK (
        definition_kind = 'overload_option'
    ),
    roll_level INTEGER NOT NULL CHECK (roll_level BETWEEN 1 AND 15),
    created_at_utc TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (alias_fingerprint, definition_version_id),
    UNIQUE (definition_version_id, roll_level),
    FOREIGN KEY (definition_version_id, definition_entity_id, definition_kind)
        REFERENCES lab_combat_support.definition_version(
            definition_version_id,
            definition_entity_id,
            definition_kind
        ) ON DELETE RESTRICT,
    FOREIGN KEY (definition_version_id, roll_level)
        REFERENCES lab_combat_support.overload_legal_value(definition_version_id, roll_level)
        ON DELETE RESTRICT
);

REVOKE ALL ON TABLE lab_private.overload_legal_value_source_alias FROM PUBLIC;

CREATE TABLE lab_combat_support.catalog_snapshot (
    catalog_snapshot_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    catalog_snapshot_uid UUID NOT NULL UNIQUE CHECK (
        catalog_snapshot_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    dataset_snapshot_id BIGINT NOT NULL
        REFERENCES lab_import.dataset_snapshot(dataset_snapshot_id) ON DELETE RESTRICT,
    request_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(request_sha256) = 32),
    output_manifest_sha256 BYTEA NOT NULL CHECK (octet_length(output_manifest_sha256) = 32),
    catalog_manifest_sha256 BYTEA NOT NULL CHECK (octet_length(catalog_manifest_sha256) = 32),
    published_by_import_run_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_import.import_run(import_run_id) ON DELETE RESTRICT,
    member_count INTEGER NOT NULL CHECK (member_count > 0),
    created_at_utc TIMESTAMPTZ NOT NULL
);

CREATE TABLE lab_combat_support.catalog_snapshot_member (
    catalog_snapshot_id BIGINT NOT NULL
        REFERENCES lab_combat_support.catalog_snapshot(catalog_snapshot_id) ON DELETE RESTRICT,
    definition_entity_id BIGINT NOT NULL,
    definition_version_id BIGINT NOT NULL,
    definition_kind TEXT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    PRIMARY KEY (catalog_snapshot_id, definition_entity_id),
    UNIQUE (catalog_snapshot_id, ordinal),
    FOREIGN KEY (definition_version_id, definition_entity_id, definition_kind)
        REFERENCES lab_combat_support.definition_version(
            definition_version_id,
            definition_entity_id,
            definition_kind
        ) ON DELETE RESTRICT
);

CREATE TABLE lab_combat_support.catalog_import_projection (
    import_run_id BIGINT PRIMARY KEY
        REFERENCES lab_import.import_run(import_run_id) ON DELETE RESTRICT,
    catalog_snapshot_id BIGINT NOT NULL
        REFERENCES lab_combat_support.catalog_snapshot(catalog_snapshot_id) ON DELETE RESTRICT,
    created_at_utc TIMESTAMPTZ NOT NULL
);

CREATE INDEX ix_support_alias_entity
    ON lab_private.combat_support_source_alias(definition_entity_id);
CREATE INDEX ix_support_value_alias_version
    ON lab_private.overload_legal_value_source_alias(definition_version_id);
CREATE INDEX ix_support_version_entity
    ON lab_combat_support.definition_version(definition_entity_id);
CREATE INDEX ix_support_contribution_version
    ON lab_combat_support.definition_stat_contribution(definition_version_id);
CREATE INDEX ix_support_skill_coordinate_version
    ON lab_combat_support.definition_skill_coordinate(definition_version_id);
CREATE INDEX ix_support_level_coordinate_version
    ON lab_combat_support.definition_level_coordinate(definition_version_id);
CREATE INDEX ix_support_equipment_option_version
    ON lab_combat_support.equipment_option_slot(definition_version_id);
CREATE INDEX ix_support_console_level_version
    ON lab_combat_support.console_legal_level(definition_version_id);
CREATE INDEX ix_support_overload_value_version
    ON lab_combat_support.overload_legal_value(definition_version_id);
CREATE INDEX ix_support_catalog_dataset
    ON lab_combat_support.catalog_snapshot(dataset_snapshot_id);
CREATE INDEX ix_support_catalog_member_version
    ON lab_combat_support.catalog_snapshot_member(definition_version_id);
CREATE INDEX ix_support_projection_catalog
    ON lab_combat_support.catalog_import_projection(catalog_snapshot_id);

CREATE FUNCTION lab_combat_support.reject_immutable_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'immutable_combat_support_row';
END;
$$;

CREATE TRIGGER trg_support_key_binding_immutable
BEFORE UPDATE OR DELETE ON lab_meta.combat_support_identity_key_binding
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_entity_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.definition_entity
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_alias_immutable
BEFORE UPDATE OR DELETE ON lab_private.combat_support_source_alias
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_version_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.definition_version
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_equipment_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.equipment_definition_detail
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_cube_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.cube_definition_detail
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_collection_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.collection_definition_detail
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_favorite_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.favorite_definition_detail
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_console_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.console_definition_detail
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_overload_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.overload_option_definition_detail
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_contribution_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.definition_stat_contribution
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_skill_coordinate_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.definition_skill_coordinate
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_level_coordinate_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.definition_level_coordinate
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_equipment_option_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.equipment_option_slot
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_console_level_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.console_legal_level
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_overload_band_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.overload_legal_band
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_overload_value_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.overload_legal_value
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_value_alias_immutable
BEFORE UPDATE OR DELETE ON lab_private.overload_legal_value_source_alias
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_catalog_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.catalog_snapshot
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_member_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.catalog_snapshot_member
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();
CREATE TRIGGER trg_support_projection_immutable
BEFORE UPDATE OR DELETE ON lab_combat_support.catalog_import_projection
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.reject_immutable_mutation();

CREATE FUNCTION lab_combat_support.guard_version_child_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1
    FROM lab_combat_support.definition_version
    WHERE definition_version_id = NEW.definition_version_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'combat_support_version_missing';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM lab_combat_support.catalog_snapshot_member
        WHERE definition_version_id = NEW.definition_version_id
    ) THEN
        RAISE EXCEPTION 'immutable_combat_support_row';
    END IF;

    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_combat_support.guard_entity_alias_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1
    FROM lab_combat_support.definition_entity
    WHERE definition_entity_id = NEW.definition_entity_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'combat_support_entity_missing';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM lab_combat_support.catalog_snapshot_member AS member
        JOIN lab_combat_support.definition_version AS version
          ON version.definition_version_id = member.definition_version_id
        WHERE version.definition_entity_id = NEW.definition_entity_id
    ) THEN
        RAISE EXCEPTION 'immutable_combat_support_row';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_support_alias_guard_insert
BEFORE INSERT ON lab_private.combat_support_source_alias
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_entity_alias_insert();

CREATE TRIGGER trg_support_equipment_guard_insert
BEFORE INSERT ON lab_combat_support.equipment_definition_detail
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();
CREATE TRIGGER trg_support_cube_guard_insert
BEFORE INSERT ON lab_combat_support.cube_definition_detail
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();
CREATE TRIGGER trg_support_collection_guard_insert
BEFORE INSERT ON lab_combat_support.collection_definition_detail
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();
CREATE TRIGGER trg_support_favorite_guard_insert
BEFORE INSERT ON lab_combat_support.favorite_definition_detail
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();
CREATE TRIGGER trg_support_console_guard_insert
BEFORE INSERT ON lab_combat_support.console_definition_detail
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();
CREATE TRIGGER trg_support_overload_guard_insert
BEFORE INSERT ON lab_combat_support.overload_option_definition_detail
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();
CREATE TRIGGER trg_support_contribution_guard_insert
BEFORE INSERT ON lab_combat_support.definition_stat_contribution
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();
CREATE TRIGGER trg_support_skill_coordinate_guard_insert
BEFORE INSERT ON lab_combat_support.definition_skill_coordinate
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();
CREATE TRIGGER trg_support_level_coordinate_guard_insert
BEFORE INSERT ON lab_combat_support.definition_level_coordinate
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();
CREATE TRIGGER trg_support_equipment_option_guard_insert
BEFORE INSERT ON lab_combat_support.equipment_option_slot
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();
CREATE TRIGGER trg_support_console_level_guard_insert
BEFORE INSERT ON lab_combat_support.console_legal_level
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();
CREATE TRIGGER trg_support_overload_band_guard_insert
BEFORE INSERT ON lab_combat_support.overload_legal_band
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();
CREATE TRIGGER trg_support_overload_value_guard_insert
BEFORE INSERT ON lab_combat_support.overload_legal_value
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();
CREATE TRIGGER trg_support_value_alias_guard_insert
BEFORE INSERT ON lab_private.overload_legal_value_source_alias
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_version_child_insert();

CREATE FUNCTION lab_combat_support.require_complete_version_children()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    detail_count BIGINT;
    matching_detail_count BIGINT;
BEGIN
    SELECT
        (SELECT count(*) FROM lab_combat_support.equipment_definition_detail
         WHERE definition_version_id = NEW.definition_version_id)
      + (SELECT count(*) FROM lab_combat_support.cube_definition_detail
         WHERE definition_version_id = NEW.definition_version_id)
      + (SELECT count(*) FROM lab_combat_support.collection_definition_detail
         WHERE definition_version_id = NEW.definition_version_id)
      + (SELECT count(*) FROM lab_combat_support.favorite_definition_detail
         WHERE definition_version_id = NEW.definition_version_id)
      + (SELECT count(*) FROM lab_combat_support.console_definition_detail
         WHERE definition_version_id = NEW.definition_version_id)
      + (SELECT count(*) FROM lab_combat_support.overload_option_definition_detail
         WHERE definition_version_id = NEW.definition_version_id)
    INTO detail_count;

    SELECT CASE NEW.definition_kind
        WHEN 'equipment' THEN (SELECT count(*) FROM lab_combat_support.equipment_definition_detail
            WHERE definition_version_id = NEW.definition_version_id)
        WHEN 'cube' THEN (SELECT count(*) FROM lab_combat_support.cube_definition_detail
            WHERE definition_version_id = NEW.definition_version_id)
        WHEN 'collection' THEN (SELECT count(*) FROM lab_combat_support.collection_definition_detail
            WHERE definition_version_id = NEW.definition_version_id)
        WHEN 'favorite' THEN (SELECT count(*) FROM lab_combat_support.favorite_definition_detail
            WHERE definition_version_id = NEW.definition_version_id)
        WHEN 'console' THEN (SELECT count(*) FROM lab_combat_support.console_definition_detail
            WHERE definition_version_id = NEW.definition_version_id)
        WHEN 'overload_option' THEN (SELECT count(*) FROM lab_combat_support.overload_option_definition_detail
            WHERE definition_version_id = NEW.definition_version_id)
        ELSE 0
    END INTO matching_detail_count;

    IF detail_count <> 1 OR matching_detail_count <> 1
       OR NEW.stat_contribution_count <> (SELECT count(*) FROM lab_combat_support.definition_stat_contribution
           WHERE definition_version_id = NEW.definition_version_id)
       OR NEW.skill_coordinate_count <> (SELECT count(*) FROM lab_combat_support.definition_skill_coordinate
           WHERE definition_version_id = NEW.definition_version_id)
       OR NEW.level_coordinate_count <> (SELECT count(*) FROM lab_combat_support.definition_level_coordinate
           WHERE definition_version_id = NEW.definition_version_id)
       OR NEW.equipment_option_slot_count <> (SELECT count(*) FROM lab_combat_support.equipment_option_slot
           WHERE definition_version_id = NEW.definition_version_id)
       OR NEW.legal_level_count <> (SELECT count(*) FROM lab_combat_support.console_legal_level
           WHERE definition_version_id = NEW.definition_version_id)
       OR NEW.overload_legal_band_count <> (SELECT count(*) FROM lab_combat_support.overload_legal_band
           WHERE definition_version_id = NEW.definition_version_id)
       OR NEW.overload_legal_value_count <> (SELECT count(*) FROM lab_combat_support.overload_legal_value
           WHERE definition_version_id = NEW.definition_version_id)
       OR NEW.overload_legal_value_count <> (SELECT count(*) FROM lab_private.overload_legal_value_source_alias
           WHERE definition_version_id = NEW.definition_version_id) THEN
        RAISE EXCEPTION 'combat_support_version_children_incomplete';
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_support_version_children_complete
AFTER INSERT ON lab_combat_support.definition_version
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.require_complete_version_children();

CREATE FUNCTION lab_combat_support.guard_catalog_member_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_count INTEGER;
    current_count BIGINT;
BEGIN
    SELECT member_count INTO expected_count
    FROM lab_combat_support.catalog_snapshot
    WHERE catalog_snapshot_id = NEW.catalog_snapshot_id
    FOR UPDATE;

    SELECT count(*) INTO current_count
    FROM lab_combat_support.catalog_snapshot_member
    WHERE catalog_snapshot_id = NEW.catalog_snapshot_id;

    IF expected_count IS NULL OR current_count >= expected_count THEN
        RAISE EXCEPTION 'immutable_combat_support_row';
    END IF;

    PERFORM 1
    FROM lab_combat_support.definition_version
    WHERE definition_version_id = NEW.definition_version_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'combat_support_version_missing';
    END IF;

    PERFORM 1
    FROM lab_combat_support.definition_entity
    WHERE definition_entity_id = NEW.definition_entity_id
    FOR UPDATE;

    IF NOT FOUND OR 1 <> (
        SELECT count(*)
        FROM lab_private.combat_support_source_alias
        WHERE definition_entity_id = NEW.definition_entity_id
    ) THEN
        RAISE EXCEPTION 'combat_support_entity_alias_incomplete';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM lab_combat_support.definition_version AS version
        WHERE version.definition_version_id = NEW.definition_version_id
          AND (
              version.stat_contribution_count <> (SELECT count(*)
                  FROM lab_combat_support.definition_stat_contribution
                  WHERE definition_version_id = NEW.definition_version_id)
              OR version.skill_coordinate_count <> (SELECT count(*)
                  FROM lab_combat_support.definition_skill_coordinate
                  WHERE definition_version_id = NEW.definition_version_id)
              OR version.level_coordinate_count <> (SELECT count(*)
                  FROM lab_combat_support.definition_level_coordinate
                  WHERE definition_version_id = NEW.definition_version_id)
              OR version.equipment_option_slot_count <> (SELECT count(*)
                  FROM lab_combat_support.equipment_option_slot
                  WHERE definition_version_id = NEW.definition_version_id)
              OR version.legal_level_count <> (SELECT count(*)
                  FROM lab_combat_support.console_legal_level
                  WHERE definition_version_id = NEW.definition_version_id)
              OR version.overload_legal_band_count <> (SELECT count(*)
                  FROM lab_combat_support.overload_legal_band
                  WHERE definition_version_id = NEW.definition_version_id)
              OR version.overload_legal_value_count <> (SELECT count(*)
                  FROM lab_combat_support.overload_legal_value
                  WHERE definition_version_id = NEW.definition_version_id)
              OR version.overload_legal_value_count <> (SELECT count(*)
                  FROM lab_private.overload_legal_value_source_alias
                  WHERE definition_version_id = NEW.definition_version_id)
          )
    ) THEN
        RAISE EXCEPTION 'combat_support_version_children_incomplete';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_support_member_guard_insert
BEFORE INSERT ON lab_combat_support.catalog_snapshot_member
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.guard_catalog_member_insert();

CREATE FUNCTION lab_combat_support.require_complete_catalog_membership()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.member_count <> (
        SELECT count(*)
        FROM lab_combat_support.catalog_snapshot_member
        WHERE catalog_snapshot_id = NEW.catalog_snapshot_id
    ) THEN
        RAISE EXCEPTION 'combat_support_catalog_membership_incomplete';
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_support_catalog_membership_complete
AFTER INSERT ON lab_combat_support.catalog_snapshot
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.require_complete_catalog_membership();

CREATE FUNCTION lab_combat_support.require_catalog_import_projection()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_catalog_id BIGINT;
    projected_catalog_id BIGINT;
BEGIN
    SELECT catalog_snapshot_id INTO expected_catalog_id
    FROM lab_combat_support.catalog_snapshot
    WHERE published_by_import_run_id = NEW.import_run_id
       OR published_by_import_run_id = NEW.reused_from_import_run_id
    ORDER BY CASE
        WHEN published_by_import_run_id = NEW.import_run_id THEN 0
        ELSE 1
    END
    LIMIT 1;

    IF expected_catalog_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT catalog_snapshot_id INTO projected_catalog_id
    FROM lab_combat_support.catalog_import_projection
    WHERE import_run_id = NEW.import_run_id;

    IF projected_catalog_id IS DISTINCT FROM expected_catalog_id THEN
        RAISE EXCEPTION 'combat_support_catalog_projection_incomplete';
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_support_import_projection_complete
AFTER INSERT ON lab_import.import_run
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_combat_support.require_catalog_import_projection();
