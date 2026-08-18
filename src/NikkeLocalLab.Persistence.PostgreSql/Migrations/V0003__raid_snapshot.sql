CREATE SCHEMA lab_raid;

CREATE TABLE lab_raid.challenge_encounter_entity (
    challenge_encounter_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    challenge_encounter_uid UUID NOT NULL UNIQUE CHECK (
        challenge_encounter_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    season_number INTEGER NOT NULL UNIQUE CHECK (season_number > 0),
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (challenge_encounter_id, season_number)
);

CREATE TABLE lab_raid.boss_variant_entity (
    boss_variant_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    boss_variant_uid UUID NOT NULL UNIQUE CHECK (
        boss_variant_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    challenge_encounter_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_raid.challenge_encounter_entity(challenge_encounter_id) ON DELETE RESTRICT,
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (boss_variant_id, challenge_encounter_id)
);

CREATE TABLE lab_raid.compatibility_map (
    compatibility_map_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    compatibility_map_uid UUID NOT NULL UNIQUE CHECK (
        compatibility_map_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    dataset_snapshot_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_import.dataset_snapshot(dataset_snapshot_id) ON DELETE RESTRICT,
    map_contract_sha256 BYTEA NOT NULL CHECK (octet_length(map_contract_sha256) = 32),
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (compatibility_map_id, dataset_snapshot_id)
);

CREATE TABLE lab_raid.client_runtime_build (
    client_runtime_build_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_runtime_build_uid UUID NOT NULL UNIQUE CHECK (
        client_runtime_build_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    source_artifact_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_import.source_artifact(source_artifact_id) ON DELETE RESTRICT,
    local_build_label TEXT NOT NULL UNIQUE CHECK (
        local_build_label ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    created_at_utc TIMESTAMPTZ NOT NULL
);

CREATE TABLE lab_raid.raid_catalog_snapshot (
    raid_catalog_snapshot_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raid_catalog_snapshot_uid UUID NOT NULL UNIQUE CHECK (
        raid_catalog_snapshot_uid <> '00000000-0000-0000-0000-000000000000'::uuid
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

CREATE TABLE lab_raid.raid_catalog_import_projection (
    import_run_id BIGINT PRIMARY KEY
        REFERENCES lab_import.import_run(import_run_id) ON DELETE RESTRICT,
    raid_catalog_snapshot_id BIGINT NOT NULL
        REFERENCES lab_raid.raid_catalog_snapshot(raid_catalog_snapshot_id) ON DELETE RESTRICT,
    diagnostic_count INTEGER NOT NULL CHECK (diagnostic_count >= 0),
    created_at_utc TIMESTAMPTZ NOT NULL
);

CREATE TABLE lab_raid.raid_snapshot (
    raid_snapshot_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raid_snapshot_uid UUID NOT NULL UNIQUE CHECK (
        raid_snapshot_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    dataset_snapshot_id BIGINT NOT NULL
        REFERENCES lab_import.dataset_snapshot(dataset_snapshot_id) ON DELETE RESTRICT,
    challenge_encounter_id BIGINT NOT NULL,
    boss_variant_id BIGINT NOT NULL,
    compatibility_map_id BIGINT NOT NULL,
    season_number INTEGER NOT NULL CHECK (season_number > 0),
    schema_version SMALLINT NOT NULL CHECK (schema_version = 2),
    mode TEXT NOT NULL CHECK (mode = 'challenge'),
    difficulty_type SMALLINT NOT NULL CHECK (difficulty_type = 2),
    wave_order SMALLINT NOT NULL CHECK (wave_order = 8),
    admission_policy_id TEXT NOT NULL CHECK (
        admission_policy_id = 'challenge-boss-support/v1'
    ),
    admission_rule TEXT NOT NULL CHECK (
        admission_rule IN ('electric_weak_to_iron', 'season_40_explicit')
    ),
    boss_element TEXT NOT NULL CHECK (
        boss_element IN ('fire', 'water', 'wind', 'electric', 'iron')
    ),
    weakness_code TEXT NOT NULL CHECK (
        weakness_code IN ('fire', 'water', 'wind', 'electric', 'iron')
    ),
    admission_status TEXT NOT NULL CHECK (admission_status = 'supported'),
    static_data_source_artifact_id BIGINT NOT NULL
        REFERENCES lab_import.source_artifact(source_artifact_id) ON DELETE RESTRICT,
    behavior_source_artifact_id BIGINT
        REFERENCES lab_import.source_artifact(source_artifact_id) ON DELETE RESTRICT,
    asset_bundle_set_sha256 BYTEA CHECK (
        asset_bundle_set_sha256 IS NULL OR octet_length(asset_bundle_set_sha256) = 32
    ),
    client_runtime_build_id BIGINT
        REFERENCES lab_raid.client_runtime_build(client_runtime_build_id) ON DELETE RESTRICT,
    compatibility_tier TEXT NOT NULL CHECK (
        compatibility_tier IN (
            'static_exact', 'behavior_exact',
            'asset_exact_runtime_current', 'historical_runtime_exact'
        )
    ),
    runtime_relation TEXT NOT NULL CHECK (
        runtime_relation IN (
            'not_evaluated', 'current_runtime_match', 'historical_runtime_match'
        )
    ),
    readiness_status TEXT NOT NULL CHECK (readiness_status = 'ready'),
    content_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(content_sha256) = 32),
    created_at_utc TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (challenge_encounter_id, season_number)
        REFERENCES lab_raid.challenge_encounter_entity(
            challenge_encounter_id,
            season_number
        ) ON DELETE RESTRICT,
    FOREIGN KEY (boss_variant_id, challenge_encounter_id)
        REFERENCES lab_raid.boss_variant_entity(
            boss_variant_id,
            challenge_encounter_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (compatibility_map_id, dataset_snapshot_id)
        REFERENCES lab_raid.compatibility_map(
            compatibility_map_id,
            dataset_snapshot_id
        ) ON DELETE RESTRICT,
    CHECK (
        (season_number = 40 AND admission_rule = 'season_40_explicit')
        OR (
            season_number NOT IN (14, 39, 40)
            AND admission_rule = 'electric_weak_to_iron'
            AND boss_element = 'electric'
            AND weakness_code = 'iron'
        )
    ),
    CHECK (
        runtime_relation = 'not_evaluated' OR client_runtime_build_id IS NOT NULL
    ),
    CHECK (
        compatibility_tier = 'static_exact'
        OR (
            behavior_source_artifact_id IS NOT NULL
            AND asset_bundle_set_sha256 IS NOT NULL
        )
    ),
    CHECK (
        compatibility_tier <> 'asset_exact_runtime_current'
        OR (
            runtime_relation = 'current_runtime_match'
            AND client_runtime_build_id IS NOT NULL
        )
    ),
    CHECK (
        compatibility_tier <> 'historical_runtime_exact'
        OR (
            runtime_relation = 'historical_runtime_match'
            AND client_runtime_build_id IS NOT NULL
        )
    )
);

CREATE TABLE lab_raid.raid_catalog_snapshot_member (
    raid_catalog_snapshot_id BIGINT NOT NULL
        REFERENCES lab_raid.raid_catalog_snapshot(raid_catalog_snapshot_id) ON DELETE RESTRICT,
    raid_snapshot_id BIGINT NOT NULL
        REFERENCES lab_raid.raid_snapshot(raid_snapshot_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    PRIMARY KEY (raid_catalog_snapshot_id, raid_snapshot_id),
    UNIQUE (raid_catalog_snapshot_id, ordinal)
);

CREATE TABLE lab_raid.raid_snapshot_part (
    raid_snapshot_id BIGINT NOT NULL
        REFERENCES lab_raid.raid_snapshot(raid_snapshot_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    part_uid UUID NOT NULL UNIQUE CHECK (
        part_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    type_code TEXT NOT NULL CHECK (type_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    damage_hp_ratio INTEGER NOT NULL CHECK (damage_hp_ratio >= 0),
    hp_ratio INTEGER NOT NULL CHECK (hp_ratio >= 0),
    defence_ratio INTEGER NOT NULL CHECK (defence_ratio >= 0),
    energy_resist_ratio INTEGER NOT NULL CHECK (energy_resist_ratio >= 0),
    metal_resist_ratio INTEGER NOT NULL CHECK (metal_resist_ratio >= 0),
    bio_resist_ratio INTEGER NOT NULL CHECK (bio_resist_ratio >= 0),
    attack_ratio INTEGER NOT NULL CHECK (attack_ratio >= 0),
    is_main_part BOOLEAN NOT NULL,
    is_damageable BOOLEAN NOT NULL,
    is_hp_visible BOOLEAN NOT NULL,
    linked_part_ordinal INTEGER CHECK (linked_part_ordinal IS NULL OR linked_part_ordinal >= 0),
    PRIMARY KEY (raid_snapshot_id, ordinal),
    FOREIGN KEY (raid_snapshot_id, linked_part_ordinal)
        REFERENCES lab_raid.raid_snapshot_part(raid_snapshot_id, ordinal)
        ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
    CHECK (linked_part_ordinal IS NULL OR linked_part_ordinal <> ordinal)
);

CREATE TABLE lab_raid.raid_snapshot_skill (
    raid_snapshot_id BIGINT NOT NULL
        REFERENCES lab_raid.raid_snapshot(raid_snapshot_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    skill_uid UUID NOT NULL UNIQUE CHECK (
        skill_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    role_code TEXT NOT NULL CHECK (role_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    PRIMARY KEY (raid_snapshot_id, ordinal)
);

CREATE TABLE lab_raid.raid_snapshot_selected_bundle (
    raid_snapshot_id BIGINT NOT NULL
        REFERENCES lab_raid.raid_snapshot(raid_snapshot_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    source_artifact_id BIGINT NOT NULL
        REFERENCES lab_import.source_artifact(source_artifact_id) ON DELETE RESTRICT,
    PRIMARY KEY (raid_snapshot_id, ordinal),
    UNIQUE (raid_snapshot_id, source_artifact_id)
);

CREATE TABLE lab_raid.raid_snapshot_selected_bundle_role (
    raid_snapshot_id BIGINT NOT NULL,
    bundle_ordinal INTEGER NOT NULL,
    role_code TEXT NOT NULL CHECK (
        role_code IN ('stage', 'model', 'behavior', 'timeline', 'animation', 'audio', 'other')
    ),
    PRIMARY KEY (raid_snapshot_id, bundle_ordinal, role_code),
    FOREIGN KEY (raid_snapshot_id, bundle_ordinal)
        REFERENCES lab_raid.raid_snapshot_selected_bundle(raid_snapshot_id, ordinal)
        ON DELETE RESTRICT
);

CREATE TABLE lab_raid.raid_snapshot_timeline (
    raid_snapshot_id BIGINT NOT NULL
        REFERENCES lab_raid.raid_snapshot(raid_snapshot_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    source_artifact_id BIGINT NOT NULL
        REFERENCES lab_import.source_artifact(source_artifact_id) ON DELETE RESTRICT,
    PRIMARY KEY (raid_snapshot_id, ordinal),
    UNIQUE (raid_snapshot_id, source_artifact_id)
);

CREATE TABLE lab_raid.raid_snapshot_timeline_clock_basis (
    raid_snapshot_id BIGINT NOT NULL,
    timeline_ordinal INTEGER NOT NULL,
    clock_basis TEXT NOT NULL CHECK (
        clock_basis IN ('behavior_tick', 'render_frame', 'fixed_update', 'wall_clock')
    ),
    PRIMARY KEY (raid_snapshot_id, timeline_ordinal, clock_basis),
    FOREIGN KEY (raid_snapshot_id, timeline_ordinal)
        REFERENCES lab_raid.raid_snapshot_timeline(raid_snapshot_id, ordinal)
        ON DELETE RESTRICT
);

CREATE TABLE lab_raid.raid_snapshot_timing_clock (
    raid_snapshot_id BIGINT NOT NULL
        REFERENCES lab_raid.raid_snapshot(raid_snapshot_id) ON DELETE RESTRICT,
    clock_basis TEXT NOT NULL CHECK (
        clock_basis IN ('behavior_tick', 'render_frame', 'fixed_update', 'wall_clock')
    ),
    resolution TEXT NOT NULL CHECK (
        resolution IN ('unresolved', 'static_analysis', 'runtime_trace')
    ),
    reason_code TEXT CHECK (reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    PRIMARY KEY (raid_snapshot_id, clock_basis),
    CHECK (
        (resolution = 'unresolved' AND reason_code IS NOT NULL)
        OR (resolution <> 'unresolved' AND reason_code IS NULL)
    )
);

CREATE TABLE lab_raid.raid_snapshot_timing_clock_evidence (
    raid_snapshot_id BIGINT NOT NULL,
    clock_basis TEXT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    source_artifact_id BIGINT NOT NULL
        REFERENCES lab_import.source_artifact(source_artifact_id) ON DELETE RESTRICT,
    PRIMARY KEY (raid_snapshot_id, clock_basis, ordinal),
    UNIQUE (raid_snapshot_id, clock_basis, source_artifact_id),
    FOREIGN KEY (raid_snapshot_id, clock_basis)
        REFERENCES lab_raid.raid_snapshot_timing_clock(raid_snapshot_id, clock_basis)
        ON DELETE RESTRICT
);

CREATE TABLE lab_raid.raid_snapshot_scheduler (
    raid_snapshot_id BIGINT PRIMARY KEY
        REFERENCES lab_raid.raid_snapshot(raid_snapshot_id) ON DELETE RESTRICT,
    resolution TEXT NOT NULL CHECK (
        resolution IN ('unresolved', 'static_analysis', 'runtime_trace')
    ),
    reason_code TEXT CHECK (reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    CHECK (
        (resolution = 'unresolved' AND reason_code IS NOT NULL)
        OR (resolution <> 'unresolved' AND reason_code IS NULL)
    )
);

CREATE TABLE lab_raid.raid_snapshot_scheduler_clock_basis (
    raid_snapshot_id BIGINT NOT NULL
        REFERENCES lab_raid.raid_snapshot_scheduler(raid_snapshot_id) ON DELETE RESTRICT,
    clock_basis TEXT NOT NULL CHECK (
        clock_basis IN ('behavior_tick', 'render_frame', 'fixed_update', 'wall_clock')
    ),
    PRIMARY KEY (raid_snapshot_id, clock_basis),
    FOREIGN KEY (raid_snapshot_id, clock_basis)
        REFERENCES lab_raid.raid_snapshot_timing_clock(raid_snapshot_id, clock_basis)
        ON DELETE RESTRICT
);

CREATE TABLE lab_raid.raid_snapshot_scheduler_evidence (
    raid_snapshot_id BIGINT NOT NULL
        REFERENCES lab_raid.raid_snapshot_scheduler(raid_snapshot_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    source_artifact_id BIGINT NOT NULL
        REFERENCES lab_import.source_artifact(source_artifact_id) ON DELETE RESTRICT,
    PRIMARY KEY (raid_snapshot_id, ordinal),
    UNIQUE (raid_snapshot_id, source_artifact_id)
);

CREATE TABLE lab_raid.raid_snapshot_compatibility_warning (
    raid_snapshot_id BIGINT NOT NULL
        REFERENCES lab_raid.raid_snapshot(raid_snapshot_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    warning_code TEXT NOT NULL CHECK (warning_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    PRIMARY KEY (raid_snapshot_id, ordinal),
    UNIQUE (raid_snapshot_id, warning_code)
);

CREATE TABLE lab_raid.raid_snapshot_readiness_warning (
    raid_snapshot_id BIGINT NOT NULL
        REFERENCES lab_raid.raid_snapshot(raid_snapshot_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    warning_code TEXT NOT NULL CHECK (warning_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    PRIMARY KEY (raid_snapshot_id, ordinal),
    UNIQUE (raid_snapshot_id, warning_code)
);

CREATE TABLE lab_raid.raid_catalog_import_diagnostic (
    raid_catalog_import_diagnostic_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raid_catalog_import_diagnostic_uid UUID NOT NULL UNIQUE CHECK (
        raid_catalog_import_diagnostic_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    import_run_id BIGINT NOT NULL
        REFERENCES lab_import.import_run(import_run_id) ON DELETE RESTRICT,
    sequence_number INTEGER NOT NULL CHECK (sequence_number >= 0),
    season_number INTEGER CHECK (season_number IS NULL OR season_number > 0),
    diagnostic_code TEXT NOT NULL CHECK (
        diagnostic_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    occurrence_count INTEGER NOT NULL CHECK (occurrence_count >= 1),
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (import_run_id, sequence_number)
);

CREATE INDEX ix_boss_variant_encounter
    ON lab_raid.boss_variant_entity(challenge_encounter_id);
CREATE INDEX ix_compatibility_map_dataset
    ON lab_raid.compatibility_map(dataset_snapshot_id);
CREATE INDEX ix_client_runtime_source_artifact
    ON lab_raid.client_runtime_build(source_artifact_id);
CREATE INDEX ix_raid_catalog_dataset
    ON lab_raid.raid_catalog_snapshot(dataset_snapshot_id);
CREATE INDEX ix_raid_catalog_import_projection_catalog
    ON lab_raid.raid_catalog_import_projection(raid_catalog_snapshot_id);
CREATE INDEX ix_raid_snapshot_dataset
    ON lab_raid.raid_snapshot(dataset_snapshot_id);
CREATE INDEX ix_raid_snapshot_season
    ON lab_raid.raid_snapshot(season_number);
CREATE INDEX ix_raid_snapshot_static_artifact
    ON lab_raid.raid_snapshot(static_data_source_artifact_id);
CREATE INDEX ix_raid_snapshot_behavior_artifact
    ON lab_raid.raid_snapshot(behavior_source_artifact_id);
CREATE INDEX ix_raid_catalog_member_snapshot
    ON lab_raid.raid_catalog_snapshot_member(raid_snapshot_id);
CREATE INDEX ix_raid_bundle_source_artifact
    ON lab_raid.raid_snapshot_selected_bundle(source_artifact_id);
CREATE INDEX ix_raid_timeline_source_artifact
    ON lab_raid.raid_snapshot_timeline(source_artifact_id);
CREATE INDEX ix_raid_clock_evidence_source_artifact
    ON lab_raid.raid_snapshot_timing_clock_evidence(source_artifact_id);
CREATE INDEX ix_raid_scheduler_evidence_source_artifact
    ON lab_raid.raid_snapshot_scheduler_evidence(source_artifact_id);
CREATE INDEX ix_raid_diagnostic_import_run
    ON lab_raid.raid_catalog_import_diagnostic(import_run_id);

CREATE FUNCTION lab_raid.reject_immutable_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'immutable_raid_row';
END;
$$;

CREATE TRIGGER trg_challenge_encounter_immutable
BEFORE UPDATE OR DELETE ON lab_raid.challenge_encounter_entity
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_boss_variant_immutable
BEFORE UPDATE OR DELETE ON lab_raid.boss_variant_entity
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_compatibility_map_immutable
BEFORE UPDATE OR DELETE ON lab_raid.compatibility_map
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_client_runtime_build_immutable
BEFORE UPDATE OR DELETE ON lab_raid.client_runtime_build
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_catalog_snapshot_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_catalog_snapshot
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_catalog_import_projection_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_catalog_import_projection
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_snapshot_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_catalog_member_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_catalog_snapshot_member
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_snapshot_part_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot_part
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_snapshot_skill_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot_skill
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_bundle_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot_selected_bundle
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_bundle_role_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot_selected_bundle_role
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_timeline_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot_timeline
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_timeline_clock_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot_timeline_clock_basis
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_timing_clock_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot_timing_clock
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_timing_clock_evidence_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot_timing_clock_evidence
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_scheduler_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot_scheduler
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_scheduler_clock_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot_scheduler_clock_basis
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_scheduler_evidence_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot_scheduler_evidence
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_compatibility_warning_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot_compatibility_warning
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_readiness_warning_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_snapshot_readiness_warning
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();
CREATE TRIGGER trg_raid_import_diagnostic_immutable
BEFORE UPDATE OR DELETE ON lab_raid.raid_catalog_import_diagnostic
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_immutable_mutation();

CREATE FUNCTION lab_raid.reject_published_snapshot_child_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1
    FROM lab_raid.raid_snapshot
    WHERE raid_snapshot_id = NEW.raid_snapshot_id
    FOR UPDATE;

    IF EXISTS (
        SELECT 1
        FROM lab_raid.raid_catalog_snapshot_member
        WHERE raid_snapshot_id = NEW.raid_snapshot_id
    ) THEN
        RAISE EXCEPTION 'immutable_raid_row';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_raid_part_reject_published_insert
BEFORE INSERT ON lab_raid.raid_snapshot_part
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_published_snapshot_child_insert();
CREATE TRIGGER trg_raid_skill_reject_published_insert
BEFORE INSERT ON lab_raid.raid_snapshot_skill
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_published_snapshot_child_insert();
CREATE TRIGGER trg_raid_bundle_reject_published_insert
BEFORE INSERT ON lab_raid.raid_snapshot_selected_bundle
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_published_snapshot_child_insert();
CREATE TRIGGER trg_raid_bundle_role_reject_published_insert
BEFORE INSERT ON lab_raid.raid_snapshot_selected_bundle_role
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_published_snapshot_child_insert();
CREATE TRIGGER trg_raid_timeline_reject_published_insert
BEFORE INSERT ON lab_raid.raid_snapshot_timeline
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_published_snapshot_child_insert();
CREATE TRIGGER trg_raid_timeline_clock_reject_published_insert
BEFORE INSERT ON lab_raid.raid_snapshot_timeline_clock_basis
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_published_snapshot_child_insert();
CREATE TRIGGER trg_raid_timing_clock_reject_published_insert
BEFORE INSERT ON lab_raid.raid_snapshot_timing_clock
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_published_snapshot_child_insert();
CREATE TRIGGER trg_raid_timing_clock_evidence_reject_published_insert
BEFORE INSERT ON lab_raid.raid_snapshot_timing_clock_evidence
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_published_snapshot_child_insert();
CREATE TRIGGER trg_raid_scheduler_reject_published_insert
BEFORE INSERT ON lab_raid.raid_snapshot_scheduler
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_published_snapshot_child_insert();
CREATE TRIGGER trg_raid_scheduler_clock_reject_published_insert
BEFORE INSERT ON lab_raid.raid_snapshot_scheduler_clock_basis
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_published_snapshot_child_insert();
CREATE TRIGGER trg_raid_scheduler_evidence_reject_published_insert
BEFORE INSERT ON lab_raid.raid_snapshot_scheduler_evidence
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_published_snapshot_child_insert();
CREATE TRIGGER trg_raid_compatibility_warning_reject_published_insert
BEFORE INSERT ON lab_raid.raid_snapshot_compatibility_warning
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_published_snapshot_child_insert();
CREATE TRIGGER trg_raid_readiness_warning_reject_published_insert
BEFORE INSERT ON lab_raid.raid_snapshot_readiness_warning
FOR EACH ROW EXECUTE FUNCTION lab_raid.reject_published_snapshot_child_insert();

CREATE FUNCTION lab_raid.guard_catalog_member_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_count INTEGER;
    current_count BIGINT;
BEGIN
    SELECT member_count
    INTO expected_count
    FROM lab_raid.raid_catalog_snapshot
    WHERE raid_catalog_snapshot_id = NEW.raid_catalog_snapshot_id
    FOR UPDATE;

    SELECT count(*)
    INTO current_count
    FROM lab_raid.raid_catalog_snapshot_member
    WHERE raid_catalog_snapshot_id = NEW.raid_catalog_snapshot_id;

    IF expected_count IS NOT NULL AND current_count >= expected_count THEN
        RAISE EXCEPTION 'immutable_raid_row';
    END IF;

    PERFORM 1
    FROM lab_raid.raid_snapshot
    WHERE raid_snapshot_id = NEW.raid_snapshot_id
    FOR UPDATE;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_raid_catalog_member_guard_insert
BEFORE INSERT ON lab_raid.raid_catalog_snapshot_member
FOR EACH ROW EXECUTE FUNCTION lab_raid.guard_catalog_member_insert();

CREATE FUNCTION lab_raid.require_complete_catalog_membership()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.member_count <> (
        SELECT count(*)
        FROM lab_raid.raid_catalog_snapshot_member
        WHERE raid_catalog_snapshot_id = NEW.raid_catalog_snapshot_id
    ) THEN
        RAISE EXCEPTION 'raid_catalog_membership_incomplete';
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_raid_catalog_membership_complete
AFTER INSERT ON lab_raid.raid_catalog_snapshot
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_raid.require_complete_catalog_membership();

CREATE FUNCTION lab_raid.guard_catalog_diagnostic_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_count INTEGER;
    current_count BIGINT;
BEGIN
    SELECT diagnostic_count
    INTO expected_count
    FROM lab_raid.raid_catalog_import_projection
    WHERE import_run_id = NEW.import_run_id
    FOR UPDATE;

    IF expected_count IS NULL THEN
        RAISE EXCEPTION 'raid_catalog_import_projection_missing';
    END IF;

    SELECT count(*)
    INTO current_count
    FROM lab_raid.raid_catalog_import_diagnostic
    WHERE import_run_id = NEW.import_run_id;

    IF current_count >= expected_count THEN
        RAISE EXCEPTION 'immutable_raid_row';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_raid_import_diagnostic_guard_insert
BEFORE INSERT ON lab_raid.raid_catalog_import_diagnostic
FOR EACH ROW EXECUTE FUNCTION lab_raid.guard_catalog_diagnostic_insert();

CREATE FUNCTION lab_raid.require_complete_catalog_diagnostics()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.diagnostic_count <> (
        SELECT count(*)
        FROM lab_raid.raid_catalog_import_diagnostic
        WHERE import_run_id = NEW.import_run_id
    ) THEN
        RAISE EXCEPTION 'raid_catalog_diagnostics_incomplete';
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_raid_catalog_diagnostics_complete
AFTER INSERT ON lab_raid.raid_catalog_import_projection
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_raid.require_complete_catalog_diagnostics();

CREATE FUNCTION lab_raid.require_catalog_import_projection()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_catalog_id BIGINT;
    projected_catalog_id BIGINT;
BEGIN
    SELECT raid_catalog_snapshot_id
    INTO expected_catalog_id
    FROM lab_raid.raid_catalog_snapshot
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

    SELECT raid_catalog_snapshot_id
    INTO projected_catalog_id
    FROM lab_raid.raid_catalog_import_projection
    WHERE import_run_id = NEW.import_run_id;

    IF projected_catalog_id IS DISTINCT FROM expected_catalog_id THEN
        RAISE EXCEPTION 'raid_catalog_import_projection_incomplete';
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_raid_import_projection_complete
AFTER INSERT ON lab_import.import_run
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_raid.require_catalog_import_projection();
