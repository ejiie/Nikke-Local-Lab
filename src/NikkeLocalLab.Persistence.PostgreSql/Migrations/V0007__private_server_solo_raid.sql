CREATE SCHEMA lab_private_server;

CREATE FUNCTION lab_private_server.reject_immutable_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'immutable_private_server_row';
END;
$$;

-- A NIKKE raid day changes at 05:00 Asia/Seoul.  This function is deliberately
-- independent of the database/session TimeZone setting.
CREATE FUNCTION lab_private_server.raid_day_key(observed_at_utc TIMESTAMPTZ)
RETURNS DATE
LANGUAGE SQL
IMMUTABLE
STRICT
AS $$
    SELECT ((observed_at_utc AT TIME ZONE 'Asia/Seoul') - INTERVAL '5 hours')::date;
$$;

CREATE TABLE lab_private_server.challenge_operational_policy (
    challenge_operational_policy_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    challenge_operational_policy_uid UUID NOT NULL UNIQUE CHECK (
        challenge_operational_policy_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    policy_id TEXT NOT NULL UNIQUE CHECK (
        policy_id ~ '^challenge-operational-policy/[a-z][a-z0-9._-]{0,47}/v[1-9][0-9]*$'
        AND char_length(policy_id) <= 96
    ),
    resolution_status TEXT NOT NULL CHECK (resolution_status IN ('configured', 'unresolved')),
    daily_entry_limit INTEGER CHECK (daily_entry_limit BETWEEN 1 AND 1000000),
    daily_entry_limit_unresolved_reason_code TEXT CHECK (
        daily_entry_limit_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    entry_consumption_point TEXT CHECK (
        entry_consumption_point IN ('run_opened', 'first_team_entered', 'run_closed')
    ),
    entry_consumption_point_unresolved_reason_code TEXT CHECK (
        entry_consumption_point_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    active_run_at_reset TEXT CHECK (
        active_run_at_reset IN ('pin_opening_raid_day', 'reject_post_boundary_progress')
    ),
    active_run_at_reset_unresolved_reason_code TEXT CHECK (
        active_run_at_reset_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    counter_scope TEXT CHECK (counter_scope IN ('per_season', 'shared_across_directory')),
    counter_scope_unresolved_reason_code TEXT CHECK (
        counter_scope_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    mock_battle_capability TEXT CHECK (
        mock_battle_capability IN ('unsupported', 'lab_owned_only')
    ),
    mock_battle_unresolved_reason_code TEXT CHECK (
        mock_battle_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    local_ranking_capability TEXT CHECK (
        local_ranking_capability IN ('unsupported', 'local_records_only')
    ),
    local_ranking_unresolved_reason_code TEXT CHECK (
        local_ranking_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    content_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(content_sha256) = 32),
    published_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (challenge_operational_policy_id, content_sha256),
    CHECK (
        (resolution_status = 'unresolved') =
        (policy_id = 'challenge-operational-policy/unresolved/v1')
    ),
    CHECK (
        (resolution_status = 'configured'
            AND daily_entry_limit IS NOT NULL
            AND daily_entry_limit_unresolved_reason_code IS NULL
            AND entry_consumption_point IS NOT NULL
            AND entry_consumption_point_unresolved_reason_code IS NULL
            AND active_run_at_reset IS NOT NULL
            AND active_run_at_reset_unresolved_reason_code IS NULL
            AND counter_scope IS NOT NULL
            AND counter_scope_unresolved_reason_code IS NULL
            AND mock_battle_capability IS NOT NULL
            AND mock_battle_unresolved_reason_code IS NULL
            AND local_ranking_capability IS NOT NULL
            AND local_ranking_unresolved_reason_code IS NULL)
        OR (resolution_status = 'unresolved'
            AND daily_entry_limit IS NULL
            AND daily_entry_limit_unresolved_reason_code IS NOT NULL
            AND entry_consumption_point IS NULL
            AND entry_consumption_point_unresolved_reason_code IS NOT NULL
            AND active_run_at_reset IS NULL
            AND active_run_at_reset_unresolved_reason_code IS NOT NULL
            AND counter_scope IS NULL
            AND counter_scope_unresolved_reason_code IS NOT NULL
            AND mock_battle_capability IS NULL
            AND mock_battle_unresolved_reason_code IS NOT NULL
            AND local_ranking_capability IS NULL
            AND local_ranking_unresolved_reason_code IS NOT NULL)
    )
);

CREATE TABLE lab_private_server.challenge_policy_activation_revision (
    challenge_policy_activation_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    challenge_policy_activation_uid UUID NOT NULL CHECK (
        challenge_policy_activation_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    challenge_policy_activation_revision_uid UUID NOT NULL UNIQUE CHECK (
        challenge_policy_activation_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    revision_number INTEGER NOT NULL UNIQUE CHECK (revision_number >= 1),
    previous_activation_revision_id BIGINT UNIQUE,
    challenge_operational_policy_id BIGINT NOT NULL,
    policy_content_sha256 BYTEA NOT NULL CHECK (octet_length(policy_content_sha256) = 32),
    effective_raid_day_key DATE NOT NULL,
    content_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(content_sha256) = 32),
    scheduled_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (challenge_policy_activation_uid, revision_number),
    UNIQUE (
        challenge_policy_activation_revision_id,
        challenge_policy_activation_uid
    ),
    FOREIGN KEY (previous_activation_revision_id)
        REFERENCES lab_private_server.challenge_policy_activation_revision(
            challenge_policy_activation_revision_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (challenge_operational_policy_id, policy_content_sha256)
        REFERENCES lab_private_server.challenge_operational_policy(
            challenge_operational_policy_id,
            content_sha256
        ) ON DELETE RESTRICT,
    UNIQUE (challenge_policy_activation_revision_id, challenge_operational_policy_id),
    CHECK (
        (revision_number = 1 AND previous_activation_revision_id IS NULL)
        OR (revision_number > 1 AND previous_activation_revision_id IS NOT NULL)
    )
);

CREATE TABLE lab_private_server.challenge_policy_state (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    latest_scheduled_activation_revision_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_private_server.challenge_policy_activation_revision(
            challenge_policy_activation_revision_id
        ) DEFERRABLE INITIALLY DEFERRED,
    updated_at_utc TIMESTAMPTZ NOT NULL
);

ALTER TABLE lab_local_game.client_feature_manifest
    ADD CONSTRAINT uq_private_server_feature_manifest_content
    UNIQUE (client_feature_manifest_id, content_sha256),
    ADD CONSTRAINT uq_private_server_feature_manifest_contract
    UNIQUE (client_feature_manifest_id, content_sha256, contract_version);

CREATE TABLE lab_private_server.capability_manifest (
    capability_manifest_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    capability_manifest_uid UUID NOT NULL UNIQUE CHECK (
        capability_manifest_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    contract_version TEXT NOT NULL CHECK (
        contract_version = 'nll/private-server-capabilities/v1'
    ),
    client_feature_manifest_id BIGINT NOT NULL,
    client_feature_manifest_content_sha256 BYTEA NOT NULL CHECK (
        octet_length(client_feature_manifest_content_sha256) = 32
    ),
    client_feature_manifest_contract_version TEXT NOT NULL CHECK (
        client_feature_manifest_contract_version = 'nll/client-feature-manifest/v2'
    ),
    challenge_operational_policy_id BIGINT NOT NULL,
    policy_content_sha256 BYTEA NOT NULL CHECK (octet_length(policy_content_sha256) = 32),
    entry_count SMALLINT NOT NULL CHECK (entry_count = 12),
    content_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(content_sha256) = 32),
    published_at_utc TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (client_feature_manifest_id, client_feature_manifest_content_sha256)
        REFERENCES lab_local_game.client_feature_manifest(
            client_feature_manifest_id,
            content_sha256
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        client_feature_manifest_id,
        client_feature_manifest_content_sha256,
        client_feature_manifest_contract_version
    ) REFERENCES lab_local_game.client_feature_manifest(
        client_feature_manifest_id,
        content_sha256,
        contract_version
    ) ON DELETE RESTRICT,
    FOREIGN KEY (challenge_operational_policy_id, policy_content_sha256)
        REFERENCES lab_private_server.challenge_operational_policy(
            challenge_operational_policy_id,
            content_sha256
        ) ON DELETE RESTRICT,
    UNIQUE (capability_manifest_id, challenge_operational_policy_id),
    UNIQUE (capability_manifest_id, client_feature_manifest_id),
    UNIQUE (challenge_operational_policy_id, client_feature_manifest_id),
    UNIQUE (
        capability_manifest_id,
        content_sha256,
        challenge_operational_policy_id
    )
);

CREATE TABLE lab_private_server.capability_manifest_entry (
    capability_manifest_id BIGINT NOT NULL
        REFERENCES lab_private_server.capability_manifest(capability_manifest_id)
        ON DELETE RESTRICT,
    capability_code TEXT NOT NULL CHECK (
        capability_code ~ '^[a-z][a-z0-9._-]{0,95}$'
    ),
    status_code TEXT NOT NULL CHECK (status_code IN (
        'supported', 'unsupported', 'visible_no_op', 'blocked_by_gate', 'unresolved'
    )),
    reason_code TEXT CHECK (reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    PRIMARY KEY (capability_manifest_id, capability_code),
    CHECK (
        (status_code IN ('blocked_by_gate', 'unresolved') AND reason_code IS NOT NULL)
        OR (status_code NOT IN ('blocked_by_gate', 'unresolved') AND reason_code IS NULL)
    )
);

-- This is the local private-server/harness application identity.  It is not an
-- assertion that an original-client runtime build has been recovered.
CREATE TABLE lab_private_server.application_build (
    application_build_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_build_uid UUID NOT NULL UNIQUE CHECK (
        application_build_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    application_contract_id TEXT NOT NULL CHECK (
        application_contract_id ~ '^nll/private-server-application/[a-z][a-z0-9._-]{0,47}/v[1-9][0-9]*$'
        AND char_length(application_contract_id) <= 128
    ),
    application_build_sha256 BYTEA NOT NULL UNIQUE CHECK (
        octet_length(application_build_sha256) = 32
    ),
    content_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(content_sha256) = 32),
    published_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (application_build_id, application_contract_id),
    UNIQUE (application_build_id, application_build_sha256)
);

CREATE TABLE lab_private_server.application_build_selection_revision (
    application_build_selection_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_build_selection_revision_uid UUID NOT NULL UNIQUE CHECK (
        application_build_selection_revision_uid <>
            '00000000-0000-0000-0000-000000000000'::uuid
    ),
    revision_number INTEGER NOT NULL UNIQUE CHECK (revision_number >= 1),
    previous_application_build_selection_revision_id BIGINT UNIQUE,
    application_build_id BIGINT NOT NULL,
    application_build_sha256 BYTEA NOT NULL CHECK (
        octet_length(application_build_sha256) = 32
    ),
    content_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(content_sha256) = 32),
    selected_at_utc TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (previous_application_build_selection_revision_id)
        REFERENCES lab_private_server.application_build_selection_revision(
            application_build_selection_revision_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (application_build_id, application_build_sha256)
        REFERENCES lab_private_server.application_build(
            application_build_id,
            application_build_sha256
        ) ON DELETE RESTRICT,
    UNIQUE (
        application_build_selection_revision_id,
        application_build_id,
        application_build_sha256
    ),
    CHECK (
        (revision_number = 1 AND previous_application_build_selection_revision_id IS NULL)
        OR (revision_number > 1 AND previous_application_build_selection_revision_id IS NOT NULL)
    )
);

CREATE TABLE lab_private_server.application_build_state (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    current_application_build_selection_revision_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_private_server.application_build_selection_revision(
            application_build_selection_revision_id
        ) DEFERRABLE INITIALLY DEFERRED,
    updated_at_utc TIMESTAMPTZ NOT NULL
);

CREATE TABLE lab_private_server.raid_season_directory (
    raid_season_directory_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raid_season_directory_uid UUID NOT NULL UNIQUE CHECK (
        raid_season_directory_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    contract_version TEXT NOT NULL UNIQUE CHECK (
        contract_version = 'nll/raid-season-directory/v1'
    ),
    raid_catalog_snapshot_id BIGINT NOT NULL
        REFERENCES lab_raid.raid_catalog_snapshot(raid_catalog_snapshot_id)
        ON DELETE RESTRICT,
    member_count SMALLINT NOT NULL CHECK (member_count = 6),
    season_availability TEXT NOT NULL CHECK (season_availability = 'permanent'),
    season_ends_at_utc TIMESTAMPTZ CHECK (season_ends_at_utc IS NULL),
    normal_stages_implemented BOOLEAN NOT NULL CHECK (NOT normal_stages_implemented),
    normal_last_clear_level SMALLINT NOT NULL CHECK (normal_last_clear_level = 7),
    challenge_unlocked BOOLEAN NOT NULL CHECK (challenge_unlocked),
    normal_combat_capability TEXT NOT NULL CHECK (normal_combat_capability = 'unsupported'),
    quick_battle_capability TEXT NOT NULL CHECK (quick_battle_capability = 'unsupported'),
    content_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(content_sha256) = 32),
    published_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (raid_season_directory_id, raid_catalog_snapshot_id)
);

ALTER TABLE lab_raid.raid_snapshot
    ADD CONSTRAINT uq_private_server_raid_snapshot_season
    UNIQUE (raid_snapshot_id, season_number),
    ADD CONSTRAINT uq_private_server_raid_snapshot_content
    UNIQUE (raid_snapshot_id, content_sha256);

ALTER TABLE lab_private_server.raid_season_directory
    ADD CONSTRAINT uq_private_server_directory_content
    UNIQUE (raid_season_directory_id, content_sha256);

CREATE TABLE lab_private_server.raid_season_directory_member (
    raid_season_directory_id BIGINT NOT NULL,
    raid_catalog_snapshot_id BIGINT NOT NULL,
    ordinal SMALLINT NOT NULL CHECK (ordinal BETWEEN 1 AND 6),
    season_number INTEGER NOT NULL CHECK (
        (ordinal = 1 AND season_number = 7)
        OR (ordinal = 2 AND season_number = 13)
        OR (ordinal = 3 AND season_number = 26)
        OR (ordinal = 4 AND season_number = 29)
        OR (ordinal = 5 AND season_number = 34)
        OR (ordinal = 6 AND season_number = 40)
    ),
    raid_snapshot_id BIGINT NOT NULL,
    raid_snapshot_content_sha256 BYTEA NOT NULL CHECK (
        octet_length(raid_snapshot_content_sha256) = 32
    ),
    presentation_status TEXT NOT NULL CHECK (presentation_status = 'unresolved'),
    presentation_uid UUID CHECK (presentation_uid IS NULL),
    presentation_unresolved_reason_code TEXT NOT NULL CHECK (
        presentation_unresolved_reason_code = 'presentation_binding_unresolved'
    ),
    PRIMARY KEY (raid_season_directory_id, ordinal),
    UNIQUE (raid_season_directory_id, season_number),
    UNIQUE (raid_season_directory_id, raid_snapshot_id),
    UNIQUE (raid_season_directory_id, raid_snapshot_id, season_number),
    FOREIGN KEY (raid_season_directory_id, raid_catalog_snapshot_id)
        REFERENCES lab_private_server.raid_season_directory(
            raid_season_directory_id,
            raid_catalog_snapshot_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (raid_catalog_snapshot_id, raid_snapshot_id)
        REFERENCES lab_raid.raid_catalog_snapshot_member(
            raid_catalog_snapshot_id,
            raid_snapshot_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (raid_snapshot_id, season_number)
        REFERENCES lab_raid.raid_snapshot(raid_snapshot_id, season_number)
        ON DELETE RESTRICT,
    FOREIGN KEY (raid_snapshot_id, raid_snapshot_content_sha256)
        REFERENCES lab_raid.raid_snapshot(raid_snapshot_id, content_sha256)
        ON DELETE RESTRICT
);

CREATE TABLE lab_private_server.private_server_boot_revision (
    private_server_boot_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    private_server_boot_revision_uid UUID NOT NULL UNIQUE CHECK (
        private_server_boot_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    revision_number INTEGER NOT NULL UNIQUE CHECK (revision_number >= 1),
    previous_private_server_boot_revision_id BIGINT UNIQUE,
    effective_raid_day_key DATE NOT NULL,
    application_build_selection_revision_id BIGINT NOT NULL,
    application_build_id BIGINT NOT NULL,
    application_build_sha256 BYTEA NOT NULL CHECK (
        octet_length(application_build_sha256) = 32
    ),
    application_contract_id TEXT NOT NULL,
    raid_season_directory_id BIGINT NOT NULL,
    directory_content_sha256 BYTEA NOT NULL CHECK (
        octet_length(directory_content_sha256) = 32
    ),
    capability_manifest_id BIGINT NOT NULL,
    capability_manifest_content_sha256 BYTEA NOT NULL CHECK (
        octet_length(capability_manifest_content_sha256) = 32
    ),
    challenge_policy_activation_revision_id BIGINT NOT NULL,
    challenge_operational_policy_id BIGINT NOT NULL,
    content_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(content_sha256) = 32),
    materialized_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (private_server_boot_revision_id, content_sha256),
    UNIQUE (challenge_policy_activation_revision_id),
    FOREIGN KEY (previous_private_server_boot_revision_id)
        REFERENCES lab_private_server.private_server_boot_revision(
            private_server_boot_revision_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        application_build_selection_revision_id,
        application_build_id,
        application_build_sha256
    ) REFERENCES lab_private_server.application_build_selection_revision(
        application_build_selection_revision_id,
        application_build_id,
        application_build_sha256
    ) ON DELETE RESTRICT,
    FOREIGN KEY (application_build_id, application_contract_id)
        REFERENCES lab_private_server.application_build(
            application_build_id,
            application_contract_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (raid_season_directory_id, directory_content_sha256)
        REFERENCES lab_private_server.raid_season_directory(
            raid_season_directory_id,
            content_sha256
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        capability_manifest_id,
        capability_manifest_content_sha256,
        challenge_operational_policy_id
    ) REFERENCES lab_private_server.capability_manifest(
        capability_manifest_id,
        content_sha256,
        challenge_operational_policy_id
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        challenge_policy_activation_revision_id,
        challenge_operational_policy_id
    ) REFERENCES lab_private_server.challenge_policy_activation_revision(
        challenge_policy_activation_revision_id,
        challenge_operational_policy_id
    ) ON DELETE RESTRICT,
    CHECK (
        (revision_number = 1 AND previous_private_server_boot_revision_id IS NULL)
        OR (revision_number > 1 AND previous_private_server_boot_revision_id IS NOT NULL)
    )
);

CREATE TABLE lab_private_server.private_server_boot_state (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    latest_scheduled_boot_revision_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_private_server.private_server_boot_revision(
            private_server_boot_revision_id
        ) DEFERRABLE INITIALLY DEFERRED,
    updated_at_utc TIMESTAMPTZ NOT NULL
);

ALTER TABLE lab_raid.client_runtime_build
    ADD CONSTRAINT uq_private_server_runtime_build_uid
    UNIQUE (client_runtime_build_id, client_runtime_build_uid),
    ADD CONSTRAINT uq_private_server_runtime_build_source
    UNIQUE (client_runtime_build_id, source_artifact_id);

ALTER TABLE lab_import.source_artifact
    ADD CONSTRAINT uq_private_server_source_artifact_content
    UNIQUE (source_artifact_id, content_sha256);

CREATE TABLE lab_private_server.runtime_execution_profile (
    runtime_execution_profile_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    runtime_execution_profile_uid UUID NOT NULL UNIQUE CHECK (
        runtime_execution_profile_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_account_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    current_runtime_execution_profile_revision_id BIGINT,
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (runtime_execution_profile_id, local_account_id),
    UNIQUE (runtime_execution_profile_id, current_runtime_execution_profile_revision_id)
);

CREATE TABLE lab_private_server.runtime_execution_profile_revision (
    runtime_execution_profile_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    runtime_execution_profile_revision_uid UUID NOT NULL UNIQUE CHECK (
        runtime_execution_profile_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    runtime_execution_profile_id BIGINT NOT NULL,
    local_account_id BIGINT NOT NULL,
    revision_number INTEGER NOT NULL CHECK (revision_number >= 1),
    previous_runtime_execution_profile_revision_id BIGINT,
    schema_version TEXT NOT NULL CHECK (schema_version = 'nll/runtime-execution-profile/v1'),
    original_runtime_build_status TEXT NOT NULL CHECK (
        original_runtime_build_status IN ('ready', 'unresolved')
    ),
    original_client_runtime_build_id BIGINT,
    original_client_runtime_build_uid UUID,
    original_runtime_source_artifact_id BIGINT,
    original_runtime_build_sha256 BYTEA CHECK (
        original_runtime_build_sha256 IS NULL OR octet_length(original_runtime_build_sha256) = 32
    ),
    original_runtime_build_unresolved_reason_code TEXT CHECK (
        original_runtime_build_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    requested_payload JSONB NOT NULL CHECK (jsonb_typeof(requested_payload) = 'object'),
    effective_payload JSONB CHECK (
        effective_payload IS NULL OR jsonb_typeof(effective_payload) = 'object'
    ),
    target_fps SMALLINT CHECK (target_fps IN (30, 60)),
    fixed_delta_denominator INTEGER CHECK (
        fixed_delta_denominator > 0
        AND (target_fps IS NULL OR fixed_delta_denominator = target_fps)
    ),
    vsync_enabled BOOLEAN,
    multiplayer_enabled BOOLEAN CHECK (multiplayer_enabled IS NULL OR NOT multiplayer_enabled),
    time_scale_code TEXT CHECK (time_scale_code IS NULL OR time_scale_code = 'normal_1x'),
    platform_code TEXT CHECK (platform_code IS NULL OR char_length(platform_code) BETWEEN 1 AND 64),
    display_mode_code TEXT CHECK (
        display_mode_code IS NULL OR char_length(display_mode_code) BETWEEN 1 AND 64
    ),
    display_width INTEGER CHECK (display_width > 0),
    display_height INTEGER CHECK (display_height > 0),
    effective_refresh_hz NUMERIC(29, 12) CHECK (effective_refresh_hz > 0),
    graphic_option_mode TEXT CHECK (
        graphic_option_mode IS NULL OR char_length(graphic_option_mode) BETWEEN 1 AND 64
    ),
    default_quality_level TEXT CHECK (
        default_quality_level IS NULL OR char_length(default_quality_level) BETWEEN 1 AND 64
    ),
    post_process_flags TEXT CHECK (
        post_process_flags IS NULL OR char_length(post_process_flags) BETWEEN 1 AND 64
    ),
    volumetric_fog_quality TEXT CHECK (
        volumetric_fog_quality IS NULL OR char_length(volumetric_fog_quality) BETWEEN 1 AND 64
    ),
    battle_effect_quality TEXT CHECK (
        battle_effect_quality IS NULL OR char_length(battle_effect_quality) BETWEEN 1 AND 64
    ),
    battle_animation_physics_flags TEXT CHECK (
        battle_animation_physics_flags IS NULL
        OR char_length(battle_animation_physics_flags) BETWEEN 1 AND 64
    ),
    spine_resolution TEXT CHECK (
        spine_resolution IS NULL OR char_length(spine_resolution) BETWEEN 1 AND 64
    ),
    texture_quality TEXT CHECK (
        texture_quality IS NULL OR char_length(texture_quality) BETWEEN 1 AND 64
    ),
    mesh_quality TEXT CHECK (mesh_quality IS NULL OR char_length(mesh_quality) BETWEEN 1 AND 64),
    anti_aliasing_enabled TEXT CHECK (
        anti_aliasing_enabled IS NULL OR char_length(anti_aliasing_enabled) BETWEEN 1 AND 64
    ),
    anti_aliasing_step TEXT CHECK (
        anti_aliasing_step IS NULL OR char_length(anti_aliasing_step) BETWEEN 1 AND 64
    ),
    fact_count SMALLINT NOT NULL CHECK (fact_count = 21),
    effective_snapshot_present BOOLEAN NOT NULL,
    harness_validation_ready BOOLEAN NOT NULL,
    original_client_launch_ready BOOLEAN NOT NULL,
    effective_readback_ready BOOLEAN NOT NULL,
    readiness_issue_code TEXT CHECK (
        readiness_issue_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    materialized_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (runtime_execution_profile_id, revision_number),
    UNIQUE (runtime_execution_profile_revision_id, runtime_execution_profile_id),
    UNIQUE (runtime_execution_profile_revision_id, local_account_id),
    FOREIGN KEY (runtime_execution_profile_id, local_account_id)
        REFERENCES lab_private_server.runtime_execution_profile(
            runtime_execution_profile_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (previous_runtime_execution_profile_revision_id, runtime_execution_profile_id)
        REFERENCES lab_private_server.runtime_execution_profile_revision(
            runtime_execution_profile_revision_id,
            runtime_execution_profile_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (original_client_runtime_build_id, original_client_runtime_build_uid)
        REFERENCES lab_raid.client_runtime_build(
            client_runtime_build_id,
            client_runtime_build_uid
        ) ON DELETE RESTRICT,
    FOREIGN KEY (original_client_runtime_build_id, original_runtime_source_artifact_id)
        REFERENCES lab_raid.client_runtime_build(
            client_runtime_build_id,
            source_artifact_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (original_runtime_source_artifact_id, original_runtime_build_sha256)
        REFERENCES lab_import.source_artifact(
            source_artifact_id,
            content_sha256
        ) ON DELETE RESTRICT,
    CHECK (
        (revision_number = 1 AND previous_runtime_execution_profile_revision_id IS NULL)
        OR (revision_number > 1 AND previous_runtime_execution_profile_revision_id IS NOT NULL)
    ),
    CHECK (
        (original_runtime_build_status = 'ready'
            AND original_client_runtime_build_id IS NOT NULL
            AND original_client_runtime_build_uid IS NOT NULL
            AND original_runtime_source_artifact_id IS NOT NULL
            AND original_runtime_build_sha256 IS NOT NULL
            AND original_runtime_build_unresolved_reason_code IS NULL)
        OR (original_runtime_build_status = 'unresolved'
            AND original_client_runtime_build_id IS NULL
            AND original_client_runtime_build_uid IS NULL
            AND original_runtime_source_artifact_id IS NULL
            AND original_runtime_build_sha256 IS NULL
            AND original_runtime_build_unresolved_reason_code IS NOT NULL)
    ),
    CHECK (harness_validation_ready OR readiness_issue_code IS NOT NULL),
    CHECK (
        original_client_launch_ready =
        (harness_validation_ready AND original_runtime_build_status = 'ready')
    ),
    CHECK (
        effective_readback_ready =
        (original_client_launch_ready
            AND effective_snapshot_present
            AND requested_payload = effective_payload)
    ),
    CHECK (effective_snapshot_present = (effective_payload IS NOT NULL))
);

CREATE TABLE lab_private_server.runtime_execution_profile_fact (
    runtime_execution_profile_revision_id BIGINT NOT NULL
        REFERENCES lab_private_server.runtime_execution_profile_revision(
            runtime_execution_profile_revision_id
        ) ON DELETE RESTRICT,
    field_code TEXT NOT NULL CHECK (field_code IN (
        'platform', 'target_fps', 'fixed_delta_denominator',
        'vsync_enabled', 'multiplayer_enabled', 'time_scale', 'display_mode',
        'display_width', 'display_height', 'effective_refresh_rate',
        'graphic_option_mode', 'default_quality_level', 'post_process_flags',
        'volumetric_fog_quality', 'battle_effect_quality',
        'battle_animation_physics_flags', 'spine_resolution', 'texture_quality',
        'mesh_quality', 'anti_aliasing_enabled', 'anti_aliasing_step'
    )),
    requested_status TEXT NOT NULL CHECK (
        requested_status IN ('ready', 'unresolved', 'not_applicable')
    ),
    requested_value TEXT CHECK (
        requested_value IS NULL OR (
            char_length(requested_value) BETWEEN 1 AND 128
            AND requested_value !~ '[[:cntrl:]]'
        )
    ),
    requested_reason_code TEXT CHECK (
        requested_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    effective_status TEXT CHECK (
        effective_status IN ('ready', 'unresolved', 'not_applicable')
    ),
    effective_value TEXT CHECK (
        effective_value IS NULL OR (
            char_length(effective_value) BETWEEN 1 AND 128
            AND effective_value !~ '[[:cntrl:]]'
        )
    ),
    effective_reason_code TEXT CHECK (
        effective_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    PRIMARY KEY (runtime_execution_profile_revision_id, field_code),
    CHECK (
        (requested_status = 'ready'
            AND requested_value IS NOT NULL
            AND requested_reason_code IS NULL)
        OR (requested_status = 'unresolved'
            AND requested_value IS NULL
            AND requested_reason_code IS NOT NULL)
        OR (requested_status = 'not_applicable'
            AND requested_value IS NULL
            AND requested_reason_code IS NULL)
    ),
    CHECK (
        (effective_status IS NULL
            AND effective_value IS NULL
            AND effective_reason_code IS NULL)
        OR (effective_status = 'ready'
            AND effective_value IS NOT NULL
            AND effective_reason_code IS NULL)
        OR (effective_status = 'unresolved'
            AND effective_value IS NULL
            AND effective_reason_code IS NOT NULL)
        OR (effective_status = 'not_applicable'
            AND effective_value IS NULL
            AND effective_reason_code IS NULL)
    )
);

ALTER TABLE lab_private_server.runtime_execution_profile
    ADD CONSTRAINT fk_runtime_profile_current_revision
    FOREIGN KEY (
        current_runtime_execution_profile_revision_id,
        runtime_execution_profile_id
    ) REFERENCES lab_private_server.runtime_execution_profile_revision(
        runtime_execution_profile_revision_id,
        runtime_execution_profile_id
    ) DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE lab_private_server.combat_control_profile (
    combat_control_profile_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    combat_control_profile_uid UUID NOT NULL UNIQUE CHECK (
        combat_control_profile_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_account_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    current_combat_control_profile_revision_id BIGINT,
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (combat_control_profile_id, local_account_id),
    UNIQUE (combat_control_profile_id, current_combat_control_profile_revision_id)
);

CREATE TABLE lab_private_server.combat_control_profile_revision (
    combat_control_profile_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    combat_control_profile_revision_uid UUID NOT NULL UNIQUE CHECK (
        combat_control_profile_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    combat_control_profile_id BIGINT NOT NULL,
    local_account_id BIGINT NOT NULL,
    revision_number INTEGER NOT NULL CHECK (revision_number >= 1),
    previous_combat_control_profile_revision_id BIGINT,
    schema_version TEXT NOT NULL CHECK (schema_version = 'nll/combat-control-profile/v1'),
    requested_payload JSONB NOT NULL CHECK (jsonb_typeof(requested_payload) = 'object'),
    effective_payload JSONB CHECK (
        effective_payload IS NULL OR jsonb_typeof(effective_payload) = 'object'
    ),
    aim_sensitivity NUMERIC(29, 12) CHECK (aim_sensitivity >= 0),
    use_aim_assistant BOOLEAN,
    aim_assistant_intensity NUMERIC(20, 8) CHECK (aim_assistant_intensity >= 0),
    use_pc_aim_sync BOOLEAN,
    max_per_shot_correct BOOLEAN,
    auto_combat_status TEXT NOT NULL CHECK (
        auto_combat_status IN ('ready', 'unresolved', 'not_applicable')
    ),
    auto_combat_value BOOLEAN,
    auto_combat_unresolved_reason_code TEXT CHECK (
        auto_combat_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    auto_burst_status TEXT NOT NULL CHECK (
        auto_burst_status IN ('ready', 'unresolved', 'not_applicable')
    ),
    auto_burst_value BOOLEAN,
    auto_burst_unresolved_reason_code TEXT CHECK (
        auto_burst_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    fact_count SMALLINT NOT NULL CHECK (fact_count = 7),
    effective_snapshot_present BOOLEAN NOT NULL,
    manual_ready BOOLEAN NOT NULL,
    effective_manual_ready BOOLEAN NOT NULL,
    effective_readback_ready BOOLEAN NOT NULL,
    readiness_issue_code TEXT CHECK (
        readiness_issue_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    materialized_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (combat_control_profile_id, revision_number),
    UNIQUE (combat_control_profile_revision_id, combat_control_profile_id),
    UNIQUE (combat_control_profile_revision_id, local_account_id),
    FOREIGN KEY (combat_control_profile_id, local_account_id)
        REFERENCES lab_private_server.combat_control_profile(
            combat_control_profile_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (previous_combat_control_profile_revision_id, combat_control_profile_id)
        REFERENCES lab_private_server.combat_control_profile_revision(
            combat_control_profile_revision_id,
            combat_control_profile_id
        ) ON DELETE RESTRICT,
    CHECK (
        (revision_number = 1 AND previous_combat_control_profile_revision_id IS NULL)
        OR (revision_number > 1 AND previous_combat_control_profile_revision_id IS NOT NULL)
    ),
    CHECK (
        use_aim_assistant IS NULL
        OR (use_aim_assistant AND aim_assistant_intensity IS NOT NULL)
        OR (NOT use_aim_assistant AND aim_assistant_intensity IS NULL)
    ),
    CHECK (
        (auto_combat_status = 'ready'
            AND auto_combat_value IS NOT NULL
            AND auto_combat_unresolved_reason_code IS NULL)
        OR (auto_combat_status = 'unresolved'
            AND auto_combat_value IS NULL
            AND auto_combat_unresolved_reason_code IS NOT NULL)
        OR (auto_combat_status = 'not_applicable'
            AND auto_combat_value IS NULL
            AND auto_combat_unresolved_reason_code IS NULL)
    ),
    CHECK (
        (auto_burst_status = 'ready'
            AND auto_burst_value IS NOT NULL
            AND auto_burst_unresolved_reason_code IS NULL)
        OR (auto_burst_status = 'unresolved'
            AND auto_burst_value IS NULL
            AND auto_burst_unresolved_reason_code IS NOT NULL)
        OR (auto_burst_status = 'not_applicable'
            AND auto_burst_value IS NULL
            AND auto_burst_unresolved_reason_code IS NULL)
    ),
    CHECK (manual_ready OR readiness_issue_code IS NOT NULL),
    CHECK (
        effective_readback_ready =
        (manual_ready AND effective_manual_ready
            AND effective_snapshot_present AND requested_payload = effective_payload)
    ),
    CHECK (effective_snapshot_present = (effective_payload IS NOT NULL)),
    CHECK (effective_snapshot_present OR NOT effective_manual_ready)
);

CREATE TABLE lab_private_server.combat_control_profile_fact (
    combat_control_profile_revision_id BIGINT NOT NULL
        REFERENCES lab_private_server.combat_control_profile_revision(
            combat_control_profile_revision_id
        ) ON DELETE RESTRICT,
    field_code TEXT NOT NULL CHECK (field_code IN (
        'aim_sensitivity', 'use_aim_assistant', 'aim_assistant_intensity',
        'use_pc_aim_sync', 'max_per_shot_correct', 'auto_combat', 'auto_burst'
    )),
    requested_status TEXT NOT NULL CHECK (
        requested_status IN ('ready', 'unresolved', 'not_applicable')
    ),
    requested_value TEXT CHECK (
        requested_value IS NULL OR (
            char_length(requested_value) BETWEEN 1 AND 128
            AND requested_value !~ '[[:cntrl:]]'
        )
    ),
    requested_reason_code TEXT CHECK (
        requested_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    effective_status TEXT CHECK (
        effective_status IN ('ready', 'unresolved', 'not_applicable')
    ),
    effective_value TEXT CHECK (
        effective_value IS NULL OR (
            char_length(effective_value) BETWEEN 1 AND 128
            AND effective_value !~ '[[:cntrl:]]'
        )
    ),
    effective_reason_code TEXT CHECK (
        effective_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    PRIMARY KEY (combat_control_profile_revision_id, field_code),
    CHECK (
        (requested_status = 'ready'
            AND requested_value IS NOT NULL
            AND requested_reason_code IS NULL)
        OR (requested_status = 'unresolved'
            AND requested_value IS NULL
            AND requested_reason_code IS NOT NULL)
        OR (requested_status = 'not_applicable'
            AND requested_value IS NULL
            AND requested_reason_code IS NULL)
    ),
    CHECK (
        (effective_status IS NULL
            AND effective_value IS NULL
            AND effective_reason_code IS NULL)
        OR (effective_status = 'ready'
            AND effective_value IS NOT NULL
            AND effective_reason_code IS NULL)
        OR (effective_status = 'unresolved'
            AND effective_value IS NULL
            AND effective_reason_code IS NOT NULL)
        OR (effective_status = 'not_applicable'
            AND effective_value IS NULL
            AND effective_reason_code IS NULL)
    )
);

ALTER TABLE lab_private_server.combat_control_profile
    ADD CONSTRAINT fk_control_profile_current_revision
    FOREIGN KEY (
        current_combat_control_profile_revision_id,
        combat_control_profile_id
    ) REFERENCES lab_private_server.combat_control_profile_revision(
        combat_control_profile_revision_id,
        combat_control_profile_id
    ) DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE lab_profile.local_session
    ADD CONSTRAINT uq_private_server_session_account
    UNIQUE (local_session_id, local_account_id);

ALTER TABLE lab_profile.profile_template_revision
    ADD CONSTRAINT uq_private_server_profile_account_state
    UNIQUE (profile_template_revision_id, local_account_id, account_state_revision_id);

ALTER TABLE lab_profile.profile_template_revision_build
    ADD CONSTRAINT uq_private_server_profile_build_member
    UNIQUE (profile_template_revision_id, character_build_id, build_revision_id);

ALTER TABLE lab_profile.squad_revision_member
    ADD CONSTRAINT uq_private_server_squad_build_member
    UNIQUE (squad_revision_id, position, character_build_id, build_revision_id);

ALTER TABLE lab_profile.squad_revision
    ADD CONSTRAINT uq_private_server_squad_exact_revision
    UNIQUE (squad_revision_id, local_account_id, squad_revision_uid, content_sha256);

ALTER TABLE lab_profile.character_build_revision
    ADD CONSTRAINT uq_private_server_build_character_member
    UNIQUE (build_revision_id, character_build_id, character_entity_id);

ALTER TABLE lab_private_server.capability_manifest
    ADD CONSTRAINT uq_private_server_capability_manifest_content
    UNIQUE (capability_manifest_id, content_sha256);

CREATE TABLE lab_private_server.local_client_context (
    local_client_context_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    local_client_context_uid UUID NOT NULL UNIQUE CHECK (
        local_client_context_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_session_id BIGINT NOT NULL UNIQUE,
    local_account_id BIGINT NOT NULL,
    current_local_client_context_revision_id BIGINT UNIQUE,
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (local_client_context_id, local_account_id),
    UNIQUE (local_client_context_id, local_session_id, local_account_id),
    UNIQUE (local_client_context_id, current_local_client_context_revision_id),
    FOREIGN KEY (local_session_id, local_account_id)
        REFERENCES lab_profile.local_session(local_session_id, local_account_id)
        ON DELETE RESTRICT
);

CREATE TABLE lab_private_server.raid_season_selection (
    raid_season_selection_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raid_season_selection_uid UUID NOT NULL UNIQUE CHECK (
        raid_season_selection_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_client_context_id BIGINT NOT NULL UNIQUE,
    local_session_id BIGINT NOT NULL,
    local_account_id BIGINT NOT NULL,
    current_selected_raid_season_revision_id BIGINT UNIQUE,
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (raid_season_selection_id, local_client_context_id),
    UNIQUE (raid_season_selection_id, local_account_id),
    UNIQUE (raid_season_selection_id, current_selected_raid_season_revision_id),
    FOREIGN KEY (local_client_context_id, local_session_id, local_account_id)
        REFERENCES lab_private_server.local_client_context(
            local_client_context_id,
            local_session_id,
            local_account_id
        ) ON DELETE RESTRICT
);

CREATE TABLE lab_private_server.selected_raid_season_revision (
    selected_raid_season_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    selected_raid_season_revision_uid UUID NOT NULL UNIQUE CHECK (
        selected_raid_season_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    raid_season_selection_id BIGINT NOT NULL,
    local_client_context_id BIGINT NOT NULL,
    local_session_id BIGINT NOT NULL,
    local_account_id BIGINT NOT NULL,
    revision_number INTEGER NOT NULL CHECK (revision_number >= 1),
    previous_selected_raid_season_revision_id BIGINT,
    raid_season_directory_id BIGINT NOT NULL,
    directory_content_sha256 BYTEA NOT NULL CHECK (octet_length(directory_content_sha256) = 32),
    raid_snapshot_id BIGINT NOT NULL,
    season_number INTEGER NOT NULL,
    raid_snapshot_content_sha256 BYTEA NOT NULL CHECK (
        octet_length(raid_snapshot_content_sha256) = 32
    ),
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    materialized_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (raid_season_selection_id, revision_number),
    UNIQUE (selected_raid_season_revision_id, raid_season_selection_id),
    UNIQUE (selected_raid_season_revision_id, local_client_context_id),
    UNIQUE (selected_raid_season_revision_id, local_account_id),
    UNIQUE (selected_raid_season_revision_id, content_sha256),
    UNIQUE (
        selected_raid_season_revision_id,
        local_client_context_id,
        local_account_id,
        raid_season_directory_id,
        raid_snapshot_id
    ),
    FOREIGN KEY (raid_season_selection_id, local_client_context_id)
        REFERENCES lab_private_server.raid_season_selection(
            raid_season_selection_id,
            local_client_context_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (local_client_context_id, local_session_id, local_account_id)
        REFERENCES lab_private_server.local_client_context(
            local_client_context_id,
            local_session_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (previous_selected_raid_season_revision_id, raid_season_selection_id)
        REFERENCES lab_private_server.selected_raid_season_revision(
            selected_raid_season_revision_id,
            raid_season_selection_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (raid_season_directory_id, raid_snapshot_id, season_number)
        REFERENCES lab_private_server.raid_season_directory_member(
            raid_season_directory_id,
            raid_snapshot_id,
            season_number
        ) ON DELETE RESTRICT,
    FOREIGN KEY (raid_season_directory_id, directory_content_sha256)
        REFERENCES lab_private_server.raid_season_directory(
            raid_season_directory_id,
            content_sha256
        ) ON DELETE RESTRICT,
    FOREIGN KEY (raid_snapshot_id, raid_snapshot_content_sha256)
        REFERENCES lab_raid.raid_snapshot(raid_snapshot_id, content_sha256)
        ON DELETE RESTRICT,
    CHECK (
        (revision_number = 1 AND previous_selected_raid_season_revision_id IS NULL)
        OR (revision_number > 1 AND previous_selected_raid_season_revision_id IS NOT NULL)
    )
);

ALTER TABLE lab_private_server.raid_season_selection
    ADD CONSTRAINT fk_raid_season_selection_current
    FOREIGN KEY (
        current_selected_raid_season_revision_id,
        raid_season_selection_id
    ) REFERENCES lab_private_server.selected_raid_season_revision(
        selected_raid_season_revision_id,
        raid_season_selection_id
    ) DEFERRABLE INITIALLY DEFERRED;

-- A lobby-ready private-server context seals every independently mutable
-- member of the V0006 account bootstrap revision set.  These composite keys
-- let historical replay prove that the stored UID/hash belongs to the exact
-- feature/squad row rather than merely accepting individually valid values.
ALTER TABLE lab_local_game.client_feature_manifest
    ADD CONSTRAINT uq_private_server_feature_manifest_pin UNIQUE (
        client_feature_manifest_id,
        client_feature_manifest_uid,
        content_sha256
    );

ALTER TABLE lab_profile.squad_revision
    ADD CONSTRAINT uq_private_server_squad_revision_pin UNIQUE (
        squad_revision_id,
        local_account_id,
        squad_revision_uid,
        content_sha256
    );

CREATE TABLE lab_private_server.local_client_context_revision (
    local_client_context_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    local_client_context_revision_uid UUID NOT NULL UNIQUE CHECK (
        local_client_context_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_client_context_id BIGINT NOT NULL,
    local_session_id BIGINT NOT NULL,
    local_account_id BIGINT NOT NULL,
    revision_number INTEGER NOT NULL CHECK (revision_number >= 1),
    previous_local_client_context_revision_id BIGINT,
    private_server_boot_revision_id BIGINT NOT NULL,
    private_server_boot_content_sha256 BYTEA NOT NULL CHECK (
        octet_length(private_server_boot_content_sha256) = 32
    ),
    capability_manifest_id BIGINT NOT NULL,
    capability_manifest_content_sha256 BYTEA NOT NULL CHECK (
        octet_length(capability_manifest_content_sha256) = 32
    ),
    application_build_id BIGINT NOT NULL,
    application_build_sha256 BYTEA NOT NULL CHECK (
        octet_length(application_build_sha256) = 32
    ),
    application_contract_id TEXT NOT NULL,
    issued_at_utc TIMESTAMPTZ NOT NULL,
    expires_at_utc TIMESTAMPTZ NOT NULL,
    stage TEXT NOT NULL CHECK (stage IN ('loading', 'local_connected', 'lobby_ready', 'closed')),
    connected_at_utc TIMESTAMPTZ,
    lobby_ready_at_utc TIMESTAMPTZ,
    account_revision_set_sha256 BYTEA CHECK (
        account_revision_set_sha256 IS NULL OR octet_length(account_revision_set_sha256) = 32
    ),
    account_state_revision_id BIGINT,
    profile_template_revision_id BIGINT,
    lobby_presentation_revision_id BIGINT,
    wallet_revision_id BIGINT,
    client_feature_manifest_id BIGINT,
    client_feature_manifest_uid UUID,
    client_feature_manifest_content_sha256 BYTEA CHECK (
        client_feature_manifest_content_sha256 IS NULL
        OR octet_length(client_feature_manifest_content_sha256) = 32
    ),
    squad_revision_id BIGINT,
    squad_revision_uid UUID,
    squad_revision_content_sha256 BYTEA CHECK (
        squad_revision_content_sha256 IS NULL
        OR octet_length(squad_revision_content_sha256) = 32
    ),
    selected_raid_season_revision_id BIGINT,
    selected_season_content_sha256 BYTEA CHECK (
        selected_season_content_sha256 IS NULL
        OR octet_length(selected_season_content_sha256) = 32
    ),
    closed_at_utc TIMESTAMPTZ,
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    materialized_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (local_client_context_id, revision_number),
    UNIQUE (local_client_context_revision_id, local_client_context_id),
    UNIQUE (local_client_context_revision_id, local_account_id),
    UNIQUE (
        local_client_context_revision_id,
        local_client_context_id,
        local_account_id,
        selected_raid_season_revision_id
    ),
    FOREIGN KEY (local_client_context_id, local_session_id, local_account_id)
        REFERENCES lab_private_server.local_client_context(
            local_client_context_id,
            local_session_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (previous_local_client_context_revision_id, local_client_context_id)
        REFERENCES lab_private_server.local_client_context_revision(
            local_client_context_revision_id,
            local_client_context_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (private_server_boot_revision_id, private_server_boot_content_sha256)
        REFERENCES lab_private_server.private_server_boot_revision(
            private_server_boot_revision_id,
            content_sha256
        ) ON DELETE RESTRICT,
    FOREIGN KEY (capability_manifest_id, capability_manifest_content_sha256)
        REFERENCES lab_private_server.capability_manifest(
            capability_manifest_id,
            content_sha256
        ) ON DELETE RESTRICT,
    FOREIGN KEY (application_build_id, application_build_sha256)
        REFERENCES lab_private_server.application_build(
            application_build_id,
            application_build_sha256
        ) ON DELETE RESTRICT,
    FOREIGN KEY (application_build_id, application_contract_id)
        REFERENCES lab_private_server.application_build(
            application_build_id,
            application_contract_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (selected_raid_season_revision_id, local_client_context_id)
        REFERENCES lab_private_server.selected_raid_season_revision(
            selected_raid_season_revision_id,
            local_client_context_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (selected_raid_season_revision_id, selected_season_content_sha256)
        REFERENCES lab_private_server.selected_raid_season_revision(
            selected_raid_season_revision_id,
            content_sha256
        ) ON DELETE RESTRICT,
    FOREIGN KEY (account_state_revision_id, local_account_id)
        REFERENCES lab_profile.account_state_revision(
            account_state_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (profile_template_revision_id, local_account_id, account_state_revision_id)
        REFERENCES lab_profile.profile_template_revision(
            profile_template_revision_id,
            local_account_id,
            account_state_revision_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (lobby_presentation_revision_id, local_account_id)
        REFERENCES lab_local_game.lobby_presentation_revision(
            lobby_presentation_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (wallet_revision_id, local_account_id)
        REFERENCES lab_local_game.wallet_revision(wallet_revision_id, local_account_id)
        ON DELETE RESTRICT,
    FOREIGN KEY (
        client_feature_manifest_id,
        client_feature_manifest_uid,
        client_feature_manifest_content_sha256
    ) REFERENCES lab_local_game.client_feature_manifest(
        client_feature_manifest_id,
        client_feature_manifest_uid,
        content_sha256
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        squad_revision_id,
        local_account_id,
        squad_revision_uid,
        squad_revision_content_sha256
    ) REFERENCES lab_profile.squad_revision(
        squad_revision_id,
        local_account_id,
        squad_revision_uid,
        content_sha256
    ) ON DELETE RESTRICT,
    CHECK (
        (revision_number = 1 AND previous_local_client_context_revision_id IS NULL)
        OR (revision_number > 1 AND previous_local_client_context_revision_id IS NOT NULL)
    ),
    CHECK (expires_at_utc > issued_at_utc),
    CHECK (
        (selected_raid_season_revision_id IS NULL) =
        (selected_season_content_sha256 IS NULL)
    ),
    CHECK (
        (account_revision_set_sha256 IS NULL
            AND account_state_revision_id IS NULL
            AND profile_template_revision_id IS NULL
            AND lobby_presentation_revision_id IS NULL
            AND wallet_revision_id IS NULL
            AND client_feature_manifest_id IS NULL
            AND client_feature_manifest_uid IS NULL
            AND client_feature_manifest_content_sha256 IS NULL
            AND squad_revision_id IS NULL
            AND squad_revision_uid IS NULL
            AND squad_revision_content_sha256 IS NULL)
        OR (account_revision_set_sha256 IS NOT NULL
            AND account_state_revision_id IS NOT NULL
            AND profile_template_revision_id IS NOT NULL
            AND lobby_presentation_revision_id IS NOT NULL
            AND wallet_revision_id IS NOT NULL
            AND client_feature_manifest_id IS NOT NULL
            AND client_feature_manifest_uid IS NOT NULL
            AND client_feature_manifest_content_sha256 IS NOT NULL
            AND (
                (squad_revision_id IS NULL
                    AND squad_revision_uid IS NULL
                    AND squad_revision_content_sha256 IS NULL)
                OR (squad_revision_id IS NOT NULL
                    AND squad_revision_uid IS NOT NULL
                    AND squad_revision_content_sha256 IS NOT NULL)
            ))
    ),
    CHECK (
        (stage = 'loading'
            AND connected_at_utc IS NULL
            AND lobby_ready_at_utc IS NULL
            AND account_revision_set_sha256 IS NULL
            AND selected_raid_season_revision_id IS NULL
            AND closed_at_utc IS NULL)
        OR (stage = 'local_connected'
            AND connected_at_utc IS NOT NULL
            AND connected_at_utc >= issued_at_utc
            AND connected_at_utc < expires_at_utc
            AND lobby_ready_at_utc IS NULL
            AND account_revision_set_sha256 IS NULL
            AND selected_raid_season_revision_id IS NOT NULL
            AND closed_at_utc IS NULL)
        OR (stage = 'lobby_ready'
            AND connected_at_utc IS NOT NULL
            AND lobby_ready_at_utc IS NOT NULL
            AND lobby_ready_at_utc >= connected_at_utc
            AND lobby_ready_at_utc < expires_at_utc
            AND account_revision_set_sha256 IS NOT NULL
            AND selected_raid_season_revision_id IS NOT NULL
            AND closed_at_utc IS NULL)
        OR (stage = 'closed'
            AND closed_at_utc IS NOT NULL
            AND closed_at_utc >= COALESCE(
                lobby_ready_at_utc,
                connected_at_utc,
                issued_at_utc
            )
            AND (connected_at_utc IS NULL
                OR (connected_at_utc >= issued_at_utc
                    AND connected_at_utc < expires_at_utc))
            AND (lobby_ready_at_utc IS NULL
                OR (connected_at_utc IS NOT NULL
                    AND lobby_ready_at_utc >= connected_at_utc
                    AND lobby_ready_at_utc < expires_at_utc))
            AND (
                (connected_at_utc IS NULL
                    AND lobby_ready_at_utc IS NULL
                    AND account_revision_set_sha256 IS NULL
                    AND selected_raid_season_revision_id IS NULL)
                OR (connected_at_utc IS NOT NULL
                    AND lobby_ready_at_utc IS NULL
                    AND account_revision_set_sha256 IS NULL
                    AND selected_raid_season_revision_id IS NOT NULL)
                OR (connected_at_utc IS NOT NULL
                    AND lobby_ready_at_utc IS NOT NULL
                    AND account_revision_set_sha256 IS NOT NULL
                    AND selected_raid_season_revision_id IS NOT NULL)
            ))
    )
);

ALTER TABLE lab_private_server.local_client_context
    ADD CONSTRAINT fk_local_client_context_current
    FOREIGN KEY (
        current_local_client_context_revision_id,
        local_client_context_id
    ) REFERENCES lab_private_server.local_client_context_revision(
        local_client_context_revision_id,
        local_client_context_id
    ) DEFERRABLE INITIALLY DEFERRED;

-- Each raid day is an independent aggregate.  There is no predecessor edge
-- between days: lazy rollover means opening the target day's aggregate once.
CREATE TABLE lab_private_server.challenge_daily_state (
    challenge_daily_state_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    challenge_daily_state_uid UUID NOT NULL UNIQUE CHECK (
        challenge_daily_state_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_account_id BIGINT NOT NULL
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    challenge_operational_policy_id BIGINT NOT NULL,
    policy_content_sha256 BYTEA NOT NULL CHECK (octet_length(policy_content_sha256) = 32),
    raid_season_directory_id BIGINT NOT NULL
        REFERENCES lab_private_server.raid_season_directory(raid_season_directory_id)
        ON DELETE RESTRICT,
    raid_day_key DATE NOT NULL,
    counter_scope TEXT NOT NULL CHECK (
        counter_scope IN ('per_season', 'shared_across_directory')
    ),
    raid_snapshot_id BIGINT,
    current_challenge_daily_state_revision_id BIGINT UNIQUE,
    first_observed_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE NULLS NOT DISTINCT (
        local_account_id,
        challenge_operational_policy_id,
        raid_season_directory_id,
        raid_day_key,
        counter_scope,
        raid_snapshot_id
    ),
    UNIQUE (challenge_daily_state_id, local_account_id),
    UNIQUE NULLS NOT DISTINCT (
        challenge_daily_state_id,
        local_account_id,
        challenge_operational_policy_id,
        raid_season_directory_id,
        raid_day_key,
        counter_scope,
        raid_snapshot_id
    ),
    FOREIGN KEY (challenge_operational_policy_id, policy_content_sha256)
        REFERENCES lab_private_server.challenge_operational_policy(
            challenge_operational_policy_id,
            content_sha256
        ) ON DELETE RESTRICT,
    FOREIGN KEY (raid_season_directory_id, raid_snapshot_id)
        REFERENCES lab_private_server.raid_season_directory_member(
            raid_season_directory_id,
            raid_snapshot_id
        ) ON DELETE RESTRICT,
    CHECK (raid_day_key = lab_private_server.raid_day_key(first_observed_at_utc)),
    CHECK (
        (counter_scope = 'per_season' AND raid_snapshot_id IS NOT NULL)
        OR (counter_scope = 'shared_across_directory' AND raid_snapshot_id IS NULL)
    )
);

CREATE TABLE lab_private_server.challenge_daily_state_revision (
    challenge_daily_state_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    challenge_daily_state_revision_uid UUID NOT NULL UNIQUE CHECK (
        challenge_daily_state_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    challenge_daily_state_id BIGINT NOT NULL,
    local_account_id BIGINT NOT NULL,
    challenge_operational_policy_id BIGINT NOT NULL,
    raid_season_directory_id BIGINT NOT NULL,
    raid_day_key DATE NOT NULL,
    counter_scope TEXT NOT NULL,
    raid_snapshot_id BIGINT,
    revision_number INTEGER NOT NULL CHECK (revision_number >= 1),
    previous_challenge_daily_state_revision_id BIGINT,
    consumed_entries INTEGER NOT NULL CHECK (consumed_entries >= 0),
    consumption_operation_uid UUID UNIQUE,
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    materialized_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (challenge_daily_state_id, revision_number),
    UNIQUE (challenge_daily_state_revision_id, challenge_daily_state_id),
    UNIQUE (challenge_daily_state_revision_id, local_account_id),
    UNIQUE (challenge_daily_state_revision_id, content_sha256),
    FOREIGN KEY (challenge_daily_state_id, local_account_id)
        REFERENCES lab_private_server.challenge_daily_state(
            challenge_daily_state_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        challenge_daily_state_id,
        local_account_id,
        challenge_operational_policy_id,
        raid_season_directory_id,
        raid_day_key,
        counter_scope,
        raid_snapshot_id
    ) REFERENCES lab_private_server.challenge_daily_state(
        challenge_daily_state_id,
        local_account_id,
        challenge_operational_policy_id,
        raid_season_directory_id,
        raid_day_key,
        counter_scope,
        raid_snapshot_id
    ) ON DELETE RESTRICT,
    FOREIGN KEY (previous_challenge_daily_state_revision_id, challenge_daily_state_id)
        REFERENCES lab_private_server.challenge_daily_state_revision(
            challenge_daily_state_revision_id,
            challenge_daily_state_id
        ) ON DELETE RESTRICT,
    CHECK (
        (revision_number = 1
            AND previous_challenge_daily_state_revision_id IS NULL
            AND consumed_entries = 0
            AND consumption_operation_uid IS NULL)
        OR (revision_number > 1
            AND previous_challenge_daily_state_revision_id IS NOT NULL
            AND consumed_entries > 0
            AND consumption_operation_uid IS NOT NULL)
    )
);

ALTER TABLE lab_private_server.challenge_daily_state
    ADD CONSTRAINT fk_challenge_daily_state_current_revision
    FOREIGN KEY (
        current_challenge_daily_state_revision_id,
        challenge_daily_state_id
    ) REFERENCES lab_private_server.challenge_daily_state_revision(
        challenge_daily_state_revision_id,
        challenge_daily_state_id
    ) DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE lab_private_server.challenge_run (
    challenge_run_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    challenge_run_uid UUID NOT NULL UNIQUE CHECK (
        challenge_run_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_account_id BIGINT NOT NULL
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    local_client_context_id BIGINT NOT NULL,
    local_client_context_revision_id BIGINT NOT NULL,
    selected_raid_season_revision_id BIGINT NOT NULL,
    raid_season_directory_id BIGINT NOT NULL,
    raid_snapshot_id BIGINT NOT NULL,
    profile_template_revision_id BIGINT NOT NULL,
    account_state_revision_id BIGINT NOT NULL,
    runtime_execution_profile_revision_id BIGINT NOT NULL,
    combat_control_profile_revision_id BIGINT NOT NULL,
    challenge_policy_activation_revision_id BIGINT NOT NULL,
    challenge_operational_policy_id BIGINT NOT NULL,
    challenge_daily_state_id BIGINT NOT NULL,
    admission_daily_state_revision_id BIGINT NOT NULL,
    admission_daily_state_content_sha256 BYTEA NOT NULL CHECK (
        octet_length(admission_daily_state_content_sha256) = 32
    ),
    opening_raid_day_key DATE NOT NULL,
    execution_lane TEXT NOT NULL CHECK (
        execution_lane = 'lab_harness_observation/v1'
    ),
    is_mock_battle BOOLEAN NOT NULL,
    configured_team_count SMALLINT NOT NULL CHECK (configured_team_count BETWEEN 1 AND 5),
    status TEXT NOT NULL CHECK (status IN (
        'open', 'team_in_progress', 'team_result_accepted', 'regroup_ready',
        'completed', 'abandoned'
    )),
    state_version INTEGER NOT NULL CHECK (state_version >= 1),
    next_team_ordinal SMALLINT CHECK (next_team_ordinal BETWEEN 1 AND 5),
    active_team_ordinal SMALLINT CHECK (active_team_ordinal BETWEEN 1 AND 5),
    accepted_team_count SMALLINT NOT NULL CHECK (
        accepted_team_count BETWEEN 0 AND configured_team_count
    ),
    canonical_cumulative_damage TEXT NOT NULL CHECK (
        canonical_cumulative_damage ~ '^(0|[1-9][0-9]{0,77})$'
    ),
    cumulative_damage NUMERIC(78, 0) NOT NULL CHECK (cumulative_damage >= 0),
    final_result_uid UUID CHECK (
        final_result_uid IS NULL
        OR final_result_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    abandonment_uid UUID CHECK (
        abandonment_uid IS NULL
        OR abandonment_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    abandon_reason_code TEXT CHECK (
        abandon_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    last_operation_uid UUID NOT NULL,
    binding_sha256 BYTEA NOT NULL CHECK (octet_length(binding_sha256) = 32),
    current_challenge_run_revision_id BIGINT,
    opened_at_utc TIMESTAMPTZ NOT NULL,
    updated_at_utc TIMESTAMPTZ NOT NULL CHECK (updated_at_utc >= opened_at_utc),
    UNIQUE (challenge_run_id, local_account_id),
    UNIQUE (challenge_run_id, local_account_id, profile_template_revision_id),
    UNIQUE (challenge_run_uid, local_account_id),
    FOREIGN KEY (
        local_client_context_revision_id,
        local_client_context_id,
        local_account_id,
        selected_raid_season_revision_id
    ) REFERENCES lab_private_server.local_client_context_revision(
        local_client_context_revision_id,
        local_client_context_id,
        local_account_id,
        selected_raid_season_revision_id
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        selected_raid_season_revision_id,
        local_client_context_id,
        local_account_id,
        raid_season_directory_id,
        raid_snapshot_id
    ) REFERENCES lab_private_server.selected_raid_season_revision(
        selected_raid_season_revision_id,
        local_client_context_id,
        local_account_id,
        raid_season_directory_id,
        raid_snapshot_id
    ) ON DELETE RESTRICT,
    FOREIGN KEY (profile_template_revision_id, local_account_id, account_state_revision_id)
        REFERENCES lab_profile.profile_template_revision(
            profile_template_revision_id,
            local_account_id,
            account_state_revision_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (runtime_execution_profile_revision_id, local_account_id)
        REFERENCES lab_private_server.runtime_execution_profile_revision(
            runtime_execution_profile_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (combat_control_profile_revision_id, local_account_id)
        REFERENCES lab_private_server.combat_control_profile_revision(
            combat_control_profile_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (challenge_policy_activation_revision_id, challenge_operational_policy_id)
        REFERENCES lab_private_server.challenge_policy_activation_revision(
            challenge_policy_activation_revision_id,
            challenge_operational_policy_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (challenge_daily_state_id, local_account_id)
        REFERENCES lab_private_server.challenge_daily_state(
            challenge_daily_state_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (admission_daily_state_revision_id, challenge_daily_state_id)
        REFERENCES lab_private_server.challenge_daily_state_revision(
            challenge_daily_state_revision_id,
            challenge_daily_state_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        admission_daily_state_revision_id,
        admission_daily_state_content_sha256
    ) REFERENCES lab_private_server.challenge_daily_state_revision(
        challenge_daily_state_revision_id,
        content_sha256
    ) ON DELETE RESTRICT,
    CHECK (canonical_cumulative_damage = cumulative_damage::text),
    CHECK (opening_raid_day_key = lab_private_server.raid_day_key(opened_at_utc)),
    CHECK (
        (status = 'open'
            AND state_version = 1
            AND next_team_ordinal = 1
            AND active_team_ordinal IS NULL
            AND accepted_team_count = 0
            AND cumulative_damage = 0)
        OR (status = 'team_in_progress'
            AND next_team_ordinal IS NOT NULL
            AND active_team_ordinal = next_team_ordinal
            AND accepted_team_count = next_team_ordinal - 1)
        OR (status = 'team_result_accepted'
            AND next_team_ordinal IS NOT NULL
            AND active_team_ordinal = next_team_ordinal
            AND accepted_team_count = next_team_ordinal)
        OR (status = 'regroup_ready'
            AND next_team_ordinal = accepted_team_count + 1
            AND next_team_ordinal <= configured_team_count
            AND active_team_ordinal IS NULL
            AND accepted_team_count BETWEEN 1 AND configured_team_count - 1)
        OR (status = 'completed'
            AND next_team_ordinal IS NULL
            AND active_team_ordinal IS NULL
            AND accepted_team_count BETWEEN 1 AND configured_team_count
            AND final_result_uid IS NOT NULL
            AND abandonment_uid IS NULL
            AND abandon_reason_code IS NULL)
        OR (status = 'abandoned'
            AND next_team_ordinal IS NULL
            AND active_team_ordinal IS NULL
            AND abandonment_uid IS NOT NULL
            AND final_result_uid IS NULL
            AND abandon_reason_code IS NOT NULL)
    ),
    CHECK (
        status = 'abandoned'
        OR (abandonment_uid IS NULL AND abandon_reason_code IS NULL)
    ),
    CHECK (status = 'completed' OR final_result_uid IS NULL)
);

CREATE UNIQUE INDEX uq_private_server_active_run_per_account
    ON lab_private_server.challenge_run(local_account_id)
    WHERE status NOT IN ('completed', 'abandoned');

CREATE UNIQUE INDEX uq_private_server_active_run_per_context
    ON lab_private_server.challenge_run(local_client_context_id)
    WHERE status NOT IN ('completed', 'abandoned');

CREATE TABLE lab_private_server.challenge_run_team (
    challenge_run_id BIGINT NOT NULL,
    team_ordinal SMALLINT NOT NULL CHECK (team_ordinal BETWEEN 1 AND 5),
    local_account_id BIGINT NOT NULL,
    profile_template_revision_id BIGINT NOT NULL,
    squad_revision_id BIGINT NOT NULL,
    squad_revision_uid UUID NOT NULL,
    squad_content_sha256 BYTEA NOT NULL CHECK (octet_length(squad_content_sha256) = 32),
    team_content_sha256 BYTEA NOT NULL CHECK (octet_length(team_content_sha256) = 32),
    PRIMARY KEY (challenge_run_id, team_ordinal),
    UNIQUE (challenge_run_id, squad_revision_id),
    UNIQUE (challenge_run_id, squad_revision_uid),
    UNIQUE (challenge_run_id, team_ordinal, squad_revision_id),
    UNIQUE (challenge_run_id, team_ordinal, local_account_id),
    UNIQUE (
        challenge_run_id,
        team_ordinal,
        local_account_id,
        profile_template_revision_id
    ),
    UNIQUE (challenge_run_id, team_ordinal, team_content_sha256),
    FOREIGN KEY (challenge_run_id, local_account_id)
        REFERENCES lab_private_server.challenge_run(challenge_run_id, local_account_id)
        ON DELETE RESTRICT,
    FOREIGN KEY (challenge_run_id, local_account_id, profile_template_revision_id)
        REFERENCES lab_private_server.challenge_run(
            challenge_run_id,
            local_account_id,
            profile_template_revision_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (squad_revision_id, local_account_id)
        REFERENCES lab_profile.squad_revision(squad_revision_id, local_account_id)
        ON DELETE RESTRICT,
    FOREIGN KEY (squad_revision_uid)
        REFERENCES lab_profile.squad_revision(squad_revision_uid) ON DELETE RESTRICT,
    FOREIGN KEY (
        squad_revision_id,
        local_account_id,
        squad_revision_uid,
        squad_content_sha256
    ) REFERENCES lab_profile.squad_revision(
        squad_revision_id,
        local_account_id,
        squad_revision_uid,
        content_sha256
    ) ON DELETE RESTRICT,
    FOREIGN KEY (profile_template_revision_id, local_account_id)
        REFERENCES lab_profile.profile_template_revision(
            profile_template_revision_id,
            local_account_id
        ) ON DELETE RESTRICT
);

CREATE TABLE lab_private_server.challenge_run_team_member (
    challenge_run_id BIGINT NOT NULL,
    team_ordinal SMALLINT NOT NULL,
    local_account_id BIGINT NOT NULL,
    position SMALLINT NOT NULL CHECK (position BETWEEN 1 AND 5),
    profile_template_revision_id BIGINT NOT NULL,
    squad_revision_id BIGINT NOT NULL,
    character_entity_id BIGINT NOT NULL,
    character_build_id BIGINT NOT NULL,
    build_revision_id BIGINT NOT NULL,
    PRIMARY KEY (challenge_run_id, team_ordinal, position),
    UNIQUE (challenge_run_id, character_entity_id),
    UNIQUE (challenge_run_id, character_build_id),
    UNIQUE (challenge_run_id, build_revision_id),
    FOREIGN KEY (challenge_run_id, team_ordinal, squad_revision_id)
        REFERENCES lab_private_server.challenge_run_team(
            challenge_run_id,
            team_ordinal,
            squad_revision_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (challenge_run_id, team_ordinal, local_account_id)
        REFERENCES lab_private_server.challenge_run_team(
            challenge_run_id,
            team_ordinal,
            local_account_id
        ) ON DELETE RESTRICT,
    CONSTRAINT fk_challenge_run_team_member_profile_pin FOREIGN KEY (
        challenge_run_id,
        team_ordinal,
        local_account_id,
        profile_template_revision_id
    ) REFERENCES lab_private_server.challenge_run_team(
        challenge_run_id,
        team_ordinal,
        local_account_id,
        profile_template_revision_id
    ) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (
        squad_revision_id,
        position,
        character_build_id,
        build_revision_id
    ) REFERENCES lab_profile.squad_revision_member(
        squad_revision_id,
        position,
        character_build_id,
        build_revision_id
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        profile_template_revision_id,
        character_build_id,
        build_revision_id
    ) REFERENCES lab_profile.profile_template_revision_build(
        profile_template_revision_id,
        character_build_id,
        build_revision_id
    ) ON DELETE RESTRICT,
    FOREIGN KEY (build_revision_id, character_build_id, character_entity_id)
        REFERENCES lab_profile.character_build_revision(
            build_revision_id,
            character_build_id,
            character_entity_id
        ) ON DELETE RESTRICT
);

CREATE TABLE lab_private_server.challenge_team_damage_receipt (
    challenge_team_damage_receipt_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    challenge_team_damage_receipt_uid UUID NOT NULL UNIQUE CHECK (
        challenge_team_damage_receipt_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    challenge_run_id BIGINT NOT NULL,
    team_ordinal SMALLINT NOT NULL,
    local_account_id BIGINT NOT NULL,
    observation_source TEXT NOT NULL CHECK (
        observation_source = 'lab_harness_observation/v1'
    ),
    canonical_damage TEXT NOT NULL CHECK (
        canonical_damage ~ '^(0|[1-9][0-9]{0,77})$'
    ),
    damage_value NUMERIC(78, 0) NOT NULL CHECK (damage_value >= 0),
    canonical_cumulative_damage TEXT NOT NULL CHECK (
        canonical_cumulative_damage ~ '^(0|[1-9][0-9]{0,77})$'
    ),
    cumulative_damage_value NUMERIC(78, 0) NOT NULL CHECK (
        cumulative_damage_value >= damage_value
    ),
    telemetry_contract_id TEXT NOT NULL CHECK (
        telemetry_contract_id = 'nll/battle-frame-telemetry/v1'
    ),
    telemetry_sha256 BYTEA NOT NULL CHECK (octet_length(telemetry_sha256) = 32),
    render_frame_count BIGINT NOT NULL CHECK (render_frame_count >= 0),
    behavior_tick_count BIGINT NOT NULL CHECK (behavior_tick_count >= 0),
    fixed_update_count BIGINT NOT NULL CHECK (fixed_update_count >= 0),
    wall_clock_microseconds BIGINT NOT NULL CHECK (wall_clock_microseconds >= 0),
    frame_time_median_milliseconds NUMERIC(20, 3) NOT NULL CHECK (
        frame_time_median_milliseconds >= 0
    ),
    frame_time_p95_milliseconds NUMERIC(20, 3) NOT NULL CHECK (
        frame_time_p95_milliseconds >= frame_time_median_milliseconds
    ),
    frame_time_p99_milliseconds NUMERIC(20, 3) NOT NULL CHECK (
        frame_time_p99_milliseconds >= frame_time_p95_milliseconds
    ),
    dropped_frame_count BIGINT NOT NULL CHECK (dropped_frame_count >= 0),
    stalled_frame_count BIGINT NOT NULL CHECK (stalled_frame_count >= 0),
    telemetry_warning_count SMALLINT NOT NULL CHECK (
        telemetry_warning_count BETWEEN 0 AND 64
    ),
    segment_count SMALLINT NOT NULL CHECK (segment_count BETWEEN 1 AND 64),
    warning_count SMALLINT NOT NULL CHECK (warning_count BETWEEN 0 AND 64),
    receipt_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(receipt_sha256) = 32),
    observed_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (challenge_run_id, team_ordinal),
    UNIQUE (challenge_team_damage_receipt_id, challenge_run_id, team_ordinal),
    UNIQUE (challenge_team_damage_receipt_id, receipt_sha256),
    UNIQUE (
        challenge_team_damage_receipt_id,
        challenge_run_id,
        team_ordinal,
        local_account_id
    ),
    FOREIGN KEY (challenge_run_id, team_ordinal, local_account_id)
        REFERENCES lab_private_server.challenge_run_team(
            challenge_run_id,
            team_ordinal,
            local_account_id
        ) ON DELETE RESTRICT,
    CHECK (canonical_damage = damage_value::text),
    CHECK (canonical_cumulative_damage = cumulative_damage_value::text)
);

CREATE TABLE lab_private_server.challenge_team_damage_warning (
    challenge_team_damage_receipt_id BIGINT NOT NULL
        REFERENCES lab_private_server.challenge_team_damage_receipt(
            challenge_team_damage_receipt_id
        ) ON DELETE RESTRICT,
    ordinal SMALLINT NOT NULL CHECK (ordinal BETWEEN 1 AND 64),
    warning_code TEXT NOT NULL CHECK (warning_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    PRIMARY KEY (challenge_team_damage_receipt_id, ordinal),
    UNIQUE (challenge_team_damage_receipt_id, warning_code)
);

CREATE TABLE lab_private_server.challenge_team_telemetry_warning (
    challenge_team_damage_receipt_id BIGINT NOT NULL
        REFERENCES lab_private_server.challenge_team_damage_receipt(
            challenge_team_damage_receipt_id
        ) ON DELETE RESTRICT,
    ordinal SMALLINT NOT NULL CHECK (ordinal BETWEEN 1 AND 64),
    warning_code TEXT NOT NULL CHECK (warning_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    PRIMARY KEY (challenge_team_damage_receipt_id, ordinal),
    UNIQUE (challenge_team_damage_receipt_id, warning_code)
);

CREATE TABLE lab_private_server.challenge_execution_segment (
    challenge_execution_segment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    challenge_team_damage_receipt_id BIGINT NOT NULL,
    challenge_run_id BIGINT NOT NULL,
    team_ordinal SMALLINT NOT NULL,
    local_account_id BIGINT NOT NULL,
    segment_ordinal SMALLINT NOT NULL CHECK (segment_ordinal BETWEEN 1 AND 64),
    runtime_execution_profile_revision_id BIGINT NOT NULL,
    combat_control_profile_revision_id BIGINT NOT NULL,
    start_render_frame BIGINT NOT NULL CHECK (start_render_frame >= 0),
    end_render_frame BIGINT NOT NULL CHECK (end_render_frame >= start_render_frame),
    start_behavior_tick BIGINT NOT NULL CHECK (start_behavior_tick >= 0),
    end_behavior_tick BIGINT NOT NULL CHECK (end_behavior_tick >= start_behavior_tick),
    start_fixed_update BIGINT NOT NULL CHECK (start_fixed_update >= 0),
    end_fixed_update BIGINT NOT NULL CHECK (end_fixed_update >= start_fixed_update),
    start_wall_clock_microseconds BIGINT NOT NULL CHECK (
        start_wall_clock_microseconds >= 0
    ),
    end_wall_clock_microseconds BIGINT NOT NULL CHECK (
        end_wall_clock_microseconds >= start_wall_clock_microseconds
    ),
    canonical_start_damage TEXT NOT NULL CHECK (
        canonical_start_damage ~ '^(0|[1-9][0-9]{0,77})$'
    ),
    start_damage NUMERIC(78, 0) NOT NULL CHECK (start_damage >= 0),
    canonical_end_damage TEXT NOT NULL CHECK (
        canonical_end_damage ~ '^(0|[1-9][0-9]{0,77})$'
    ),
    end_damage NUMERIC(78, 0) NOT NULL CHECK (end_damage >= start_damage),
    UNIQUE (challenge_team_damage_receipt_id, segment_ordinal),
    UNIQUE (challenge_run_id, team_ordinal, segment_ordinal),
    FOREIGN KEY (
        challenge_team_damage_receipt_id,
        challenge_run_id,
        team_ordinal,
        local_account_id
    ) REFERENCES lab_private_server.challenge_team_damage_receipt(
        challenge_team_damage_receipt_id,
        challenge_run_id,
        team_ordinal,
        local_account_id
    ) ON DELETE RESTRICT,
    FOREIGN KEY (runtime_execution_profile_revision_id, local_account_id)
        REFERENCES lab_private_server.runtime_execution_profile_revision(
            runtime_execution_profile_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (combat_control_profile_revision_id, local_account_id)
        REFERENCES lab_private_server.combat_control_profile_revision(
            combat_control_profile_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    CHECK (canonical_start_damage = start_damage::text),
    CHECK (canonical_end_damage = end_damage::text)
);

-- A challenge run is an immutable revision aggregate. The mutable columns on
-- challenge_run are a transactionally validated current-head projection used
-- only for the active-run uniqueness constraint and efficient admission/CAS.
CREATE TABLE lab_private_server.challenge_run_revision (
    challenge_run_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    challenge_run_revision_uid UUID NOT NULL UNIQUE CHECK (
        challenge_run_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    challenge_run_id BIGINT NOT NULL,
    challenge_run_uid UUID NOT NULL,
    local_account_id BIGINT NOT NULL,
    revision_number INTEGER NOT NULL CHECK (revision_number >= 1),
    previous_challenge_run_revision_id BIGINT,
    status TEXT NOT NULL CHECK (status IN (
        'open', 'team_in_progress', 'team_result_accepted', 'regroup_ready',
        'completed', 'abandoned'
    )),
    next_team_ordinal SMALLINT CHECK (next_team_ordinal BETWEEN 1 AND 5),
    active_team_ordinal SMALLINT CHECK (active_team_ordinal BETWEEN 1 AND 5),
    accepted_team_count SMALLINT NOT NULL CHECK (accepted_team_count BETWEEN 0 AND 5),
    canonical_cumulative_damage TEXT NOT NULL CHECK (
        canonical_cumulative_damage ~ '^(0|[1-9][0-9]{0,77})$'
    ),
    cumulative_damage NUMERIC(78, 0) NOT NULL CHECK (cumulative_damage >= 0),
    final_result_uid UUID CHECK (
        final_result_uid IS NULL
        OR final_result_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    abandonment_uid UUID CHECK (
        abandonment_uid IS NULL
        OR abandonment_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    abandon_reason_code TEXT CHECK (
        abandon_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    opened_at_utc TIMESTAMPTZ NOT NULL,
    updated_at_utc TIMESTAMPTZ NOT NULL CHECK (updated_at_utc >= opened_at_utc),
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    UNIQUE (challenge_run_id, revision_number),
    UNIQUE (challenge_run_id, challenge_run_revision_uid),
    UNIQUE (challenge_run_revision_id, challenge_run_id),
    UNIQUE (challenge_run_revision_id, challenge_run_id, content_sha256),
    UNIQUE (
        challenge_run_revision_id,
        challenge_run_revision_uid,
        content_sha256
    ),
    FOREIGN KEY (challenge_run_id, local_account_id)
        REFERENCES lab_private_server.challenge_run(challenge_run_id, local_account_id)
        ON DELETE RESTRICT,
    FOREIGN KEY (challenge_run_uid, local_account_id)
        REFERENCES lab_private_server.challenge_run(challenge_run_uid, local_account_id)
        ON DELETE RESTRICT,
    FOREIGN KEY (previous_challenge_run_revision_id, challenge_run_id)
        REFERENCES lab_private_server.challenge_run_revision(
            challenge_run_revision_id,
            challenge_run_id
        ) ON DELETE RESTRICT,
    CHECK (canonical_cumulative_damage = cumulative_damage::text),
    CHECK (
        (revision_number = 1 AND previous_challenge_run_revision_id IS NULL)
        OR (revision_number > 1 AND previous_challenge_run_revision_id IS NOT NULL)
    ),
    CHECK (
        (status = 'open'
            AND revision_number = 1
            AND next_team_ordinal = 1
            AND active_team_ordinal IS NULL
            AND accepted_team_count = 0
            AND cumulative_damage = 0)
        OR (status = 'team_in_progress'
            AND next_team_ordinal IS NOT NULL
            AND active_team_ordinal = next_team_ordinal
            AND accepted_team_count = next_team_ordinal - 1)
        OR (status = 'team_result_accepted'
            AND next_team_ordinal IS NOT NULL
            AND active_team_ordinal = next_team_ordinal
            AND accepted_team_count = next_team_ordinal)
        OR (status = 'regroup_ready'
            AND next_team_ordinal = accepted_team_count + 1
            AND active_team_ordinal IS NULL
            AND accepted_team_count BETWEEN 1 AND 4)
        OR (status = 'completed'
            AND next_team_ordinal IS NULL
            AND active_team_ordinal IS NULL
            AND accepted_team_count BETWEEN 1 AND 5
            AND final_result_uid IS NOT NULL)
        OR (status = 'abandoned'
            AND next_team_ordinal IS NULL
            AND active_team_ordinal IS NULL
            AND final_result_uid IS NULL
            AND abandonment_uid IS NOT NULL
            AND abandon_reason_code IS NOT NULL)
    ),
    CHECK (status = 'completed' OR final_result_uid IS NULL),
    CHECK (
        status = 'abandoned'
        OR (abandonment_uid IS NULL AND abandon_reason_code IS NULL)
    )
);

CREATE TABLE lab_private_server.challenge_run_revision_attempt (
    challenge_run_revision_id BIGINT NOT NULL,
    challenge_run_id BIGINT NOT NULL,
    attempt_ordinal SMALLINT NOT NULL CHECK (attempt_ordinal BETWEEN 1 AND 5),
    team_ordinal SMALLINT NOT NULL CHECK (team_ordinal BETWEEN 1 AND 5),
    team_content_sha256 BYTEA NOT NULL CHECK (octet_length(team_content_sha256) = 32),
    entered_at_utc TIMESTAMPTZ NOT NULL,
    challenge_team_damage_receipt_id BIGINT,
    receipt_sha256 BYTEA CHECK (
        receipt_sha256 IS NULL OR octet_length(receipt_sha256) = 32
    ),
    PRIMARY KEY (challenge_run_revision_id, attempt_ordinal),
    UNIQUE (challenge_run_revision_id, team_ordinal),
    FOREIGN KEY (challenge_run_revision_id, challenge_run_id)
        REFERENCES lab_private_server.challenge_run_revision(
            challenge_run_revision_id,
            challenge_run_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (challenge_run_id, team_ordinal, team_content_sha256)
        REFERENCES lab_private_server.challenge_run_team(
            challenge_run_id,
            team_ordinal,
            team_content_sha256
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        challenge_team_damage_receipt_id,
        challenge_run_id,
        team_ordinal
    ) REFERENCES lab_private_server.challenge_team_damage_receipt(
        challenge_team_damage_receipt_id,
        challenge_run_id,
        team_ordinal
    ) ON DELETE RESTRICT,
    FOREIGN KEY (challenge_team_damage_receipt_id, receipt_sha256)
        REFERENCES lab_private_server.challenge_team_damage_receipt(
            challenge_team_damage_receipt_id,
            receipt_sha256
        ) ON DELETE RESTRICT,
    CHECK (
        (challenge_team_damage_receipt_id IS NULL) = (receipt_sha256 IS NULL)
    ),
    CHECK (attempt_ordinal = team_ordinal)
);

CREATE TABLE lab_private_server.challenge_run_result (
    challenge_run_result_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    challenge_run_result_uid UUID NOT NULL UNIQUE CHECK (
        challenge_run_result_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    challenge_run_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_private_server.challenge_run(challenge_run_id) ON DELETE RESTRICT,
    accepted_team_count SMALLINT NOT NULL CHECK (accepted_team_count BETWEEN 1 AND 5),
    canonical_total_damage TEXT NOT NULL CHECK (
        canonical_total_damage ~ '^(0|[1-9][0-9]{0,77})$'
    ),
    total_damage NUMERIC(78, 0) NOT NULL CHECK (total_damage >= 0),
    result_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(result_sha256) = 32),
    completed_at_utc TIMESTAMPTZ NOT NULL,
    CHECK (canonical_total_damage = total_damage::text)
);

ALTER TABLE lab_private_server.challenge_run
    ADD CONSTRAINT fk_challenge_run_current_revision
    FOREIGN KEY (current_challenge_run_revision_id, challenge_run_id)
    REFERENCES lab_private_server.challenge_run_revision(
        challenge_run_revision_id,
        challenge_run_id
    ) DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE lab_private_server.challenge_run
    ADD CONSTRAINT fk_challenge_run_final_result_uid
    FOREIGN KEY (final_result_uid)
    REFERENCES lab_private_server.challenge_run_result(challenge_run_result_uid)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE lab_private_server.challenge_run_revision
    ADD CONSTRAINT fk_challenge_run_revision_final_result_uid
    FOREIGN KEY (final_result_uid)
    REFERENCES lab_private_server.challenge_run_result(challenge_run_result_uid)
    DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE lab_private_server.challenge_run_operation (
    challenge_run_operation_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_uid UUID NOT NULL UNIQUE CHECK (
        operation_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    operation_kind TEXT NOT NULL CHECK (operation_kind IN (
        'open_run', 'enter_team', 'accept_team_damage', 'regroup',
        'close_run', 'abandon_run', 'recover_stranded_run'
    )),
    request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256) = 32),
    challenge_run_uid UUID NOT NULL
        REFERENCES lab_private_server.challenge_run(challenge_run_uid)
        DEFERRABLE INITIALLY DEFERRED,
    expected_run_revision_uid UUID
        REFERENCES lab_private_server.challenge_run_revision(challenge_run_revision_uid)
        ON DELETE RESTRICT,
    expected_state_version INTEGER,
    result_challenge_run_revision_id BIGINT NOT NULL,
    result_run_revision_uid UUID NOT NULL,
    result_run_content_sha256 BYTEA NOT NULL CHECK (
        octet_length(result_run_content_sha256) = 32
    ),
    result_state_version INTEGER NOT NULL CHECK (result_state_version >= 1),
    result_status TEXT NOT NULL CHECK (result_status IN (
        'open', 'team_in_progress', 'team_result_accepted', 'regroup_ready',
        'completed', 'abandoned'
    )),
    team_ordinal SMALLINT CHECK (team_ordinal BETWEEN 1 AND 5),
    challenge_team_damage_receipt_id BIGINT
        REFERENCES lab_private_server.challenge_team_damage_receipt(
            challenge_team_damage_receipt_id
        ) ON DELETE RESTRICT,
    challenge_run_result_id BIGINT
        REFERENCES lab_private_server.challenge_run_result(challenge_run_result_id)
        ON DELETE RESTRICT,
    consumed_daily_attempt BOOLEAN NOT NULL,
    result_daily_state_revision_id BIGINT
        REFERENCES lab_private_server.challenge_daily_state_revision(
            challenge_daily_state_revision_id
        ) ON DELETE RESTRICT,
    abandonment_uid UUID,
    abandon_reason_code TEXT CHECK (
        abandon_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    requesting_local_account_id BIGINT
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    requesting_local_client_context_revision_id BIGINT,
    completed_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (challenge_run_uid, result_state_version),
    FOREIGN KEY (
        result_challenge_run_revision_id,
        result_run_revision_uid,
        result_run_content_sha256
    ) REFERENCES lab_private_server.challenge_run_revision(
        challenge_run_revision_id,
        challenge_run_revision_uid,
        content_sha256
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        requesting_local_client_context_revision_id,
        requesting_local_account_id
    ) REFERENCES lab_private_server.local_client_context_revision(
        local_client_context_revision_id,
        local_account_id
    ) ON DELETE RESTRICT,
    CHECK (
        (operation_kind IN ('abandon_run', 'recover_stranded_run')) =
        (abandonment_uid IS NOT NULL AND abandon_reason_code IS NOT NULL)
    ),
    CHECK (
        (operation_kind = 'recover_stranded_run') =
        (requesting_local_account_id IS NOT NULL
            AND requesting_local_client_context_revision_id IS NOT NULL
            AND abandon_reason_code = 'owning_session_inactive_recovery')
    ),
    CHECK (
        operation_kind = 'recover_stranded_run'
        OR (requesting_local_account_id IS NULL
            AND requesting_local_client_context_revision_id IS NULL)
    ),
    CHECK (
        operation_kind <> 'abandon_run'
        OR abandon_reason_code <> 'owning_session_inactive_recovery'
    ),
    CHECK (
        consumed_daily_attempt = (result_daily_state_revision_id IS NOT NULL)
    ),
    CHECK (
        (operation_kind = 'open_run'
            AND expected_run_revision_uid IS NULL
            AND expected_state_version IS NULL
            AND result_state_version = 1
            AND result_status = 'open'
            AND team_ordinal IS NULL
            AND challenge_team_damage_receipt_id IS NULL
            AND challenge_run_result_id IS NULL)
        OR (operation_kind = 'enter_team'
            AND expected_run_revision_uid IS NOT NULL
            AND expected_state_version IS NOT NULL
            AND result_state_version = expected_state_version + 1
            AND result_status = 'team_in_progress'
            AND team_ordinal IS NOT NULL
            AND challenge_team_damage_receipt_id IS NULL
            AND challenge_run_result_id IS NULL)
        OR (operation_kind = 'accept_team_damage'
            AND expected_run_revision_uid IS NOT NULL
            AND expected_state_version IS NOT NULL
            AND result_state_version = expected_state_version + 1
            AND result_status = 'team_result_accepted'
            AND team_ordinal IS NOT NULL
            AND challenge_team_damage_receipt_id IS NOT NULL
            AND challenge_run_result_id IS NULL)
        OR (operation_kind = 'regroup'
            AND expected_run_revision_uid IS NOT NULL
            AND expected_state_version IS NOT NULL
            AND result_state_version = expected_state_version + 1
            AND result_status = 'regroup_ready'
            AND team_ordinal IS NOT NULL
            AND challenge_team_damage_receipt_id IS NULL
            AND challenge_run_result_id IS NULL)
        OR (operation_kind = 'close_run'
            AND expected_run_revision_uid IS NOT NULL
            AND expected_state_version IS NOT NULL
            AND result_state_version = expected_state_version + 1
            AND result_status = 'completed'
            AND team_ordinal IS NULL
            AND challenge_team_damage_receipt_id IS NULL
            AND challenge_run_result_id IS NOT NULL
            AND abandonment_uid IS NULL
            AND abandon_reason_code IS NULL)
        OR (operation_kind = 'abandon_run'
            AND expected_run_revision_uid IS NOT NULL
            AND expected_state_version IS NOT NULL
            AND result_state_version = expected_state_version + 1
            AND result_status = 'abandoned'
            AND team_ordinal IS NULL
            AND challenge_team_damage_receipt_id IS NULL
            AND challenge_run_result_id IS NULL
            AND abandonment_uid IS NOT NULL
            AND abandon_reason_code IS NOT NULL)
        OR (operation_kind = 'recover_stranded_run'
            AND expected_run_revision_uid IS NOT NULL
            AND expected_state_version IS NOT NULL
            AND result_state_version = expected_state_version + 1
            AND result_status = 'abandoned'
            AND team_ordinal IS NULL
            AND challenge_team_damage_receipt_id IS NULL
            AND challenge_run_result_id IS NULL
            AND abandonment_uid IS NOT NULL
            AND abandon_reason_code = 'owning_session_inactive_recovery')
    )
);

ALTER TABLE lab_private_server.challenge_run
    ADD CONSTRAINT fk_challenge_run_last_operation
    FOREIGN KEY (last_operation_uid)
    REFERENCES lab_private_server.challenge_run_operation(operation_uid)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE lab_private_server.challenge_daily_state_revision
    ADD CONSTRAINT fk_challenge_daily_consumption_operation
    FOREIGN KEY (consumption_operation_uid)
    REFERENCES lab_private_server.challenge_run_operation(operation_uid)
    DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE lab_private_server.private_server_write_operation (
    private_server_write_operation_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_uid UUID NOT NULL UNIQUE CHECK (
        operation_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    operation_kind TEXT NOT NULL CHECK (operation_kind IN (
        'publish_application_build', 'publish_client_feature_manifest_v2',
        'publish_capability_manifest', 'publish_season_directory',
        'publish_operational_policy', 'schedule_operational_policy',
        'save_runtime_profile', 'save_control_profile',
        'open_client_context', 'connect_client_context', 'enter_lobby',
        'select_raid_season'
    )),
    request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256) = 32),
    local_account_id BIGINT
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    expected_revision_uid UUID,
    result_entity_uid UUID NOT NULL CHECK (
        result_entity_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    result_revision_uid UUID,
    result_content_sha256 BYTEA NOT NULL CHECK (octet_length(result_content_sha256) = 32),
    completed_at_utc TIMESTAMPTZ NOT NULL,
    CHECK (
        (operation_kind IN (
            'publish_application_build', 'publish_client_feature_manifest_v2',
            'publish_capability_manifest', 'publish_season_directory',
            'publish_operational_policy'
        )
            AND local_account_id IS NULL
            AND result_revision_uid IS NULL
            AND expected_revision_uid IS NULL)
        OR (operation_kind = 'schedule_operational_policy'
            AND local_account_id IS NULL
            AND result_revision_uid IS NOT NULL)
        OR (operation_kind IN (
            'save_runtime_profile', 'save_control_profile',
            'open_client_context', 'connect_client_context', 'enter_lobby',
            'select_raid_season'
        )
            AND local_account_id IS NOT NULL
            AND result_revision_uid IS NOT NULL)
    )
);

-- The replay ledger is authoritative only when its sealed result resolves to
-- the exact immutable entity/revision it claims.  `expected_revision_uid =
-- result_revision_uid` is the explicit same-content no-op form for revisioned
-- writes. Policy publication has no revision row, so multiple exact operations
-- may point to the same immutable UID/content while expected_revision_uid stays
-- null. Every other shape represents a newly materialized result.
CREATE FUNCTION lab_private_server.validate_private_server_write_operation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    binding_valid BOOLEAN := FALSE;
BEGIN
    CASE NEW.operation_kind
        WHEN 'publish_application_build' THEN
            SELECT EXISTS (
                SELECT 1
                  FROM lab_private_server.application_build build
                 WHERE build.application_build_uid = NEW.result_entity_uid
                   AND build.content_sha256 = NEW.result_content_sha256
                   AND build.published_at_utc = NEW.completed_at_utc
            ) INTO binding_valid;
        WHEN 'publish_client_feature_manifest_v2' THEN
            SELECT EXISTS (
                SELECT 1
                  FROM lab_local_game.client_feature_manifest manifest
                 WHERE manifest.client_feature_manifest_uid = NEW.result_entity_uid
                   AND manifest.content_sha256 = NEW.result_content_sha256
                   AND manifest.contract_version = 'nll/client-feature-manifest/v2'
                   AND manifest.published_at_utc = NEW.completed_at_utc
            ) INTO binding_valid;
        WHEN 'publish_capability_manifest' THEN
            SELECT EXISTS (
                SELECT 1
                  FROM lab_private_server.capability_manifest manifest
                 WHERE manifest.capability_manifest_uid = NEW.result_entity_uid
                   AND manifest.content_sha256 = NEW.result_content_sha256
                   AND manifest.published_at_utc = NEW.completed_at_utc
            ) INTO binding_valid;
        WHEN 'publish_season_directory' THEN
            SELECT EXISTS (
                SELECT 1
                  FROM lab_private_server.raid_season_directory directory
                 WHERE directory.raid_season_directory_uid = NEW.result_entity_uid
                   AND directory.content_sha256 = NEW.result_content_sha256
                   AND directory.published_at_utc = NEW.completed_at_utc
            ) INTO binding_valid;
        WHEN 'publish_operational_policy' THEN
            SELECT EXISTS (
                SELECT 1
                  FROM lab_private_server.challenge_operational_policy policy
                 WHERE policy.challenge_operational_policy_uid =
                       NEW.result_entity_uid
                   AND policy.content_sha256 = NEW.result_content_sha256
                   AND NEW.expected_revision_uid IS NULL
                   AND NEW.completed_at_utc >= policy.published_at_utc
            ) INTO binding_valid;
        WHEN 'schedule_operational_policy' THEN
            SELECT EXISTS (
                SELECT 1
                  FROM lab_private_server.challenge_policy_activation_revision revision
                  JOIN lab_private_server.challenge_policy_state state
                    ON state.latest_scheduled_activation_revision_id =
                       revision.challenge_policy_activation_revision_id
                  LEFT JOIN lab_private_server.challenge_policy_activation_revision previous
                    ON previous.challenge_policy_activation_revision_id =
                       revision.previous_activation_revision_id
                 WHERE revision.challenge_policy_activation_uid =
                       NEW.result_entity_uid
                   AND revision.challenge_policy_activation_revision_uid =
                       NEW.result_revision_uid
                   AND revision.content_sha256 = NEW.result_content_sha256
                   AND (
                       (NEW.expected_revision_uid =
                            revision.challenge_policy_activation_revision_uid
                           AND NEW.completed_at_utc >= revision.scheduled_at_utc)
                       OR (revision.revision_number > 1
                           AND NEW.expected_revision_uid =
                               previous.challenge_policy_activation_revision_uid
                           AND NEW.completed_at_utc = revision.scheduled_at_utc)
                   )
            ) INTO binding_valid;
        WHEN 'save_runtime_profile' THEN
            SELECT EXISTS (
                SELECT 1
                  FROM lab_private_server.runtime_execution_profile_revision revision
                  JOIN lab_private_server.runtime_execution_profile profile
                    ON profile.runtime_execution_profile_id =
                       revision.runtime_execution_profile_id
                   AND profile.current_runtime_execution_profile_revision_id =
                       revision.runtime_execution_profile_revision_id
                  LEFT JOIN lab_private_server.runtime_execution_profile_revision previous
                    ON previous.runtime_execution_profile_revision_id =
                       revision.previous_runtime_execution_profile_revision_id
                 WHERE profile.runtime_execution_profile_uid = NEW.result_entity_uid
                   AND revision.runtime_execution_profile_revision_uid =
                       NEW.result_revision_uid
                   AND revision.local_account_id = NEW.local_account_id
                   AND revision.content_sha256 = NEW.result_content_sha256
                   AND NEW.completed_at_utc >= revision.materialized_at_utc
                   AND (
                       (revision.revision_number = 1
                           AND NEW.expected_revision_uid IS NULL)
                       OR NEW.expected_revision_uid =
                           revision.runtime_execution_profile_revision_uid
                       OR (revision.revision_number > 1
                           AND NEW.expected_revision_uid =
                               previous.runtime_execution_profile_revision_uid)
                   )
            ) INTO binding_valid;
        WHEN 'save_control_profile' THEN
            SELECT EXISTS (
                SELECT 1
                  FROM lab_private_server.combat_control_profile_revision revision
                  JOIN lab_private_server.combat_control_profile profile
                    ON profile.combat_control_profile_id =
                       revision.combat_control_profile_id
                   AND profile.current_combat_control_profile_revision_id =
                       revision.combat_control_profile_revision_id
                  LEFT JOIN lab_private_server.combat_control_profile_revision previous
                    ON previous.combat_control_profile_revision_id =
                       revision.previous_combat_control_profile_revision_id
                 WHERE profile.combat_control_profile_uid = NEW.result_entity_uid
                   AND revision.combat_control_profile_revision_uid =
                       NEW.result_revision_uid
                   AND revision.local_account_id = NEW.local_account_id
                   AND revision.content_sha256 = NEW.result_content_sha256
                   AND NEW.completed_at_utc >= revision.materialized_at_utc
                   AND (
                       (revision.revision_number = 1
                           AND NEW.expected_revision_uid IS NULL)
                       OR NEW.expected_revision_uid =
                           revision.combat_control_profile_revision_uid
                       OR (revision.revision_number > 1
                           AND NEW.expected_revision_uid =
                               previous.combat_control_profile_revision_uid)
                   )
            ) INTO binding_valid;
        WHEN 'open_client_context' THEN
            SELECT EXISTS (
                SELECT 1
                  FROM lab_private_server.local_client_context_revision revision
                  JOIN lab_private_server.local_client_context context
                    ON context.local_client_context_id =
                       revision.local_client_context_id
                   AND context.current_local_client_context_revision_id =
                       revision.local_client_context_revision_id
                 WHERE context.local_client_context_uid = NEW.result_entity_uid
                   AND revision.local_client_context_revision_uid =
                       NEW.result_revision_uid
                   AND revision.local_account_id = NEW.local_account_id
                   AND revision.content_sha256 = NEW.result_content_sha256
                   AND revision.revision_number = 1
                   AND revision.previous_local_client_context_revision_id IS NULL
                   AND revision.stage = 'loading'
                   AND NEW.expected_revision_uid IS NULL
                   AND revision.materialized_at_utc = NEW.completed_at_utc
            ) INTO binding_valid;
        WHEN 'connect_client_context', 'enter_lobby',
             'select_raid_season' THEN
            SELECT EXISTS (
                SELECT 1
                  FROM lab_private_server.local_client_context_revision revision
                  JOIN lab_private_server.local_client_context context
                    ON context.local_client_context_id =
                       revision.local_client_context_id
                   AND context.current_local_client_context_revision_id =
                       revision.local_client_context_revision_id
                  LEFT JOIN lab_private_server.local_client_context_revision previous
                    ON previous.local_client_context_revision_id =
                       revision.previous_local_client_context_revision_id
                 WHERE context.local_client_context_uid = NEW.result_entity_uid
                   AND revision.local_client_context_revision_uid =
                       NEW.result_revision_uid
                   AND revision.local_account_id = NEW.local_account_id
                   AND revision.content_sha256 = NEW.result_content_sha256
                   AND NEW.completed_at_utc >= revision.materialized_at_utc
                   AND (
                       (NEW.operation_kind = 'select_raid_season'
                           AND NEW.expected_revision_uid =
                               revision.local_client_context_revision_uid)
                       OR (NEW.expected_revision_uid =
                               previous.local_client_context_revision_uid
                           AND NEW.completed_at_utc = revision.materialized_at_utc)
                   )
                   AND (
                       (NEW.operation_kind = 'connect_client_context'
                           AND revision.stage = 'local_connected'
                           AND previous.stage = 'loading')
                       OR (NEW.operation_kind = 'enter_lobby'
                           AND revision.stage = 'lobby_ready'
                           AND previous.stage = 'local_connected')
                       OR (NEW.operation_kind = 'select_raid_season'
                           AND revision.stage = 'lobby_ready'
                           AND (
                               NEW.expected_revision_uid =
                                   revision.local_client_context_revision_uid
                               OR (previous.stage = 'lobby_ready'
                                   AND revision.selected_raid_season_revision_id
                                       IS DISTINCT FROM
                                       previous.selected_raid_season_revision_id)
                           ))
                   )
            ) INTO binding_valid;
    END CASE;

    IF NOT binding_valid THEN
        RAISE EXCEPTION 'private_server_write_operation_result_mismatch';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_private_server_write_operation
AFTER INSERT OR UPDATE ON lab_private_server.private_server_write_operation
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.validate_private_server_write_operation();

CREATE FUNCTION lab_private_server.validate_published_write_operation_inverse()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    entity_uid UUID := (to_jsonb(NEW) ->> TG_ARGV[1])::uuid;
    content_sha256 BYTEA := (to_jsonb(NEW) ->> TG_ARGV[2])::bytea;
    published_at_utc TIMESTAMPTZ :=
        (to_jsonb(NEW) ->> TG_ARGV[3])::timestamptz;
    matching_operation_count INTEGER;
BEGIN
    SELECT count(*) INTO matching_operation_count
          FROM lab_private_server.private_server_write_operation operation
         WHERE operation.operation_kind = TG_ARGV[0]
           AND operation.expected_revision_uid IS NULL
           AND operation.result_entity_uid = entity_uid
           AND operation.result_revision_uid IS NULL
           AND operation.result_content_sha256 = content_sha256
           AND operation.completed_at_utc = published_at_utc;
    IF (TG_ARGV[0] = 'publish_operational_policy'
            AND matching_operation_count < 1)
       OR (TG_ARGV[0] <> 'publish_operational_policy'
            AND matching_operation_count <> 1) THEN
        RAISE EXCEPTION 'private_server_write_operation_inverse_missing';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_policy_write_operation_inverse
AFTER INSERT ON lab_private_server.challenge_operational_policy
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.validate_published_write_operation_inverse(
        'publish_operational_policy', 'challenge_operational_policy_uid',
        'content_sha256', 'published_at_utc'
    );

CREATE CONSTRAINT TRIGGER trg_validate_capability_write_operation_inverse
AFTER INSERT ON lab_private_server.capability_manifest
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.validate_published_write_operation_inverse(
        'publish_capability_manifest', 'capability_manifest_uid',
        'content_sha256', 'published_at_utc'
    );

CREATE CONSTRAINT TRIGGER trg_validate_application_write_operation_inverse
AFTER INSERT ON lab_private_server.application_build
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.validate_published_write_operation_inverse(
        'publish_application_build', 'application_build_uid',
        'content_sha256', 'published_at_utc'
    );

CREATE FUNCTION lab_private_server.validate_application_selection_write_operation_inverse()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    matching_operation_count INTEGER;
    matching_selection_count INTEGER;
BEGIN
    SELECT count(*) INTO matching_operation_count
      FROM lab_private_server.application_build build
      JOIN lab_private_server.private_server_write_operation operation
        ON operation.operation_kind = 'publish_application_build'
       AND operation.local_account_id IS NULL
       AND operation.expected_revision_uid IS NULL
       AND operation.result_entity_uid = build.application_build_uid
       AND operation.result_revision_uid IS NULL
       AND operation.result_content_sha256 = build.content_sha256
       AND operation.completed_at_utc = NEW.selected_at_utc
     WHERE build.application_build_id = NEW.application_build_id;
    SELECT count(*) INTO matching_selection_count
      FROM lab_private_server.application_build_selection_revision selection
     WHERE selection.application_build_id = NEW.application_build_id;
    IF matching_operation_count <> 1
       OR matching_selection_count <> 1 THEN
        RAISE EXCEPTION 'private_server_write_operation_inverse_missing';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_application_selection_write_operation_inverse
AFTER INSERT ON lab_private_server.application_build_selection_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.validate_application_selection_write_operation_inverse();

CREATE CONSTRAINT TRIGGER trg_validate_directory_write_operation_inverse
AFTER INSERT ON lab_private_server.raid_season_directory
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.validate_published_write_operation_inverse(
        'publish_season_directory', 'raid_season_directory_uid',
        'content_sha256', 'published_at_utc'
    );

CREATE CONSTRAINT TRIGGER trg_validate_feature_v2_write_operation_inverse
AFTER INSERT ON lab_local_game.client_feature_manifest
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
WHEN (NEW.contract_version = 'nll/client-feature-manifest/v2')
EXECUTE FUNCTION lab_private_server.validate_published_write_operation_inverse(
    'publish_client_feature_manifest_v2', 'client_feature_manifest_uid',
    'content_sha256', 'published_at_utc'
);

CREATE FUNCTION lab_private_server.validate_profile_write_operation_inverse()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    required_operation_kind TEXT := TG_ARGV[0];
    bound_entity_uid UUID;
    bound_revision_uid UUID;
    bound_previous_revision_uid UUID;
    matching_operation_count INTEGER;
BEGIN
    IF required_operation_kind = 'save_runtime_profile' THEN
        SELECT profile.runtime_execution_profile_uid,
               NEW.runtime_execution_profile_revision_uid,
               previous.runtime_execution_profile_revision_uid
          INTO STRICT bound_entity_uid, bound_revision_uid,
               bound_previous_revision_uid
          FROM lab_private_server.runtime_execution_profile profile
          LEFT JOIN lab_private_server.runtime_execution_profile_revision previous
            ON previous.runtime_execution_profile_revision_id =
               NEW.previous_runtime_execution_profile_revision_id
         WHERE profile.runtime_execution_profile_id =
               NEW.runtime_execution_profile_id;
    ELSE
        SELECT profile.combat_control_profile_uid,
               NEW.combat_control_profile_revision_uid,
               previous.combat_control_profile_revision_uid
          INTO STRICT bound_entity_uid, bound_revision_uid,
               bound_previous_revision_uid
          FROM lab_private_server.combat_control_profile profile
          LEFT JOIN lab_private_server.combat_control_profile_revision previous
            ON previous.combat_control_profile_revision_id =
               NEW.previous_combat_control_profile_revision_id
         WHERE profile.combat_control_profile_id =
               NEW.combat_control_profile_id;
    END IF;

    SELECT count(*) INTO matching_operation_count
          FROM lab_private_server.private_server_write_operation operation
         WHERE operation.operation_kind = required_operation_kind
           AND operation.local_account_id = NEW.local_account_id
           AND operation.expected_revision_uid IS NOT DISTINCT FROM
               bound_previous_revision_uid
           AND operation.result_entity_uid = bound_entity_uid
           AND operation.result_revision_uid = bound_revision_uid
           AND operation.result_content_sha256 = NEW.content_sha256
           AND operation.completed_at_utc >= NEW.materialized_at_utc;
    IF matching_operation_count <> 1 THEN
        RAISE EXCEPTION 'private_server_write_operation_inverse_missing';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_runtime_write_operation_inverse
AFTER INSERT ON lab_private_server.runtime_execution_profile_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.validate_profile_write_operation_inverse(
        'save_runtime_profile'
    );

CREATE CONSTRAINT TRIGGER trg_validate_control_write_operation_inverse
AFTER INSERT ON lab_private_server.combat_control_profile_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.validate_profile_write_operation_inverse(
        'save_control_profile'
    );

CREATE FUNCTION lab_private_server.validate_activation_write_operation_inverse()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    previous_revision_uid UUID;
    matching_operation_count INTEGER;
BEGIN
    IF NEW.revision_number = 1 THEN
        RETURN NULL;
    END IF;
    SELECT challenge_policy_activation_revision_uid
      INTO STRICT previous_revision_uid
      FROM lab_private_server.challenge_policy_activation_revision
     WHERE challenge_policy_activation_revision_id =
           NEW.previous_activation_revision_id;
    SELECT count(*) INTO matching_operation_count
          FROM lab_private_server.private_server_write_operation operation
         WHERE operation.operation_kind = 'schedule_operational_policy'
           AND operation.expected_revision_uid = previous_revision_uid
           AND operation.result_entity_uid =
               NEW.challenge_policy_activation_uid
           AND operation.result_revision_uid =
               NEW.challenge_policy_activation_revision_uid
           AND operation.result_content_sha256 = NEW.content_sha256
           AND operation.completed_at_utc = NEW.scheduled_at_utc;
    IF matching_operation_count <> 1 THEN
        RAISE EXCEPTION 'private_server_write_operation_inverse_missing';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_activation_write_operation_inverse
AFTER INSERT ON lab_private_server.challenge_policy_activation_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.validate_activation_write_operation_inverse();

CREATE FUNCTION lab_private_server.validate_context_write_operation_inverse()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    context_uid UUID;
    previous_revision lab_private_server.local_client_context_revision%ROWTYPE;
    expected_operation_kind TEXT;
    bound_expected_revision_uid UUID;
    matching_operation_count INTEGER;
BEGIN
    SELECT local_client_context_uid INTO STRICT context_uid
      FROM lab_private_server.local_client_context
     WHERE local_client_context_id = NEW.local_client_context_id;
    IF NEW.revision_number = 1 THEN
        expected_operation_kind := 'open_client_context';
        bound_expected_revision_uid := NULL;
    ELSE
        SELECT * INTO STRICT previous_revision
          FROM lab_private_server.local_client_context_revision
         WHERE local_client_context_revision_id =
               NEW.previous_local_client_context_revision_id;
        bound_expected_revision_uid :=
            previous_revision.local_client_context_revision_uid;
        IF NEW.stage = 'local_connected' THEN
            expected_operation_kind := 'connect_client_context';
        ELSIF NEW.stage = 'lobby_ready'
              AND NEW.selected_raid_season_revision_id IS DISTINCT FROM
                  previous_revision.selected_raid_season_revision_id THEN
            expected_operation_kind := 'select_raid_season';
        ELSE
            expected_operation_kind := 'enter_lobby';
        END IF;
    END IF;

    SELECT count(*) INTO matching_operation_count
          FROM lab_private_server.private_server_write_operation operation
         WHERE operation.operation_kind = expected_operation_kind
           AND operation.local_account_id = NEW.local_account_id
           AND operation.expected_revision_uid IS NOT DISTINCT FROM
               bound_expected_revision_uid
           AND operation.result_entity_uid = context_uid
           AND operation.result_revision_uid =
               NEW.local_client_context_revision_uid
           AND operation.result_content_sha256 = NEW.content_sha256
           AND operation.completed_at_utc = NEW.materialized_at_utc;
    IF matching_operation_count <> 1 THEN
        RAISE EXCEPTION 'private_server_write_operation_inverse_missing';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_context_write_operation_inverse
AFTER INSERT ON lab_private_server.local_client_context_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.validate_context_write_operation_inverse();

CREATE FUNCTION lab_private_server.validate_selection_write_operation_inverse()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_operation_kind TEXT := CASE
        WHEN NEW.revision_number = 1 THEN 'connect_client_context'
        ELSE 'select_raid_season'
    END;
    matching_operation_count INTEGER;
BEGIN
    SELECT count(*) INTO matching_operation_count
          FROM lab_private_server.local_client_context_revision context_revision
          JOIN lab_private_server.local_client_context context
            ON context.local_client_context_id =
               context_revision.local_client_context_id
          JOIN lab_private_server.private_server_write_operation operation
            ON operation.operation_kind = expected_operation_kind
           AND operation.local_account_id = NEW.local_account_id
           AND operation.result_entity_uid = context.local_client_context_uid
           AND operation.result_revision_uid =
               context_revision.local_client_context_revision_uid
           AND operation.result_content_sha256 = context_revision.content_sha256
         WHERE context_revision.selected_raid_season_revision_id =
               NEW.selected_raid_season_revision_id
           AND context_revision.local_client_context_id =
               NEW.local_client_context_id
           AND context_revision.materialized_at_utc = NEW.materialized_at_utc;
    IF matching_operation_count <> 1 THEN
        RAISE EXCEPTION 'private_server_write_operation_inverse_missing';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_selection_write_operation_inverse
AFTER INSERT ON lab_private_server.selected_raid_season_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.validate_selection_write_operation_inverse();

CREATE FUNCTION lab_private_server.guard_policy_activation_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    previous_revision lab_private_server.challenge_policy_activation_revision%ROWTYPE;
    latest_revision_id BIGINT;
    policy_published_at TIMESTAMPTZ;
BEGIN
    SELECT published_at_utc
      INTO STRICT policy_published_at
      FROM lab_private_server.challenge_operational_policy
     WHERE challenge_operational_policy_id = NEW.challenge_operational_policy_id;

    IF NEW.scheduled_at_utc < policy_published_at THEN
        RAISE EXCEPTION 'challenge_policy_scheduled_before_publish';
    END IF;

    SELECT latest_scheduled_activation_revision_id
      INTO latest_revision_id
      FROM lab_private_server.challenge_policy_state
     WHERE singleton;

    IF NEW.revision_number = 1 THEN
        IF latest_revision_id IS NOT NULL
           OR NEW.effective_raid_day_key <>
                lab_private_server.raid_day_key(NEW.scheduled_at_utc) THEN
            RAISE EXCEPTION 'challenge_policy_initial_activation_invalid';
        END IF;
    ELSE
        SELECT * INTO STRICT previous_revision
          FROM lab_private_server.challenge_policy_activation_revision
         WHERE challenge_policy_activation_revision_id = NEW.previous_activation_revision_id;

        IF latest_revision_id IS DISTINCT FROM NEW.previous_activation_revision_id
           OR previous_revision.revision_number + 1 <> NEW.revision_number
           OR previous_revision.challenge_policy_activation_uid <>
                NEW.challenge_policy_activation_uid
           OR NEW.scheduled_at_utc < previous_revision.scheduled_at_utc
           OR NEW.effective_raid_day_key <
                lab_private_server.raid_day_key(NEW.scheduled_at_utc) + 1
           OR NEW.effective_raid_day_key < previous_revision.effective_raid_day_key THEN
            RAISE EXCEPTION 'challenge_policy_activation_lineage_invalid';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_policy_activation_insert
BEFORE INSERT ON lab_private_server.challenge_policy_activation_revision
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_policy_activation_insert();

CREATE FUNCTION lab_private_server.validate_policy_state_head()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_id BIGINT;
BEGIN
    SELECT challenge_policy_activation_revision_id
      INTO expected_id
      FROM lab_private_server.challenge_policy_activation_revision
     ORDER BY revision_number DESC
     LIMIT 1;

    IF NEW.latest_scheduled_activation_revision_id IS DISTINCT FROM expected_id THEN
        RAISE EXCEPTION 'challenge_policy_state_head_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_policy_state_head
AFTER INSERT OR UPDATE ON lab_private_server.challenge_policy_state
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_policy_state_head();

CREATE FUNCTION lab_private_server.validate_capability_manifest()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    manifest_id BIGINT := COALESCE(NEW.capability_manifest_id, OLD.capability_manifest_id);
    feature_manifest_id BIGINT;
    linked_policy_row_id BIGINT;
    feature_entry_count INTEGER;
    capability_entry_count INTEGER;
    feature_invalid BOOLEAN;
    capability_invalid BOOLEAN;
    policy_row lab_private_server.challenge_operational_policy%ROWTYPE;
BEGIN
    SELECT client_feature_manifest_id, challenge_operational_policy_id
      INTO STRICT feature_manifest_id, linked_policy_row_id
      FROM lab_private_server.capability_manifest
     WHERE capability_manifest_id = manifest_id;

    SELECT * INTO STRICT policy_row
      FROM lab_private_server.challenge_operational_policy
     WHERE challenge_operational_policy_id = linked_policy_row_id;

    SELECT count(*), COALESCE(bool_or(
        CASE route_code
            WHEN 'lobby.profile' THEN capability_code <> 'supported'
            WHEN 'lobby.wallet' THEN capability_code <> 'supported'
            WHEN 'lobby.nikke' THEN capability_code <> 'supported'
            WHEN 'lobby.squad' THEN capability_code <> 'supported'
            WHEN 'lobby.inventory' THEN capability_code <> 'supported'
            WHEN 'lobby.recruit' THEN capability_code <> 'visible_no_op'
            WHEN 'lobby.messenger' THEN capability_code <> 'hidden'
            WHEN 'lobby.tracing_the_stars' THEN capability_code <> 'hidden'
            WHEN 'lobby.costume_pick' THEN capability_code <> 'hidden'
            WHEN 'lobby.trail_marker' THEN capability_code <> 'hidden'
            WHEN 'lobby.more' THEN capability_code <> 'hidden'
            WHEN 'lobby.pickup_banner' THEN capability_code <> 'hidden'
            WHEN 'lobby.right_side' THEN capability_code <> 'hidden'
            WHEN 'lobby.shop' THEN capability_code <> 'hidden'
            WHEN 'lobby.cash_shop' THEN capability_code <> 'hidden'
            WHEN 'lobby.outpost' THEN capability_code <> 'hidden'
            WHEN 'lobby.outpost_defense' THEN capability_code <> 'hidden'
            WHEN 'lobby.solo_raid' THEN capability_code <> 'supported'
            WHEN 'solo_raid.directory' THEN capability_code <> 'supported'
            WHEN 'solo_raid.normal_battle' THEN capability_code <> 'not_supported'
            WHEN 'solo_raid.quick_battle' THEN capability_code <> 'not_supported'
            WHEN 'solo_raid.challenge' THEN capability_code <> 'supported'
            ELSE TRUE
        END
    ), TRUE)
      INTO feature_entry_count, feature_invalid
      FROM lab_local_game.client_feature_manifest_entry
     WHERE client_feature_manifest_id = feature_manifest_id;

    IF feature_entry_count <> 22 OR feature_invalid THEN
        RAISE EXCEPTION 'phase2b_client_feature_manifest_entries_invalid';
    END IF;

    SELECT count(*), COALESCE(bool_or(
        CASE capability_code
            WHEN 'private_server.boot' THEN
                status_code <> 'supported' OR reason_code IS NOT NULL
            WHEN 'private_server.lobby' THEN
                status_code <> 'supported' OR reason_code IS NOT NULL
            WHEN 'solo_raid.directory' THEN
                status_code <> 'supported' OR reason_code IS NOT NULL
            WHEN 'solo_raid.challenge_state' THEN
                status_code <> 'supported' OR reason_code IS NOT NULL
            WHEN 'solo_raid.challenge_run' THEN
                CASE WHEN policy_row.resolution_status = 'configured'
                    THEN status_code <> 'supported' OR reason_code IS NOT NULL
                    ELSE status_code <> 'unresolved'
                        OR reason_code <> 'challenge_operational_policy_unresolved'
                END
            WHEN 'solo_raid.normal_combat' THEN
                status_code <> 'unsupported' OR reason_code IS NOT NULL
            WHEN 'solo_raid.quick_battle' THEN
                status_code <> 'unsupported' OR reason_code IS NOT NULL
            WHEN 'solo_raid.mock_battle' THEN
                CASE WHEN policy_row.resolution_status = 'unresolved'
                    THEN status_code <> 'unresolved'
                        OR reason_code <> policy_row.mock_battle_unresolved_reason_code
                    WHEN policy_row.mock_battle_capability = 'lab_owned_only'
                    THEN status_code <> 'supported' OR reason_code IS NOT NULL
                    ELSE status_code <> 'unsupported' OR reason_code IS NOT NULL
                END
            WHEN 'solo_raid.local_ranking' THEN
                CASE WHEN policy_row.resolution_status = 'unresolved'
                    THEN status_code <> 'unresolved'
                        OR reason_code <> policy_row.local_ranking_unresolved_reason_code
                    WHEN policy_row.local_ranking_capability = 'local_records_only'
                    THEN status_code <> 'supported' OR reason_code IS NOT NULL
                    ELSE status_code <> 'unsupported' OR reason_code IS NOT NULL
                END
            WHEN 'recruit.navigation' THEN
                status_code <> 'visible_no_op' OR reason_code IS NOT NULL
            WHEN 'original_client.wire_adapter' THEN
                status_code <> 'blocked_by_gate'
                    OR reason_code <> 'original_client_gate_not_satisfied'
            WHEN 'original_client.presentation_adapter' THEN
                status_code <> 'blocked_by_gate'
                    OR reason_code <> 'original_client_presentation_gate_not_satisfied'
            ELSE TRUE
        END
    ), TRUE)
      INTO capability_entry_count, capability_invalid
      FROM lab_private_server.capability_manifest_entry
     WHERE capability_manifest_id = manifest_id;

    IF capability_entry_count <> 12 OR capability_invalid THEN
        RAISE EXCEPTION 'private_server_capability_manifest_entries_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_capability_manifest_parent
AFTER INSERT ON lab_private_server.capability_manifest
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_capability_manifest();

CREATE CONSTRAINT TRIGGER trg_validate_capability_manifest_entry
AFTER INSERT ON lab_private_server.capability_manifest_entry
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_capability_manifest();

CREATE FUNCTION lab_private_server.validate_raid_season_directory()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    directory_id BIGINT := COALESCE(NEW.raid_season_directory_id, OLD.raid_season_directory_id);
    actual_count INTEGER;
BEGIN
    SELECT count(*) INTO actual_count
      FROM lab_private_server.raid_season_directory_member
     WHERE raid_season_directory_id = directory_id;
    IF actual_count <> 6 THEN
        RAISE EXCEPTION 'raid_season_directory_incomplete';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_raid_season_directory_parent
AFTER INSERT ON lab_private_server.raid_season_directory
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_raid_season_directory();

CREATE CONSTRAINT TRIGGER trg_validate_raid_season_directory_member
AFTER INSERT ON lab_private_server.raid_season_directory_member
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_raid_season_directory();

CREATE FUNCTION lab_private_server.guard_runtime_profile_revision_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    head_id BIGINT;
    previous_number INTEGER;
BEGIN
    SELECT current_runtime_execution_profile_revision_id
      INTO STRICT head_id
      FROM lab_private_server.runtime_execution_profile
     WHERE runtime_execution_profile_id = NEW.runtime_execution_profile_id
     FOR UPDATE;

    IF NEW.revision_number = 1 THEN
        IF head_id IS NOT NULL OR NEW.previous_runtime_execution_profile_revision_id IS NOT NULL THEN
            RAISE EXCEPTION 'runtime_profile_initial_revision_invalid';
        END IF;
    ELSE
        SELECT revision_number INTO STRICT previous_number
          FROM lab_private_server.runtime_execution_profile_revision
         WHERE runtime_execution_profile_revision_id =
               NEW.previous_runtime_execution_profile_revision_id;
        IF head_id IS DISTINCT FROM NEW.previous_runtime_execution_profile_revision_id
           OR previous_number + 1 <> NEW.revision_number THEN
            RAISE EXCEPTION 'runtime_profile_revision_conflict';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_runtime_profile_revision_insert
BEFORE INSERT ON lab_private_server.runtime_execution_profile_revision
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_runtime_profile_revision_insert();

CREATE FUNCTION lab_private_server.validate_runtime_profile_revision()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    revision_id BIGINT := COALESCE(
        NEW.runtime_execution_profile_revision_id,
        OLD.runtime_execution_profile_revision_id
    );
    revision_row lab_private_server.runtime_execution_profile_revision%ROWTYPE;
    actual_count INTEGER;
    effective_count INTEGER;
    requested_unready INTEGER;
    projection_invalid BOOLEAN;
    facts_differ BOOLEAN;
BEGIN
    SELECT * INTO STRICT revision_row
      FROM lab_private_server.runtime_execution_profile_revision
     WHERE runtime_execution_profile_revision_id = revision_id;

    SELECT count(*), count(effective_status),
           count(*) FILTER (WHERE requested_status <> 'ready'),
           COALESCE(bool_or(
               CASE field_code
                   WHEN 'target_fps' THEN
                       (requested_status = 'ready') <> (revision_row.target_fps IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value::integer <> revision_row.target_fps)
                   WHEN 'fixed_delta_denominator' THEN
                       (requested_status = 'ready') <>
                           (revision_row.fixed_delta_denominator IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value::integer <>
                               revision_row.fixed_delta_denominator)
                   WHEN 'vsync_enabled' THEN
                       (requested_status = 'ready') <> (revision_row.vsync_enabled IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value::boolean <> revision_row.vsync_enabled)
                   WHEN 'multiplayer_enabled' THEN
                       (requested_status = 'ready') <>
                           (revision_row.multiplayer_enabled IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value::boolean <>
                               revision_row.multiplayer_enabled)
                   WHEN 'time_scale' THEN
                       (requested_status = 'ready') <> (revision_row.time_scale_code IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <> revision_row.time_scale_code)
                   WHEN 'platform' THEN
                       (requested_status = 'ready') <> (revision_row.platform_code IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <> revision_row.platform_code)
                   WHEN 'display_mode' THEN
                       (requested_status = 'ready') <>
                           (revision_row.display_mode_code IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <> revision_row.display_mode_code)
                   WHEN 'display_width' THEN
                       (requested_status = 'ready') <> (revision_row.display_width IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value::integer <> revision_row.display_width)
                   WHEN 'display_height' THEN
                       (requested_status = 'ready') <> (revision_row.display_height IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value::integer <> revision_row.display_height)
                   WHEN 'effective_refresh_rate' THEN
                       (requested_status = 'ready') <>
                           (revision_row.effective_refresh_hz IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value::numeric <>
                               revision_row.effective_refresh_hz)
                   WHEN 'graphic_option_mode' THEN
                       (requested_status = 'ready') <>
                           (revision_row.graphic_option_mode IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <> revision_row.graphic_option_mode)
                   WHEN 'default_quality_level' THEN
                       (requested_status = 'ready') <>
                           (revision_row.default_quality_level IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <> revision_row.default_quality_level)
                   WHEN 'post_process_flags' THEN
                       (requested_status = 'ready') <>
                           (revision_row.post_process_flags IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <> revision_row.post_process_flags)
                   WHEN 'volumetric_fog_quality' THEN
                       (requested_status = 'ready') <>
                           (revision_row.volumetric_fog_quality IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <> revision_row.volumetric_fog_quality)
                   WHEN 'battle_effect_quality' THEN
                       (requested_status = 'ready') <>
                           (revision_row.battle_effect_quality IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <> revision_row.battle_effect_quality)
                   WHEN 'battle_animation_physics_flags' THEN
                       (requested_status = 'ready') <>
                           (revision_row.battle_animation_physics_flags IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <>
                               revision_row.battle_animation_physics_flags)
                   WHEN 'spine_resolution' THEN
                       (requested_status = 'ready') <>
                           (revision_row.spine_resolution IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <> revision_row.spine_resolution)
                   WHEN 'texture_quality' THEN
                       (requested_status = 'ready') <>
                           (revision_row.texture_quality IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <> revision_row.texture_quality)
                   WHEN 'mesh_quality' THEN
                       (requested_status = 'ready') <> (revision_row.mesh_quality IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <> revision_row.mesh_quality)
                   WHEN 'anti_aliasing_enabled' THEN
                       (requested_status = 'ready') <>
                           (revision_row.anti_aliasing_enabled IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <> revision_row.anti_aliasing_enabled)
                   WHEN 'anti_aliasing_step' THEN
                       (requested_status = 'ready') <>
                           (revision_row.anti_aliasing_step IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value <> revision_row.anti_aliasing_step)
                   ELSE TRUE
               END
           ), TRUE),
           COALESCE(bool_or(
               (requested_status, requested_value, requested_reason_code)
                   IS DISTINCT FROM
               (effective_status, effective_value, effective_reason_code)
           ), FALSE)
      INTO actual_count, effective_count, requested_unready, projection_invalid, facts_differ
      FROM lab_private_server.runtime_execution_profile_fact
     WHERE runtime_execution_profile_revision_id = revision_id;

    IF actual_count <> 21
       OR (revision_row.effective_snapshot_present AND effective_count <> 21)
       OR (NOT revision_row.effective_snapshot_present AND effective_count <> 0)
       OR revision_row.harness_validation_ready <> (requested_unready = 0)
       OR projection_invalid
       OR (revision_row.effective_readback_ready AND facts_differ) THEN
        RAISE EXCEPTION 'runtime_profile_revision_graph_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_runtime_profile_revision_parent
AFTER INSERT ON lab_private_server.runtime_execution_profile_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_runtime_profile_revision();

CREATE CONSTRAINT TRIGGER trg_validate_runtime_profile_revision_fact
AFTER INSERT ON lab_private_server.runtime_execution_profile_fact
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_runtime_profile_revision();

CREATE FUNCTION lab_private_server.validate_runtime_profile_head()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_id BIGINT;
    head_id BIGINT;
BEGIN
    SELECT current_runtime_execution_profile_revision_id INTO STRICT head_id
      FROM lab_private_server.runtime_execution_profile
     WHERE runtime_execution_profile_id = NEW.runtime_execution_profile_id;
    SELECT runtime_execution_profile_revision_id INTO expected_id
      FROM lab_private_server.runtime_execution_profile_revision
     WHERE runtime_execution_profile_id = NEW.runtime_execution_profile_id
     ORDER BY revision_number DESC LIMIT 1;
    IF expected_id IS NULL
       OR head_id IS DISTINCT FROM expected_id THEN
        RAISE EXCEPTION 'runtime_profile_head_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_runtime_profile_head
AFTER INSERT OR UPDATE ON lab_private_server.runtime_execution_profile
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_runtime_profile_head();

CREATE FUNCTION lab_private_server.guard_control_profile_revision_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    head_id BIGINT;
    previous_number INTEGER;
BEGIN
    SELECT current_combat_control_profile_revision_id
      INTO STRICT head_id
      FROM lab_private_server.combat_control_profile
     WHERE combat_control_profile_id = NEW.combat_control_profile_id
     FOR UPDATE;

    IF NEW.revision_number = 1 THEN
        IF head_id IS NOT NULL OR NEW.previous_combat_control_profile_revision_id IS NOT NULL THEN
            RAISE EXCEPTION 'control_profile_initial_revision_invalid';
        END IF;
    ELSE
        SELECT revision_number INTO STRICT previous_number
          FROM lab_private_server.combat_control_profile_revision
         WHERE combat_control_profile_revision_id =
               NEW.previous_combat_control_profile_revision_id;
        IF head_id IS DISTINCT FROM NEW.previous_combat_control_profile_revision_id
           OR previous_number + 1 <> NEW.revision_number THEN
            RAISE EXCEPTION 'control_profile_revision_conflict';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_control_profile_revision_insert
BEFORE INSERT ON lab_private_server.combat_control_profile_revision
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_control_profile_revision_insert();

CREATE FUNCTION lab_private_server.validate_control_profile_revision()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    revision_id BIGINT := COALESCE(
        NEW.combat_control_profile_revision_id,
        OLD.combat_control_profile_revision_id
    );
    revision_row lab_private_server.combat_control_profile_revision%ROWTYPE;
    actual_count INTEGER;
    effective_count INTEGER;
    requested_unready INTEGER;
    effective_unready INTEGER;
    projection_invalid BOOLEAN;
    facts_differ BOOLEAN;
    aim_assistant_shape_invalid BOOLEAN;
BEGIN
    SELECT * INTO STRICT revision_row
      FROM lab_private_server.combat_control_profile_revision
     WHERE combat_control_profile_revision_id = revision_id;

    SELECT count(*), count(effective_status),
           count(*) FILTER (
               WHERE (field_code IN (
                   'aim_sensitivity', 'use_aim_assistant',
                   'use_pc_aim_sync', 'max_per_shot_correct'
               ) AND requested_status <> 'ready')
               OR (field_code = 'aim_assistant_intensity'
                   AND requested_status = 'unresolved')
           ),
           count(*) FILTER (
               WHERE effective_status IS NOT NULL AND (
                   (field_code IN (
                       'aim_sensitivity', 'use_aim_assistant',
                       'use_pc_aim_sync', 'max_per_shot_correct'
                   ) AND effective_status <> 'ready')
                   OR (field_code = 'aim_assistant_intensity'
                       AND effective_status = 'unresolved')
               )
           ),
           COALESCE(bool_or(
               CASE field_code
                   WHEN 'aim_sensitivity' THEN
                       (requested_status = 'ready') <>
                           (revision_row.aim_sensitivity IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value::numeric <> revision_row.aim_sensitivity)
                   WHEN 'use_aim_assistant' THEN
                       (requested_status = 'ready') <>
                           (revision_row.use_aim_assistant IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value::boolean <> revision_row.use_aim_assistant)
                   WHEN 'aim_assistant_intensity' THEN
                       (requested_status = 'ready') <>
                           (revision_row.aim_assistant_intensity IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value::numeric <>
                               revision_row.aim_assistant_intensity)
                   WHEN 'use_pc_aim_sync' THEN
                       (requested_status = 'ready') <>
                           (revision_row.use_pc_aim_sync IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value::boolean <> revision_row.use_pc_aim_sync)
                   WHEN 'max_per_shot_correct' THEN
                       (requested_status = 'ready') <>
                           (revision_row.max_per_shot_correct IS NOT NULL)
                       OR (requested_status = 'ready'
                           AND requested_value::boolean <> revision_row.max_per_shot_correct)
                   WHEN 'auto_combat' THEN
                       requested_status <> revision_row.auto_combat_status
                       OR (requested_value::boolean IS DISTINCT FROM
                           revision_row.auto_combat_value)
                       OR requested_reason_code IS DISTINCT FROM
                           revision_row.auto_combat_unresolved_reason_code
                   WHEN 'auto_burst' THEN
                       requested_status <> revision_row.auto_burst_status
                       OR (requested_value::boolean IS DISTINCT FROM
                           revision_row.auto_burst_value)
                       OR requested_reason_code IS DISTINCT FROM
                           revision_row.auto_burst_unresolved_reason_code
                   ELSE TRUE
               END
           ), TRUE),
           COALESCE(bool_or(
               (requested_status, requested_value, requested_reason_code)
                   IS DISTINCT FROM
               (effective_status, effective_value, effective_reason_code)
           ), FALSE)
      INTO actual_count, effective_count, requested_unready, effective_unready,
           projection_invalid, facts_differ
      FROM lab_private_server.combat_control_profile_fact
     WHERE combat_control_profile_revision_id = revision_id;

    SELECT EXISTS (
        SELECT 1
          FROM lab_private_server.combat_control_profile_fact use_fact
          JOIN lab_private_server.combat_control_profile_fact intensity_fact
            ON intensity_fact.combat_control_profile_revision_id =
               use_fact.combat_control_profile_revision_id
           AND intensity_fact.field_code = 'aim_assistant_intensity'
         WHERE use_fact.combat_control_profile_revision_id = revision_id
           AND use_fact.field_code = 'use_aim_assistant'
           AND (
               (
                   use_fact.requested_status = 'ready'
                   AND (
                       (use_fact.requested_value::boolean
                           AND intensity_fact.requested_status <> 'ready')
                       OR
                       (NOT use_fact.requested_value::boolean
                           AND intensity_fact.requested_status <>
                               'not_applicable')
                   )
               )
               OR
               (
                   use_fact.effective_status = 'ready'
                   AND (
                       (use_fact.effective_value::boolean
                           AND intensity_fact.effective_status <> 'ready')
                       OR
                       (NOT use_fact.effective_value::boolean
                           AND intensity_fact.effective_status IS DISTINCT FROM
                               'not_applicable')
                   )
               )
           )
    ) INTO aim_assistant_shape_invalid;

    IF actual_count <> 7
       OR (revision_row.effective_snapshot_present AND effective_count <> 7)
       OR (NOT revision_row.effective_snapshot_present AND effective_count <> 0)
       OR revision_row.manual_ready <> (requested_unready = 0)
       OR revision_row.effective_manual_ready <>
            (revision_row.effective_snapshot_present AND effective_unready = 0)
       OR projection_invalid
       OR aim_assistant_shape_invalid
       OR (revision_row.effective_readback_ready AND facts_differ) THEN
        RAISE EXCEPTION 'control_profile_revision_graph_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_control_profile_revision_parent
AFTER INSERT ON lab_private_server.combat_control_profile_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_control_profile_revision();

CREATE CONSTRAINT TRIGGER trg_validate_control_profile_revision_fact
AFTER INSERT ON lab_private_server.combat_control_profile_fact
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_control_profile_revision();

CREATE FUNCTION lab_private_server.validate_control_profile_head()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_id BIGINT;
    head_id BIGINT;
BEGIN
    SELECT current_combat_control_profile_revision_id INTO STRICT head_id
      FROM lab_private_server.combat_control_profile
     WHERE combat_control_profile_id = NEW.combat_control_profile_id;
    SELECT combat_control_profile_revision_id INTO expected_id
      FROM lab_private_server.combat_control_profile_revision
     WHERE combat_control_profile_id = NEW.combat_control_profile_id
     ORDER BY revision_number DESC LIMIT 1;
    IF expected_id IS NULL
       OR head_id IS DISTINCT FROM expected_id THEN
        RAISE EXCEPTION 'control_profile_head_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_control_profile_head
AFTER INSERT OR UPDATE ON lab_private_server.combat_control_profile
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_control_profile_head();

CREATE FUNCTION lab_private_server.guard_selection_revision_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    head_id BIGINT;
    previous_number INTEGER;
BEGIN
    SELECT current_selected_raid_season_revision_id
      INTO STRICT head_id
      FROM lab_private_server.raid_season_selection
     WHERE raid_season_selection_id = NEW.raid_season_selection_id
     FOR UPDATE;

    IF NEW.revision_number = 1 THEN
        IF head_id IS NOT NULL OR NEW.previous_selected_raid_season_revision_id IS NOT NULL THEN
            RAISE EXCEPTION 'raid_season_selection_initial_revision_invalid';
        END IF;
    ELSE
        SELECT revision_number INTO STRICT previous_number
          FROM lab_private_server.selected_raid_season_revision
         WHERE selected_raid_season_revision_id =
               NEW.previous_selected_raid_season_revision_id;
        IF head_id IS DISTINCT FROM NEW.previous_selected_raid_season_revision_id
           OR previous_number + 1 <> NEW.revision_number THEN
            RAISE EXCEPTION 'raid_season_selection_revision_conflict';
        END IF;
        IF EXISTS (
            SELECT 1
              FROM lab_private_server.challenge_run
             WHERE local_client_context_id = NEW.local_client_context_id
                AND status NOT IN ('completed', 'abandoned')
        ) THEN
            RAISE EXCEPTION 'raid_season_selection_active_run';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_selection_revision_insert
BEFORE INSERT ON lab_private_server.selected_raid_season_revision
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_selection_revision_insert();

CREATE FUNCTION lab_private_server.validate_selection_head()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_id BIGINT;
    head_id BIGINT;
BEGIN
    SELECT current_selected_raid_season_revision_id INTO STRICT head_id
      FROM lab_private_server.raid_season_selection
     WHERE raid_season_selection_id = NEW.raid_season_selection_id;
    SELECT selected_raid_season_revision_id INTO expected_id
      FROM lab_private_server.selected_raid_season_revision
     WHERE raid_season_selection_id = NEW.raid_season_selection_id
     ORDER BY revision_number DESC LIMIT 1;
    IF expected_id IS NULL
       OR head_id IS DISTINCT FROM expected_id THEN
        RAISE EXCEPTION 'raid_season_selection_head_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_selection_head
AFTER INSERT OR UPDATE ON lab_private_server.raid_season_selection
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_selection_head();

CREATE FUNCTION lab_private_server.guard_client_context_revision_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    head_id BIGINT;
    previous_row lab_private_server.local_client_context_revision%ROWTYPE;
    session_row lab_profile.local_session%ROWTYPE;
    active_policy_id BIGINT;
    manifest_policy_id BIGINT;
    active_boot_id BIGINT;
    boot_row lab_private_server.private_server_boot_revision%ROWTYPE;
    selection_head_id BIGINT;
    account_state_head BIGINT;
    profile_head BIGINT;
    lobby_head BIGINT;
    wallet_head BIGINT;
    feature_manifest_head BIGINT;
    squad_revision_head BIGINT;
BEGIN
    SELECT current_local_client_context_revision_id
      INTO STRICT head_id
      FROM lab_private_server.local_client_context
     WHERE local_client_context_id = NEW.local_client_context_id
     FOR UPDATE;

    SELECT * INTO STRICT session_row
      FROM lab_profile.local_session
     WHERE local_session_id = NEW.local_session_id;
    IF session_row.local_account_id <> NEW.local_account_id
       OR session_row.issued_at_utc <> NEW.issued_at_utc
       OR session_row.expires_at_utc <> NEW.expires_at_utc
       OR (NEW.stage <> 'closed' AND session_row.revoked_at_utc IS NOT NULL)
       OR (NEW.stage <> 'closed' AND NEW.materialized_at_utc >= NEW.expires_at_utc) THEN
        RAISE EXCEPTION 'private_server_session_binding_invalid';
    END IF;

    SELECT challenge_operational_policy_id INTO active_policy_id
      FROM lab_private_server.challenge_policy_activation_revision
     WHERE effective_raid_day_key <=
           lab_private_server.raid_day_key(NEW.materialized_at_utc)
     ORDER BY effective_raid_day_key DESC, revision_number DESC
     LIMIT 1;
    SELECT private_server_boot_revision_id INTO active_boot_id
      FROM lab_private_server.private_server_boot_revision
     WHERE effective_raid_day_key <=
           lab_private_server.raid_day_key(NEW.materialized_at_utc)
     ORDER BY effective_raid_day_key DESC, revision_number DESC
     LIMIT 1;
    SELECT * INTO STRICT boot_row
      FROM lab_private_server.private_server_boot_revision
     WHERE private_server_boot_revision_id = NEW.private_server_boot_revision_id;
    SELECT challenge_operational_policy_id INTO STRICT manifest_policy_id
      FROM lab_private_server.capability_manifest
     WHERE capability_manifest_id = NEW.capability_manifest_id;
    IF boot_row.challenge_operational_policy_id <> manifest_policy_id
       OR boot_row.application_build_id <> NEW.application_build_id
       OR boot_row.application_build_sha256 <> NEW.application_build_sha256
       OR boot_row.capability_manifest_id <> NEW.capability_manifest_id
       OR boot_row.capability_manifest_content_sha256 <>
            NEW.capability_manifest_content_sha256 THEN
        RAISE EXCEPTION 'private_server_context_policy_manifest_mismatch';
    END IF;

    IF NEW.revision_number = 1 THEN
        IF head_id IS NOT NULL
           OR NEW.previous_local_client_context_revision_id IS NOT NULL
           OR NEW.stage <> 'loading'
           OR active_boot_id IS DISTINCT FROM NEW.private_server_boot_revision_id
           OR active_policy_id IS DISTINCT FROM manifest_policy_id THEN
            RAISE EXCEPTION 'private_server_context_initial_revision_invalid';
        END IF;
    ELSE
        SELECT * INTO STRICT previous_row
          FROM lab_private_server.local_client_context_revision
         WHERE local_client_context_revision_id =
               NEW.previous_local_client_context_revision_id;
        IF head_id IS DISTINCT FROM NEW.previous_local_client_context_revision_id
           OR previous_row.revision_number + 1 <> NEW.revision_number
           OR previous_row.local_client_context_id <> NEW.local_client_context_id
           OR previous_row.local_session_id <> NEW.local_session_id
           OR previous_row.local_account_id <> NEW.local_account_id
           OR previous_row.private_server_boot_revision_id <>
               NEW.private_server_boot_revision_id
           OR previous_row.private_server_boot_content_sha256 <>
               NEW.private_server_boot_content_sha256
           OR previous_row.capability_manifest_id <> NEW.capability_manifest_id
           OR previous_row.capability_manifest_content_sha256 <>
               NEW.capability_manifest_content_sha256
           OR previous_row.application_build_id <> NEW.application_build_id
           OR previous_row.application_build_sha256 <> NEW.application_build_sha256
           OR previous_row.application_contract_id <> NEW.application_contract_id
           OR previous_row.issued_at_utc <> NEW.issued_at_utc
           OR previous_row.expires_at_utc <> NEW.expires_at_utc THEN
            RAISE EXCEPTION 'private_server_context_revision_conflict';
        END IF;

        IF NOT (
            (previous_row.stage = 'loading' AND NEW.stage = 'local_connected')
            OR (previous_row.stage = 'local_connected' AND NEW.stage = 'lobby_ready')
            OR (previous_row.stage = 'lobby_ready' AND NEW.stage = 'lobby_ready')
            OR (previous_row.stage <> 'closed' AND NEW.stage = 'closed')
        ) THEN
            RAISE EXCEPTION 'private_server_context_transition_invalid';
        END IF;
        IF previous_row.stage = 'lobby_ready'
           AND NEW.stage = 'lobby_ready'
           AND (
               NEW.selected_raid_season_revision_id IS NOT DISTINCT FROM
                   previous_row.selected_raid_season_revision_id
               OR NEW.selected_season_content_sha256 IS NOT DISTINCT FROM
                   previous_row.selected_season_content_sha256
           ) THEN
            RAISE EXCEPTION 'private_server_context_transition_invalid';
        END IF;
        IF EXISTS (
            SELECT 1
              FROM lab_private_server.challenge_run active_run
             WHERE active_run.local_client_context_id =
                   NEW.local_client_context_id
               AND active_run.status NOT IN ('completed', 'abandoned')
        ) THEN
            RAISE EXCEPTION 'private_server_context_active_run';
        END IF;
        IF NEW.stage = 'closed'
           AND (NEW.connected_at_utc, NEW.lobby_ready_at_utc,
                NEW.selected_raid_season_revision_id,
                NEW.selected_season_content_sha256,
                NEW.account_revision_set_sha256,
                NEW.account_state_revision_id,
                NEW.profile_template_revision_id,
                NEW.lobby_presentation_revision_id,
                NEW.wallet_revision_id,
                NEW.client_feature_manifest_id,
                NEW.client_feature_manifest_uid,
                NEW.client_feature_manifest_content_sha256,
                NEW.squad_revision_id,
                NEW.squad_revision_uid,
                NEW.squad_revision_content_sha256)
               IS DISTINCT FROM
               (previous_row.connected_at_utc, previous_row.lobby_ready_at_utc,
                previous_row.selected_raid_season_revision_id,
                previous_row.selected_season_content_sha256,
                previous_row.account_revision_set_sha256,
                previous_row.account_state_revision_id,
                previous_row.profile_template_revision_id,
                previous_row.lobby_presentation_revision_id,
                previous_row.wallet_revision_id,
                previous_row.client_feature_manifest_id,
                previous_row.client_feature_manifest_uid,
                previous_row.client_feature_manifest_content_sha256,
                previous_row.squad_revision_id,
                previous_row.squad_revision_uid,
                previous_row.squad_revision_content_sha256) THEN
            RAISE EXCEPTION 'private_server_context_close_pin_mutation';
        END IF;
        IF previous_row.stage = 'lobby_ready'
           AND NEW.stage = 'lobby_ready'
           AND (NEW.account_revision_set_sha256,
                NEW.account_state_revision_id,
                NEW.profile_template_revision_id,
                NEW.lobby_presentation_revision_id,
                NEW.wallet_revision_id,
                NEW.client_feature_manifest_id,
                NEW.client_feature_manifest_uid,
                NEW.client_feature_manifest_content_sha256,
                NEW.squad_revision_id,
                NEW.squad_revision_uid,
                NEW.squad_revision_content_sha256)
               IS DISTINCT FROM
               (previous_row.account_revision_set_sha256,
                previous_row.account_state_revision_id,
                previous_row.profile_template_revision_id,
                previous_row.lobby_presentation_revision_id,
                previous_row.wallet_revision_id,
                previous_row.client_feature_manifest_id,
                previous_row.client_feature_manifest_uid,
                previous_row.client_feature_manifest_content_sha256,
                previous_row.squad_revision_id,
                previous_row.squad_revision_uid,
                previous_row.squad_revision_content_sha256) THEN
            RAISE EXCEPTION 'private_server_context_rebind_pin_mutation';
        END IF;
    END IF;

    IF NEW.stage IN ('local_connected', 'lobby_ready') THEN
        SELECT current_selected_raid_season_revision_id INTO STRICT selection_head_id
          FROM lab_private_server.raid_season_selection
         WHERE local_client_context_id = NEW.local_client_context_id;
        IF selection_head_id <> NEW.selected_raid_season_revision_id THEN
            RAISE EXCEPTION 'private_server_context_selection_head_mismatch';
        END IF;

    END IF;

    IF NEW.stage = 'lobby_ready'
       AND NEW.revision_number > 1
       AND previous_row.stage = 'local_connected' THEN
        SELECT account.current_account_state_revision_id,
               account.current_profile_template_revision_id,
               profile.squad_revision_id
          INTO STRICT account_state_head, profile_head, squad_revision_head
          FROM lab_profile.local_account account
          JOIN lab_profile.profile_template_revision profile
            ON profile.profile_template_revision_id =
               account.current_profile_template_revision_id
         WHERE account.local_account_id = NEW.local_account_id;
        SELECT current_lobby_presentation_revision_id,
               current_wallet_revision_id,
               current_client_feature_manifest_id
          INTO STRICT lobby_head, wallet_head, feature_manifest_head
          FROM lab_local_game.account_client_state
         WHERE local_account_id = NEW.local_account_id;
        IF NEW.account_state_revision_id <> account_state_head
           OR NEW.profile_template_revision_id <> profile_head
           OR NEW.lobby_presentation_revision_id <> lobby_head
           OR NEW.wallet_revision_id <> wallet_head
           OR NEW.client_feature_manifest_id <> feature_manifest_head
           OR NEW.squad_revision_id IS DISTINCT FROM squad_revision_head THEN
            RAISE EXCEPTION 'private_server_context_account_revision_set_mismatch';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_client_context_revision_insert
BEFORE INSERT ON lab_private_server.local_client_context_revision
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_client_context_revision_insert();

CREATE FUNCTION lab_private_server.validate_client_context_head()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_id BIGINT;
    head_id BIGINT;
BEGIN
    SELECT current_local_client_context_revision_id INTO STRICT head_id
      FROM lab_private_server.local_client_context
     WHERE local_client_context_id = NEW.local_client_context_id;
    SELECT local_client_context_revision_id INTO expected_id
      FROM lab_private_server.local_client_context_revision
     WHERE local_client_context_id = NEW.local_client_context_id
     ORDER BY revision_number DESC LIMIT 1;
    IF expected_id IS NULL
       OR head_id IS DISTINCT FROM expected_id THEN
        RAISE EXCEPTION 'private_server_context_head_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_client_context_head
AFTER INSERT OR UPDATE ON lab_private_server.local_client_context
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_client_context_head();

CREATE FUNCTION lab_private_server.guard_daily_state_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    policy_row lab_private_server.challenge_operational_policy%ROWTYPE;
BEGIN
    SELECT * INTO STRICT policy_row
      FROM lab_private_server.challenge_operational_policy
     WHERE challenge_operational_policy_id = NEW.challenge_operational_policy_id;
    IF policy_row.resolution_status <> 'configured'
       OR policy_row.counter_scope <> NEW.counter_scope THEN
        RAISE EXCEPTION 'challenge_daily_policy_unresolved_or_mismatch';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_daily_state_insert
BEFORE INSERT ON lab_private_server.challenge_daily_state
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_daily_state_insert();

CREATE FUNCTION lab_private_server.guard_daily_state_revision_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    state_row lab_private_server.challenge_daily_state%ROWTYPE;
    previous_row lab_private_server.challenge_daily_state_revision%ROWTYPE;
    entry_limit INTEGER;
BEGIN
    SELECT * INTO STRICT state_row
      FROM lab_private_server.challenge_daily_state
     WHERE challenge_daily_state_id = NEW.challenge_daily_state_id
     FOR UPDATE;

    IF NEW.local_account_id <> state_row.local_account_id
       OR NEW.challenge_operational_policy_id <>
          state_row.challenge_operational_policy_id
       OR NEW.raid_season_directory_id <> state_row.raid_season_directory_id
       OR NEW.raid_day_key <> state_row.raid_day_key
       OR NEW.counter_scope <> state_row.counter_scope
       OR NEW.raid_snapshot_id IS DISTINCT FROM state_row.raid_snapshot_id THEN
        RAISE EXCEPTION 'challenge_daily_state_topology_mismatch';
    END IF;

    SELECT daily_entry_limit INTO STRICT entry_limit
      FROM lab_private_server.challenge_operational_policy
     WHERE challenge_operational_policy_id = NEW.challenge_operational_policy_id
       AND resolution_status = 'configured';

    IF NEW.revision_number = 1 THEN
        IF state_row.current_challenge_daily_state_revision_id IS NOT NULL
           OR NEW.previous_challenge_daily_state_revision_id IS NOT NULL
           OR NEW.consumed_entries <> 0 THEN
            RAISE EXCEPTION 'challenge_daily_initial_revision_invalid';
        END IF;
    ELSE
        SELECT * INTO STRICT previous_row
          FROM lab_private_server.challenge_daily_state_revision
         WHERE challenge_daily_state_revision_id =
               NEW.previous_challenge_daily_state_revision_id;
        IF state_row.current_challenge_daily_state_revision_id IS DISTINCT FROM
               NEW.previous_challenge_daily_state_revision_id
           OR previous_row.revision_number + 1 <> NEW.revision_number
           OR previous_row.challenge_daily_state_id <> NEW.challenge_daily_state_id
           OR previous_row.consumed_entries + 1 <> NEW.consumed_entries THEN
            RAISE EXCEPTION 'challenge_daily_revision_conflict';
        END IF;
    END IF;

    IF NEW.consumed_entries > entry_limit THEN
        RAISE EXCEPTION 'challenge_daily_entry_limit_reached';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_daily_state_revision_insert
BEFORE INSERT ON lab_private_server.challenge_daily_state_revision
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_daily_state_revision_insert();

CREATE FUNCTION lab_private_server.validate_daily_state_head()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_id BIGINT;
    head_id BIGINT;
BEGIN
    SELECT current_challenge_daily_state_revision_id INTO STRICT head_id
      FROM lab_private_server.challenge_daily_state
     WHERE challenge_daily_state_id = NEW.challenge_daily_state_id;
    SELECT challenge_daily_state_revision_id INTO expected_id
      FROM lab_private_server.challenge_daily_state_revision
     WHERE challenge_daily_state_id = NEW.challenge_daily_state_id
     ORDER BY revision_number DESC LIMIT 1;
    IF expected_id IS NULL
       OR head_id IS DISTINCT FROM expected_id THEN
        RAISE EXCEPTION 'challenge_daily_state_head_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_daily_state_head
AFTER INSERT OR UPDATE ON lab_private_server.challenge_daily_state
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_daily_state_head();

CREATE FUNCTION lab_private_server.guard_run_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    context_row lab_private_server.local_client_context_revision%ROWTYPE;
    context_head BIGINT;
    selection_head BIGINT;
    policy_row lab_private_server.challenge_operational_policy%ROWTYPE;
    active_activation_id BIGINT;
    daily_row lab_private_server.challenge_daily_state%ROWTYPE;
    daily_head BIGINT;
    daily_consumed INTEGER;
    runtime_ready BOOLEAN;
    control_ready BOOLEAN;
    runtime_head BIGINT;
    control_head BIGINT;
    manifest_policy_id BIGINT;
    session_revoked TIMESTAMPTZ;
BEGIN
    IF NEW.current_challenge_run_revision_id IS NOT NULL THEN
        RAISE EXCEPTION 'challenge_run_initial_head_must_be_unset';
    END IF;
    SELECT * INTO STRICT context_row
      FROM lab_private_server.local_client_context_revision
     WHERE local_client_context_revision_id = NEW.local_client_context_revision_id;
    SELECT current_local_client_context_revision_id INTO STRICT context_head
      FROM lab_private_server.local_client_context
     WHERE local_client_context_id = NEW.local_client_context_id;
    IF context_row.stage <> 'lobby_ready'
       OR context_head <> NEW.local_client_context_revision_id
       OR context_row.profile_template_revision_id <>
            NEW.profile_template_revision_id
       OR context_row.account_state_revision_id <>
            NEW.account_state_revision_id
       OR NEW.opened_at_utc < context_row.lobby_ready_at_utc
       OR NEW.opened_at_utc >= context_row.expires_at_utc THEN
        RAISE EXCEPTION 'challenge_run_context_not_ready';
    END IF;
    SELECT revoked_at_utc INTO session_revoked
      FROM lab_profile.local_session
     WHERE local_session_id = context_row.local_session_id;
    IF session_revoked IS NOT NULL THEN
        RAISE EXCEPTION 'challenge_run_session_revoked';
    END IF;

    SELECT current_selected_raid_season_revision_id INTO STRICT selection_head
      FROM lab_private_server.raid_season_selection
     WHERE local_client_context_id = NEW.local_client_context_id;
    IF selection_head <> NEW.selected_raid_season_revision_id THEN
        RAISE EXCEPTION 'challenge_run_selection_not_current';
    END IF;

    SELECT challenge_policy_activation_revision_id
      INTO active_activation_id
      FROM lab_private_server.challenge_policy_activation_revision
     WHERE effective_raid_day_key <= NEW.opening_raid_day_key
     ORDER BY effective_raid_day_key DESC, revision_number DESC
     LIMIT 1;
    IF active_activation_id IS DISTINCT FROM
       NEW.challenge_policy_activation_revision_id THEN
        RAISE EXCEPTION 'challenge_run_policy_activation_not_effective';
    END IF;
    SELECT * INTO STRICT policy_row
      FROM lab_private_server.challenge_operational_policy
     WHERE challenge_operational_policy_id = NEW.challenge_operational_policy_id;
    IF policy_row.resolution_status <> 'configured'
       OR (NEW.is_mock_battle AND policy_row.mock_battle_capability <> 'lab_owned_only') THEN
        RAISE EXCEPTION 'challenge_run_policy_unresolved_or_unsupported';
    END IF;
    SELECT challenge_operational_policy_id INTO STRICT manifest_policy_id
      FROM lab_private_server.capability_manifest
     WHERE capability_manifest_id = context_row.capability_manifest_id;
    IF manifest_policy_id <> NEW.challenge_operational_policy_id THEN
        RAISE EXCEPTION 'challenge_run_context_capability_policy_mismatch';
    END IF;

    SELECT * INTO STRICT daily_row
      FROM lab_private_server.challenge_daily_state
     WHERE challenge_daily_state_id = NEW.challenge_daily_state_id;
    daily_head := daily_row.current_challenge_daily_state_revision_id;
    IF daily_row.local_account_id <> NEW.local_account_id
       OR daily_row.challenge_operational_policy_id <>
          NEW.challenge_operational_policy_id
       OR daily_row.raid_season_directory_id <> NEW.raid_season_directory_id
       OR daily_row.raid_day_key <> NEW.opening_raid_day_key
       OR daily_row.counter_scope <> policy_row.counter_scope
       OR daily_row.raid_snapshot_id IS DISTINCT FROM (
          CASE WHEN policy_row.counter_scope = 'per_season'
               THEN NEW.raid_snapshot_id ELSE NULL END
       )
       OR daily_head <> NEW.admission_daily_state_revision_id THEN
        RAISE EXCEPTION 'challenge_run_daily_state_binding_invalid';
    END IF;
    SELECT consumed_entries INTO STRICT daily_consumed
      FROM lab_private_server.challenge_daily_state_revision
     WHERE challenge_daily_state_revision_id = daily_head;
    IF NOT NEW.is_mock_battle
       AND daily_consumed >= policy_row.daily_entry_limit
       AND policy_row.entry_consumption_point <> 'run_opened' THEN
        RAISE EXCEPTION 'challenge_daily_entry_limit_reached';
    END IF;

    SELECT revision.harness_validation_ready,
           profile.current_runtime_execution_profile_revision_id
      INTO STRICT runtime_ready, runtime_head
      FROM lab_private_server.runtime_execution_profile_revision revision
      JOIN lab_private_server.runtime_execution_profile profile
        ON profile.runtime_execution_profile_id =
           revision.runtime_execution_profile_id
     WHERE revision.runtime_execution_profile_revision_id =
           NEW.runtime_execution_profile_revision_id;
    SELECT revision.manual_ready,
           profile.current_combat_control_profile_revision_id
      INTO STRICT control_ready, control_head
      FROM lab_private_server.combat_control_profile_revision revision
      JOIN lab_private_server.combat_control_profile profile
        ON profile.combat_control_profile_id =
           revision.combat_control_profile_id
     WHERE revision.combat_control_profile_revision_id =
           NEW.combat_control_profile_revision_id;
    IF NOT runtime_ready OR NOT control_ready
       OR runtime_head <> NEW.runtime_execution_profile_revision_id
       OR control_head <> NEW.combat_control_profile_revision_id THEN
        RAISE EXCEPTION 'challenge_run_execution_profile_not_ready';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_run_insert
BEFORE INSERT ON lab_private_server.challenge_run
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_run_insert();

CREATE FUNCTION lab_private_server.guard_run_revision_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    run_row lab_private_server.challenge_run%ROWTYPE;
    previous_row lab_private_server.challenge_run_revision%ROWTYPE;
    boundary_policy TEXT;
BEGIN
    SELECT * INTO STRICT run_row
      FROM lab_private_server.challenge_run
     WHERE challenge_run_id = NEW.challenge_run_id
     FOR UPDATE;
    IF NEW.challenge_run_uid <> run_row.challenge_run_uid
       OR NEW.local_account_id <> run_row.local_account_id
       OR NEW.opened_at_utc <> run_row.opened_at_utc
       OR NEW.accepted_team_count > run_row.configured_team_count THEN
        RAISE EXCEPTION 'challenge_run_revision_binding_invalid';
    END IF;

    IF NEW.revision_number = 1 THEN
        IF run_row.current_challenge_run_revision_id IS NOT NULL
           OR NEW.previous_challenge_run_revision_id IS NOT NULL
           OR NEW.status <> 'open' THEN
            RAISE EXCEPTION 'challenge_run_initial_revision_invalid';
        END IF;
    ELSE
        IF run_row.current_challenge_run_revision_id IS NULL
           OR NEW.previous_challenge_run_revision_id <>
              run_row.current_challenge_run_revision_id THEN
            RAISE EXCEPTION 'challenge_run_revision_cas_conflict';
        END IF;
        SELECT * INTO STRICT previous_row
          FROM lab_private_server.challenge_run_revision
         WHERE challenge_run_revision_id = NEW.previous_challenge_run_revision_id;
        IF NEW.revision_number <> previous_row.revision_number + 1
           OR NEW.updated_at_utc < previous_row.updated_at_utc
           OR previous_row.status IN ('completed', 'abandoned')
           OR NOT (
               (previous_row.status IN ('open', 'regroup_ready')
                    AND NEW.status = 'team_in_progress')
               OR (previous_row.status = 'team_in_progress'
                    AND NEW.status = 'team_result_accepted')
               OR (previous_row.status = 'team_result_accepted'
                    AND NEW.status IN ('regroup_ready', 'completed'))
               OR (previous_row.status = 'regroup_ready'
                    AND NEW.status = 'completed')
               OR (previous_row.status NOT IN ('completed', 'abandoned')
                    AND NEW.status = 'abandoned')
           ) THEN
            RAISE EXCEPTION 'challenge_run_revision_transition_invalid';
        END IF;
    END IF;

    SELECT active_run_at_reset INTO STRICT boundary_policy
      FROM lab_private_server.challenge_operational_policy
     WHERE challenge_operational_policy_id = run_row.challenge_operational_policy_id;
    IF NEW.status <> 'abandoned'
       AND boundary_policy = 'reject_post_boundary_progress'
       AND lab_private_server.raid_day_key(NEW.updated_at_utc) <>
           run_row.opening_raid_day_key THEN
        RAISE EXCEPTION 'challenge_run_cross_boundary_progress_rejected';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_run_revision_insert
BEFORE INSERT ON lab_private_server.challenge_run_revision
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_run_revision_insert();

CREATE FUNCTION lab_private_server.validate_run_revision_attempt_graph()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    revision_id BIGINT := COALESCE(
        NEW.challenge_run_revision_id,
        OLD.challenge_run_revision_id
    );
    revision_row lab_private_server.challenge_run_revision%ROWTYPE;
    attempt_count INTEGER;
    accepted_count INTEGER;
    active_count INTEGER;
    receipt_total NUMERIC(78, 0);
    invalid_time_count INTEGER;
BEGIN
    SELECT * INTO STRICT revision_row
      FROM lab_private_server.challenge_run_revision
     WHERE challenge_run_revision_id = revision_id;
    SELECT count(*),
           count(*) FILTER (
               WHERE attempt.challenge_team_damage_receipt_id IS NOT NULL),
           count(*) FILTER (
               WHERE attempt.challenge_team_damage_receipt_id IS NULL),
           COALESCE(sum(receipt.damage_value), 0),
           count(*) FILTER (
               WHERE attempt.entered_at_utc < revision_row.opened_at_utc
                  OR attempt.entered_at_utc > revision_row.updated_at_utc
                  OR (receipt.observed_at_utc IS NOT NULL AND (
                      receipt.observed_at_utc < attempt.entered_at_utc
                      OR receipt.observed_at_utc > revision_row.updated_at_utc
                  ))
           )
      INTO attempt_count, accepted_count, active_count, receipt_total,
           invalid_time_count
      FROM lab_private_server.challenge_run_revision_attempt attempt
      LEFT JOIN lab_private_server.challenge_team_damage_receipt receipt
        ON receipt.challenge_team_damage_receipt_id =
           attempt.challenge_team_damage_receipt_id
     WHERE attempt.challenge_run_revision_id = revision_id;

    IF invalid_time_count <> 0
       OR accepted_count <> revision_row.accepted_team_count
       OR receipt_total <> revision_row.cumulative_damage
       OR NOT (
           (revision_row.status = 'open'
                AND attempt_count = 0 AND active_count = 0)
           OR (revision_row.status = 'team_in_progress'
                AND attempt_count = revision_row.accepted_team_count + 1
                AND active_count = 1
                AND revision_row.active_team_ordinal = attempt_count)
           OR (revision_row.status IN (
                    'team_result_accepted', 'regroup_ready', 'completed'
                )
                AND attempt_count = revision_row.accepted_team_count
                AND attempt_count > 0 AND active_count = 0)
           OR (revision_row.status = 'abandoned'
                AND attempt_count IN (
                    revision_row.accepted_team_count,
                    revision_row.accepted_team_count + 1
                )
                AND active_count = attempt_count - revision_row.accepted_team_count)
       ) THEN
        RAISE EXCEPTION 'challenge_run_revision_attempt_graph_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_run_revision_attempt_graph_revision
AFTER INSERT ON lab_private_server.challenge_run_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_run_revision_attempt_graph();

CREATE CONSTRAINT TRIGGER trg_validate_run_revision_attempt_graph_attempt
AFTER INSERT ON lab_private_server.challenge_run_revision_attempt
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_run_revision_attempt_graph();

CREATE FUNCTION lab_private_server.guard_run_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    revision_row lab_private_server.challenge_run_revision%ROWTYPE;
BEGIN
    IF (NEW.challenge_run_uid, NEW.local_account_id, NEW.local_client_context_id,
        NEW.local_client_context_revision_id, NEW.selected_raid_season_revision_id,
        NEW.raid_season_directory_id, NEW.raid_snapshot_id,
        NEW.profile_template_revision_id, NEW.account_state_revision_id,
        NEW.runtime_execution_profile_revision_id, NEW.combat_control_profile_revision_id,
        NEW.challenge_policy_activation_revision_id,
        NEW.challenge_operational_policy_id, NEW.challenge_daily_state_id,
        NEW.admission_daily_state_revision_id,
        NEW.admission_daily_state_content_sha256, NEW.opening_raid_day_key,
        NEW.execution_lane, NEW.is_mock_battle, NEW.configured_team_count,
        NEW.opened_at_utc, NEW.binding_sha256)
       IS DISTINCT FROM
       (OLD.challenge_run_uid, OLD.local_account_id, OLD.local_client_context_id,
        OLD.local_client_context_revision_id, OLD.selected_raid_season_revision_id,
        OLD.raid_season_directory_id, OLD.raid_snapshot_id,
        OLD.profile_template_revision_id, OLD.account_state_revision_id,
        OLD.runtime_execution_profile_revision_id, OLD.combat_control_profile_revision_id,
        OLD.challenge_policy_activation_revision_id,
        OLD.challenge_operational_policy_id, OLD.challenge_daily_state_id,
        OLD.admission_daily_state_revision_id,
        OLD.admission_daily_state_content_sha256, OLD.opening_raid_day_key,
        OLD.execution_lane, OLD.is_mock_battle, OLD.configured_team_count,
        OLD.opened_at_utc, OLD.binding_sha256) THEN
        RAISE EXCEPTION 'challenge_run_pin_mutation';
    END IF;

    IF NEW.current_challenge_run_revision_id IS NULL
       OR NEW.current_challenge_run_revision_id IS NOT DISTINCT FROM
          OLD.current_challenge_run_revision_id THEN
        RAISE EXCEPTION 'challenge_run_head_pointer_not_advanced';
    END IF;
    SELECT * INTO STRICT revision_row
      FROM lab_private_server.challenge_run_revision
     WHERE challenge_run_revision_id = NEW.current_challenge_run_revision_id
       AND challenge_run_id = NEW.challenge_run_id;
    IF revision_row.revision_number <> NEW.state_version
       OR revision_row.status <> NEW.status
       OR revision_row.next_team_ordinal IS DISTINCT FROM NEW.next_team_ordinal
       OR revision_row.active_team_ordinal IS DISTINCT FROM NEW.active_team_ordinal
       OR revision_row.accepted_team_count <> NEW.accepted_team_count
       OR revision_row.cumulative_damage <> NEW.cumulative_damage
       OR revision_row.final_result_uid IS DISTINCT FROM NEW.final_result_uid
       OR revision_row.abandonment_uid IS DISTINCT FROM NEW.abandonment_uid
       OR revision_row.abandon_reason_code IS DISTINCT FROM NEW.abandon_reason_code
       OR revision_row.updated_at_utc <> NEW.updated_at_utc THEN
        RAISE EXCEPTION 'challenge_run_head_projection_mismatch';
    END IF;
    IF OLD.current_challenge_run_revision_id IS NULL THEN
        IF NEW.state_version <> 1 OR NEW.status <> 'open' THEN
            RAISE EXCEPTION 'challenge_run_initial_head_invalid';
        END IF;
    ELSIF OLD.status IN ('completed', 'abandoned')
       OR NEW.state_version <> OLD.state_version + 1
       OR revision_row.previous_challenge_run_revision_id <>
          OLD.current_challenge_run_revision_id THEN
        RAISE EXCEPTION 'challenge_run_revision_conflict';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_run_update
BEFORE UPDATE ON lab_private_server.challenge_run
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_run_update();

CREATE FUNCTION lab_private_server.validate_run_team_graph()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    run_id BIGINT := COALESCE(NEW.challenge_run_id, OLD.challenge_run_id);
    configured_count INTEGER;
    team_count INTEGER;
    min_ordinal INTEGER;
    max_ordinal INTEGER;
    invalid_member_count INTEGER;
BEGIN
    SELECT configured_team_count INTO STRICT configured_count
      FROM lab_private_server.challenge_run
     WHERE challenge_run_id = run_id;
    SELECT count(*), min(team_ordinal), max(team_ordinal)
      INTO team_count, min_ordinal, max_ordinal
      FROM lab_private_server.challenge_run_team
     WHERE challenge_run_id = run_id;
    SELECT count(*) INTO invalid_member_count
      FROM lab_private_server.challenge_run_team team
      JOIN lab_profile.squad_revision squad
        ON squad.squad_revision_id = team.squad_revision_id
     WHERE team.challenge_run_id = run_id
       AND (squad.selection_readiness_status <> 'ready'
         OR (SELECT count(*)
               FROM lab_private_server.challenge_run_team_member member
              WHERE member.challenge_run_id = team.challenge_run_id
                AND member.team_ordinal = team.team_ordinal) <> 5);
    IF team_count <> configured_count
       OR min_ordinal <> 1
       OR max_ordinal <> configured_count
       OR invalid_member_count <> 0 THEN
        RAISE EXCEPTION 'challenge_run_team_graph_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_run_team_graph_run
AFTER INSERT ON lab_private_server.challenge_run
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_run_team_graph();

CREATE CONSTRAINT TRIGGER trg_validate_run_team_graph_team
AFTER INSERT ON lab_private_server.challenge_run_team
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_run_team_graph();

CREATE CONSTRAINT TRIGGER trg_validate_run_team_graph_member
AFTER INSERT ON lab_private_server.challenge_run_team_member
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_run_team_graph();

CREATE FUNCTION lab_private_server.validate_damage_receipt()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    receipt_id BIGINT := COALESCE(
        NEW.challenge_team_damage_receipt_id,
        OLD.challenge_team_damage_receipt_id
    );
    receipt_row lab_private_server.challenge_team_damage_receipt%ROWTYPE;
    actual_segment_count INTEGER;
    actual_warning_count INTEGER;
    actual_telemetry_warning_count INTEGER;
    invalid_chain BOOLEAN;
    previous_damage NUMERIC(78, 0);
BEGIN
    SELECT * INTO STRICT receipt_row
      FROM lab_private_server.challenge_team_damage_receipt
     WHERE challenge_team_damage_receipt_id = receipt_id;
    SELECT count(*)
      INTO actual_segment_count
      FROM lab_private_server.challenge_execution_segment
     WHERE challenge_team_damage_receipt_id = receipt_id;
    SELECT count(*) INTO actual_warning_count
      FROM lab_private_server.challenge_team_damage_warning
     WHERE challenge_team_damage_receipt_id = receipt_id;
    SELECT count(*) INTO actual_telemetry_warning_count
      FROM lab_private_server.challenge_team_telemetry_warning
     WHERE challenge_team_damage_receipt_id = receipt_id;
    SELECT COALESCE(bool_or(
        segment_ordinal <> expected_ordinal
        OR start_render_frame <> expected_start_render_frame
        OR start_behavior_tick <> expected_start_behavior_tick
        OR start_fixed_update <> expected_start_fixed_update
        OR start_wall_clock_microseconds <> expected_start_wall_clock_microseconds
        OR start_damage <> expected_start_damage
    ), FALSE)
      INTO invalid_chain
      FROM (
          SELECT segment_ordinal,
                 row_number() OVER (ORDER BY segment_ordinal) AS expected_ordinal,
                 start_render_frame,
                 start_behavior_tick,
                 start_fixed_update,
                 start_wall_clock_microseconds,
                 start_damage,
                 COALESCE(
                     lag(end_render_frame) OVER (ORDER BY segment_ordinal),
                     0
                 ) AS expected_start_render_frame,
                 COALESCE(
                     lag(end_behavior_tick) OVER (ORDER BY segment_ordinal),
                     0
                 ) AS expected_start_behavior_tick,
                 COALESCE(
                     lag(end_fixed_update) OVER (ORDER BY segment_ordinal),
                     0
                 ) AS expected_start_fixed_update,
                 COALESCE(
                     lag(end_wall_clock_microseconds) OVER (ORDER BY segment_ordinal),
                     0
                 ) AS expected_start_wall_clock_microseconds,
                 COALESCE(
                     lag(end_damage) OVER (ORDER BY segment_ordinal),
                     0
                 ) AS expected_start_damage
            FROM lab_private_server.challenge_execution_segment
           WHERE challenge_team_damage_receipt_id = receipt_id
      ) ordered_segments;
    SELECT COALESCE(sum(damage_value), 0) INTO previous_damage
      FROM lab_private_server.challenge_team_damage_receipt
     WHERE challenge_run_id = receipt_row.challenge_run_id
       AND team_ordinal < receipt_row.team_ordinal;

    IF actual_segment_count <> receipt_row.segment_count
       OR actual_warning_count <> receipt_row.warning_count
       OR actual_telemetry_warning_count <> receipt_row.telemetry_warning_count
       OR invalid_chain
       OR EXISTS (
           SELECT 1
             FROM lab_private_server.challenge_execution_segment segment
             JOIN lab_private_server.challenge_run run
               ON run.challenge_run_id = segment.challenge_run_id
            WHERE segment.challenge_team_damage_receipt_id = receipt_id
              AND (segment.runtime_execution_profile_revision_id <>
                       run.runtime_execution_profile_revision_id
                OR segment.combat_control_profile_revision_id <>
                       run.combat_control_profile_revision_id)
       )
       OR NOT EXISTS (
           SELECT 1
             FROM lab_private_server.challenge_execution_segment
            WHERE challenge_team_damage_receipt_id = receipt_id
              AND segment_ordinal = receipt_row.segment_count
              AND end_render_frame = receipt_row.render_frame_count
              AND end_behavior_tick = receipt_row.behavior_tick_count
              AND end_fixed_update = receipt_row.fixed_update_count
              AND end_wall_clock_microseconds = receipt_row.wall_clock_microseconds
              AND end_damage = receipt_row.damage_value
       )
       OR NOT EXISTS (
           SELECT 1
             FROM lab_private_server.challenge_run_operation operation
             JOIN lab_private_server.challenge_run_revision revision
               ON revision.challenge_run_revision_id =
                  operation.result_challenge_run_revision_id
             JOIN lab_private_server.challenge_run_revision_attempt attempt
               ON attempt.challenge_run_revision_id =
                  revision.challenge_run_revision_id
              AND attempt.challenge_run_id = receipt_row.challenge_run_id
              AND attempt.team_ordinal = receipt_row.team_ordinal
              AND attempt.challenge_team_damage_receipt_id = receipt_id
              AND attempt.receipt_sha256 = receipt_row.receipt_sha256
            WHERE operation.operation_kind = 'accept_team_damage'
              AND operation.challenge_team_damage_receipt_id = receipt_id
              AND operation.result_status = 'team_result_accepted'
              AND operation.team_ordinal = receipt_row.team_ordinal
       )
       OR receipt_row.cumulative_damage_value <>
            previous_damage + receipt_row.damage_value THEN
        RAISE EXCEPTION 'challenge_damage_receipt_graph_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_damage_receipt_parent
AFTER INSERT ON lab_private_server.challenge_team_damage_receipt
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_damage_receipt();

CREATE CONSTRAINT TRIGGER trg_validate_damage_receipt_segment
AFTER INSERT ON lab_private_server.challenge_execution_segment
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_damage_receipt();

CREATE CONSTRAINT TRIGGER trg_validate_damage_receipt_warning
AFTER INSERT ON lab_private_server.challenge_team_damage_warning
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_damage_receipt();

CREATE CONSTRAINT TRIGGER trg_validate_damage_receipt_telemetry_warning
AFTER INSERT ON lab_private_server.challenge_team_telemetry_warning
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_damage_receipt();

CREATE FUNCTION lab_private_server.validate_run_result()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    receipt_count INTEGER;
    receipt_total NUMERIC(78, 0);
BEGIN
    SELECT count(*), COALESCE(sum(damage_value), 0)
      INTO receipt_count, receipt_total
      FROM lab_private_server.challenge_team_damage_receipt
     WHERE challenge_run_id = NEW.challenge_run_id;
    IF receipt_count <> NEW.accepted_team_count
       OR receipt_total <> NEW.total_damage
       OR NOT EXISTS (
           SELECT 1
             FROM lab_private_server.challenge_run_operation operation
             JOIN lab_private_server.challenge_run_revision revision
               ON revision.challenge_run_revision_id =
                  operation.result_challenge_run_revision_id
            WHERE operation.operation_kind = 'close_run'
              AND operation.challenge_run_result_id =
                  NEW.challenge_run_result_id
              AND operation.result_status = 'completed'
              AND revision.challenge_run_id = NEW.challenge_run_id
              AND revision.final_result_uid = NEW.challenge_run_result_uid
              AND revision.accepted_team_count = NEW.accepted_team_count
              AND revision.cumulative_damage = NEW.total_damage
              AND revision.updated_at_utc = NEW.completed_at_utc
       ) THEN
        RAISE EXCEPTION 'challenge_run_result_graph_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_run_result
AFTER INSERT ON lab_private_server.challenge_run_result
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_run_result();

CREATE FUNCTION lab_private_server.validate_run_operation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    run_row lab_private_server.challenge_run%ROWTYPE;
    policy_row lab_private_server.challenge_operational_policy%ROWTYPE;
    should_consume BOOLEAN;
    daily_revision lab_private_server.challenge_daily_state_revision%ROWTYPE;
    result_revision lab_private_server.challenge_run_revision%ROWTYPE;
    expected_revision lab_private_server.challenge_run_revision%ROWTYPE;
    requester_context lab_private_server.local_client_context_revision%ROWTYPE;
    requester_head BIGINT;
    requester_session lab_profile.local_session%ROWTYPE;
    owner_session lab_profile.local_session%ROWTYPE;
BEGIN
    SELECT * INTO STRICT run_row
      FROM lab_private_server.challenge_run
     WHERE challenge_run_uid = NEW.challenge_run_uid;
    SELECT * INTO STRICT policy_row
      FROM lab_private_server.challenge_operational_policy
     WHERE challenge_operational_policy_id = run_row.challenge_operational_policy_id;
    SELECT * INTO STRICT result_revision
      FROM lab_private_server.challenge_run_revision
     WHERE challenge_run_revision_id = NEW.result_challenge_run_revision_id;
    IF result_revision.challenge_run_uid <> NEW.challenge_run_uid
       OR result_revision.challenge_run_revision_uid <> NEW.result_run_revision_uid
       OR result_revision.content_sha256 <> NEW.result_run_content_sha256
       OR result_revision.revision_number <> NEW.result_state_version
       OR result_revision.status <> NEW.result_status
       OR result_revision.updated_at_utc <> NEW.completed_at_utc THEN
        RAISE EXCEPTION 'challenge_run_operation_result_revision_mismatch';
    END IF;
    IF (NEW.operation_kind = 'enter_team' AND (
            NEW.team_ordinal IS DISTINCT FROM result_revision.active_team_ordinal
            OR NOT EXISTS (
                SELECT 1
                  FROM lab_private_server.challenge_run_revision_attempt attempt
                 WHERE attempt.challenge_run_revision_id =
                       result_revision.challenge_run_revision_id
                   AND attempt.team_ordinal = NEW.team_ordinal
                   AND attempt.challenge_team_damage_receipt_id IS NULL
            )
        ))
       OR (NEW.operation_kind = 'accept_team_damage' AND (
            NEW.team_ordinal IS DISTINCT FROM result_revision.active_team_ordinal
            OR NOT EXISTS (
                SELECT 1
                  FROM lab_private_server.challenge_run_revision_attempt attempt
                 WHERE attempt.challenge_run_revision_id =
                       result_revision.challenge_run_revision_id
                   AND attempt.team_ordinal = NEW.team_ordinal
                   AND attempt.challenge_team_damage_receipt_id =
                       NEW.challenge_team_damage_receipt_id
            )
        ))
       OR (NEW.operation_kind = 'regroup' AND (
            NEW.team_ordinal IS DISTINCT FROM result_revision.accepted_team_count
            OR NOT EXISTS (
                SELECT 1
                  FROM lab_private_server.challenge_run_revision_attempt attempt
                 WHERE attempt.challenge_run_revision_id =
                       result_revision.challenge_run_revision_id
                   AND attempt.team_ordinal = NEW.team_ordinal
                   AND attempt.challenge_team_damage_receipt_id IS NOT NULL
            )
        )) THEN
        RAISE EXCEPTION 'challenge_run_operation_team_ordinal_mismatch';
    END IF;
    IF NEW.expected_run_revision_uid IS NULL THEN
        IF result_revision.revision_number <> 1
           OR result_revision.previous_challenge_run_revision_id IS NOT NULL THEN
            RAISE EXCEPTION 'challenge_run_operation_initial_revision_mismatch';
        END IF;
    ELSE
        SELECT * INTO STRICT expected_revision
          FROM lab_private_server.challenge_run_revision
         WHERE challenge_run_revision_uid = NEW.expected_run_revision_uid;
        IF expected_revision.challenge_run_uid <> NEW.challenge_run_uid
           OR expected_revision.revision_number <> NEW.expected_state_version
           OR result_revision.previous_challenge_run_revision_id <>
              expected_revision.challenge_run_revision_id THEN
            RAISE EXCEPTION 'challenge_run_operation_expected_revision_mismatch';
        END IF;
    END IF;

    should_consume := NOT run_row.is_mock_battle AND (
        (policy_row.entry_consumption_point = 'run_opened'
            AND NEW.operation_kind = 'open_run')
        OR (policy_row.entry_consumption_point = 'first_team_entered'
            AND NEW.operation_kind = 'enter_team' AND NEW.team_ordinal = 1)
        OR (policy_row.entry_consumption_point = 'run_closed'
            AND NEW.operation_kind = 'close_run')
        OR (policy_row.entry_consumption_point = 'run_closed'
            AND NEW.operation_kind IN ('abandon_run', 'recover_stranded_run')
            AND EXISTS (
                SELECT 1
                  FROM lab_private_server.challenge_run_operation prior_operation
                 WHERE prior_operation.challenge_run_uid = NEW.challenge_run_uid
                   AND prior_operation.operation_kind = 'enter_team'
            ))
    );
    IF NEW.consumed_daily_attempt <> should_consume THEN
        RAISE EXCEPTION 'challenge_run_operation_consumption_mismatch';
    END IF;

    IF NEW.operation_kind <> 'recover_stranded_run' THEN
        SELECT owner_session_row.* INTO STRICT owner_session
          FROM lab_private_server.local_client_context owner_context
          JOIN lab_profile.local_session owner_session_row
            ON owner_session_row.local_session_id = owner_context.local_session_id
         WHERE owner_context.local_client_context_id =
               run_row.local_client_context_id;
        IF owner_session.revoked_at_utc IS NOT NULL
           OR NEW.completed_at_utc < owner_session.issued_at_utc
           OR NEW.completed_at_utc >= owner_session.expires_at_utc THEN
            RAISE EXCEPTION 'challenge_run_operation_owner_session_inactive';
        END IF;
    ELSE
        SELECT * INTO STRICT requester_context
          FROM lab_private_server.local_client_context_revision
         WHERE local_client_context_revision_id =
               NEW.requesting_local_client_context_revision_id;
        SELECT context.current_local_client_context_revision_id
          INTO STRICT requester_head
          FROM lab_private_server.local_client_context context
         WHERE context.local_client_context_id =
               requester_context.local_client_context_id;
        SELECT session.* INTO STRICT requester_session
          FROM lab_private_server.local_client_context context
          JOIN lab_profile.local_session session
            ON session.local_session_id = context.local_session_id
         WHERE context.local_client_context_id =
               requester_context.local_client_context_id;
        SELECT owner_session_row.* INTO STRICT owner_session
          FROM lab_private_server.local_client_context owner_context
          JOIN lab_profile.local_session owner_session_row
            ON owner_session_row.local_session_id = owner_context.local_session_id
         WHERE owner_context.local_client_context_id = run_row.local_client_context_id;
        IF requester_context.local_account_id <> run_row.local_account_id
           OR NEW.requesting_local_account_id <> run_row.local_account_id
           OR requester_head <> NEW.requesting_local_client_context_revision_id
           OR requester_context.stage <> 'lobby_ready'
           OR requester_session.revoked_at_utc IS NOT NULL
           OR NEW.completed_at_utc < requester_session.issued_at_utc
           OR NEW.completed_at_utc >= requester_session.expires_at_utc
           OR NOT (
               owner_session.revoked_at_utc IS NOT NULL
               OR NEW.completed_at_utc >= owner_session.expires_at_utc
           ) THEN
            RAISE EXCEPTION 'challenge_stranded_run_recovery_not_authorized';
        END IF;
    END IF;

    IF should_consume THEN
        SELECT * INTO STRICT daily_revision
          FROM lab_private_server.challenge_daily_state_revision
         WHERE challenge_daily_state_revision_id = NEW.result_daily_state_revision_id;
        IF daily_revision.challenge_daily_state_id <> run_row.challenge_daily_state_id
           OR daily_revision.consumption_operation_uid <> NEW.operation_uid THEN
            RAISE EXCEPTION 'challenge_run_operation_daily_revision_mismatch';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_run_operation
AFTER INSERT OR UPDATE ON lab_private_server.challenge_run_operation
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_run_operation();

CREATE FUNCTION lab_private_server.validate_daily_consumption_operation_inverse()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.revision_number = 1 THEN
        RETURN NULL;
    END IF;
    IF (SELECT count(*)
          FROM lab_private_server.challenge_run_operation operation
          JOIN lab_private_server.challenge_run run
            ON run.challenge_run_uid = operation.challenge_run_uid
         WHERE operation.operation_uid = NEW.consumption_operation_uid
           AND operation.consumed_daily_attempt
           AND operation.result_daily_state_revision_id =
               NEW.challenge_daily_state_revision_id
           AND run.challenge_daily_state_id = NEW.challenge_daily_state_id
           AND run.local_account_id = NEW.local_account_id) <> 1 THEN
        RAISE EXCEPTION 'challenge_daily_consumption_operation_mismatch';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_daily_consumption_operation_inverse
AFTER INSERT ON lab_private_server.challenge_daily_state_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.validate_daily_consumption_operation_inverse();

CREATE FUNCTION lab_private_server.validate_run_revision_operation_inverse()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF (SELECT count(*)
          FROM lab_private_server.challenge_run_operation operation
         WHERE operation.result_challenge_run_revision_id =
               NEW.challenge_run_revision_id
           AND operation.challenge_run_uid = NEW.challenge_run_uid
           AND operation.result_run_revision_uid =
               NEW.challenge_run_revision_uid
           AND operation.result_run_content_sha256 = NEW.content_sha256
           AND operation.result_state_version = NEW.revision_number
           AND operation.result_status = NEW.status) <> 1 THEN
        RAISE EXCEPTION 'challenge_run_revision_operation_mismatch';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_run_revision_operation_inverse
AFTER INSERT ON lab_private_server.challenge_run_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.validate_run_revision_operation_inverse();

CREATE FUNCTION lab_private_server.validate_run_head()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    run_row lab_private_server.challenge_run%ROWTYPE;
    operation_row lab_private_server.challenge_run_operation%ROWTYPE;
    revision_row lab_private_server.challenge_run_revision%ROWTYPE;
BEGIN
    SELECT * INTO STRICT run_row
      FROM lab_private_server.challenge_run
     WHERE challenge_run_id = NEW.challenge_run_id;
    IF run_row.current_challenge_run_revision_id IS NULL THEN
        RAISE EXCEPTION 'challenge_run_head_missing';
    END IF;
    SELECT * INTO STRICT revision_row
      FROM lab_private_server.challenge_run_revision
     WHERE challenge_run_revision_id = run_row.current_challenge_run_revision_id;
    SELECT * INTO STRICT operation_row
      FROM lab_private_server.challenge_run_operation
     WHERE operation_uid = run_row.last_operation_uid;
    IF operation_row.challenge_run_uid <> run_row.challenge_run_uid
       OR operation_row.result_challenge_run_revision_id <>
          run_row.current_challenge_run_revision_id
       OR operation_row.result_run_revision_uid <>
          revision_row.challenge_run_revision_uid
       OR operation_row.result_run_content_sha256 <> revision_row.content_sha256
       OR operation_row.result_state_version <> run_row.state_version
       OR operation_row.result_status <> run_row.status THEN
        RAISE EXCEPTION 'challenge_run_operation_head_mismatch';
    END IF;
    IF run_row.status = 'team_result_accepted' AND NOT EXISTS (
        SELECT 1
          FROM lab_private_server.challenge_team_damage_receipt receipt
         WHERE receipt.challenge_team_damage_receipt_id =
               operation_row.challenge_team_damage_receipt_id
           AND receipt.challenge_run_id = run_row.challenge_run_id
           AND receipt.team_ordinal = run_row.active_team_ordinal
           AND receipt.cumulative_damage_value = run_row.cumulative_damage
    ) THEN
        RAISE EXCEPTION 'challenge_run_damage_head_mismatch';
    END IF;
    IF run_row.status = 'completed' AND NOT EXISTS (
        SELECT 1
          FROM lab_private_server.challenge_run_result result
         WHERE result.challenge_run_result_id = operation_row.challenge_run_result_id
           AND result.challenge_run_id = run_row.challenge_run_id
           AND result.challenge_run_result_uid = run_row.final_result_uid
           AND result.accepted_team_count = run_row.accepted_team_count
           AND result.total_damage = run_row.cumulative_damage
    ) THEN
        RAISE EXCEPTION 'challenge_run_result_head_mismatch';
    END IF;
    IF run_row.status = 'abandoned' AND (
        operation_row.operation_kind NOT IN ('abandon_run', 'recover_stranded_run')
        OR operation_row.abandonment_uid IS DISTINCT FROM run_row.abandonment_uid
        OR operation_row.abandon_reason_code IS DISTINCT FROM run_row.abandon_reason_code
    ) THEN
        RAISE EXCEPTION 'challenge_run_abandonment_head_mismatch';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_run_head
AFTER INSERT OR UPDATE ON lab_private_server.challenge_run
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_run_head();

CREATE FUNCTION lab_private_server.guard_application_build_selection_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    head_id BIGINT;
    previous_number INTEGER;
BEGIN
    SELECT current_application_build_selection_revision_id
      INTO head_id
      FROM lab_private_server.application_build_state
     WHERE singleton;
    IF NEW.revision_number = 1 THEN
        IF head_id IS NOT NULL
           OR NEW.previous_application_build_selection_revision_id IS NOT NULL THEN
            RAISE EXCEPTION 'application_build_initial_selection_invalid';
        END IF;
    ELSE
        SELECT revision_number INTO STRICT previous_number
          FROM lab_private_server.application_build_selection_revision
         WHERE application_build_selection_revision_id =
               NEW.previous_application_build_selection_revision_id;
        IF head_id IS DISTINCT FROM NEW.previous_application_build_selection_revision_id
           OR previous_number + 1 <> NEW.revision_number THEN
            RAISE EXCEPTION 'application_build_selection_conflict';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_application_build_selection_insert
BEFORE INSERT ON lab_private_server.application_build_selection_revision
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_application_build_selection_insert();

CREATE FUNCTION lab_private_server.validate_application_build_state_head()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_id BIGINT;
BEGIN
    SELECT application_build_selection_revision_id INTO expected_id
      FROM lab_private_server.application_build_selection_revision
     ORDER BY revision_number DESC LIMIT 1;
    IF expected_id IS NULL
       OR NEW.current_application_build_selection_revision_id IS DISTINCT FROM expected_id THEN
        RAISE EXCEPTION 'application_build_state_head_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_application_build_state_head
AFTER INSERT OR UPDATE ON lab_private_server.application_build_state
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_application_build_state_head();

CREATE FUNCTION lab_private_server.guard_aggregate_pointer_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    new_fixed JSONB := to_jsonb(NEW);
    old_fixed JSONB := to_jsonb(OLD);
    key TEXT;
BEGIN
    FOREACH key IN ARRAY TG_ARGV LOOP
        new_fixed := new_fixed - key;
        old_fixed := old_fixed - key;
    END LOOP;
    IF new_fixed IS DISTINCT FROM old_fixed THEN
        RAISE EXCEPTION 'private_server_aggregate_identity_mutation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_runtime_profile_pointer
BEFORE UPDATE ON lab_private_server.runtime_execution_profile
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_aggregate_pointer_update(
    'current_runtime_execution_profile_revision_id'
);

CREATE TRIGGER trg_guard_control_profile_pointer
BEFORE UPDATE ON lab_private_server.combat_control_profile
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_aggregate_pointer_update(
    'current_combat_control_profile_revision_id'
);

CREATE TRIGGER trg_guard_selection_pointer
BEFORE UPDATE ON lab_private_server.raid_season_selection
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_aggregate_pointer_update(
    'current_selected_raid_season_revision_id'
);

CREATE TRIGGER trg_guard_context_pointer
BEFORE UPDATE ON lab_private_server.local_client_context
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_aggregate_pointer_update(
    'current_local_client_context_revision_id'
);

CREATE TRIGGER trg_guard_daily_state_pointer
BEFORE UPDATE ON lab_private_server.challenge_daily_state
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_aggregate_pointer_update(
    'current_challenge_daily_state_revision_id'
);

CREATE TRIGGER trg_guard_policy_state_pointer
BEFORE UPDATE ON lab_private_server.challenge_policy_state
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_aggregate_pointer_update(
    'latest_scheduled_activation_revision_id', 'updated_at_utc'
);

CREATE TRIGGER trg_guard_application_build_state_pointer
BEFORE UPDATE ON lab_private_server.application_build_state
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_aggregate_pointer_update(
    'current_application_build_selection_revision_id', 'updated_at_utc'
);

CREATE TRIGGER trg_reject_policy_state_delete
BEFORE DELETE ON lab_private_server.challenge_policy_state
FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();

CREATE TRIGGER trg_reject_application_build_state_delete
BEFORE DELETE ON lab_private_server.application_build_state
FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();

DO $$
DECLARE
    immutable_table TEXT;
BEGIN
    FOREACH immutable_table IN ARRAY ARRAY[
        'challenge_operational_policy',
        'challenge_policy_activation_revision',
        'capability_manifest',
        'capability_manifest_entry',
        'application_build',
        'application_build_selection_revision',
        'raid_season_directory',
        'raid_season_directory_member',
        'runtime_execution_profile_revision',
        'runtime_execution_profile_fact',
        'combat_control_profile_revision',
        'combat_control_profile_fact',
        'selected_raid_season_revision',
        'local_client_context_revision',
        'challenge_daily_state_revision',
        'challenge_run_team',
        'challenge_run_team_member',
        'challenge_run_revision',
        'challenge_run_revision_attempt',
        'challenge_team_damage_receipt',
        'challenge_team_damage_warning',
        'challenge_team_telemetry_warning',
        'challenge_execution_segment',
        'challenge_run_result',
        'challenge_run_operation',
        'private_server_write_operation'
    ] LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_reject_immutable_mutation BEFORE UPDATE OR DELETE ON lab_private_server.%I FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation()',
            immutable_table
        );
    END LOOP;
END;
$$;

CREATE TRIGGER trg_reject_runtime_profile_delete
BEFORE DELETE ON lab_private_server.runtime_execution_profile
FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();

CREATE TRIGGER trg_reject_control_profile_delete
BEFORE DELETE ON lab_private_server.combat_control_profile
FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();

CREATE TRIGGER trg_reject_selection_delete
BEFORE DELETE ON lab_private_server.raid_season_selection
FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();

CREATE TRIGGER trg_reject_context_delete
BEFORE DELETE ON lab_private_server.local_client_context
FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();

CREATE TRIGGER trg_reject_daily_state_delete
BEFORE DELETE ON lab_private_server.challenge_daily_state
FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();

CREATE TRIGGER trg_reject_run_delete
BEFORE DELETE ON lab_private_server.challenge_run
FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();

CREATE FUNCTION lab_private_server.validate_revision_head_from_revision()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    aggregate_id BIGINT := (to_jsonb(NEW) ->> TG_ARGV[1])::bigint;
    head_id BIGINT;
    expected_id BIGINT;
BEGIN
    EXECUTE format(
        'SELECT %I FROM lab_private_server.%I WHERE %I = $1',
        TG_ARGV[2], TG_ARGV[0], TG_ARGV[1]
    ) INTO head_id USING aggregate_id;
    EXECUTE format(
        'SELECT %I FROM lab_private_server.%I WHERE %I = $1 ORDER BY revision_number DESC LIMIT 1',
        TG_ARGV[4], TG_ARGV[3], TG_ARGV[1]
    ) INTO expected_id USING aggregate_id;
    IF expected_id IS NULL OR head_id IS DISTINCT FROM expected_id THEN
        RAISE EXCEPTION 'private_server_revision_head_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_runtime_head_from_revision
AFTER INSERT ON lab_private_server.runtime_execution_profile_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_revision_head_from_revision(
    'runtime_execution_profile', 'runtime_execution_profile_id',
    'current_runtime_execution_profile_revision_id',
    'runtime_execution_profile_revision', 'runtime_execution_profile_revision_id'
);

CREATE CONSTRAINT TRIGGER trg_validate_control_head_from_revision
AFTER INSERT ON lab_private_server.combat_control_profile_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_revision_head_from_revision(
    'combat_control_profile', 'combat_control_profile_id',
    'current_combat_control_profile_revision_id',
    'combat_control_profile_revision', 'combat_control_profile_revision_id'
);

CREATE CONSTRAINT TRIGGER trg_validate_selection_head_from_revision
AFTER INSERT ON lab_private_server.selected_raid_season_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_revision_head_from_revision(
    'raid_season_selection', 'raid_season_selection_id',
    'current_selected_raid_season_revision_id',
    'selected_raid_season_revision', 'selected_raid_season_revision_id'
);

CREATE CONSTRAINT TRIGGER trg_validate_context_head_from_revision
AFTER INSERT ON lab_private_server.local_client_context_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_revision_head_from_revision(
    'local_client_context', 'local_client_context_id',
    'current_local_client_context_revision_id',
    'local_client_context_revision', 'local_client_context_revision_id'
);

CREATE CONSTRAINT TRIGGER trg_validate_daily_head_from_revision
AFTER INSERT ON lab_private_server.challenge_daily_state_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_revision_head_from_revision(
    'challenge_daily_state', 'challenge_daily_state_id',
    'current_challenge_daily_state_revision_id',
    'challenge_daily_state_revision', 'challenge_daily_state_revision_id'
);

CREATE CONSTRAINT TRIGGER trg_validate_run_head_from_revision
AFTER INSERT ON lab_private_server.challenge_run_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_revision_head_from_revision(
    'challenge_run', 'challenge_run_id',
    'current_challenge_run_revision_id',
    'challenge_run_revision', 'challenge_run_revision_id'
);

CREATE FUNCTION lab_private_server.validate_global_revision_head()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    head_id BIGINT;
    expected_id BIGINT;
BEGIN
    EXECUTE format(
        'SELECT %I FROM lab_private_server.%I WHERE singleton',
        TG_ARGV[1], TG_ARGV[0]
    ) INTO head_id;
    EXECUTE format(
        'SELECT %I FROM lab_private_server.%I ORDER BY revision_number DESC LIMIT 1',
        TG_ARGV[3], TG_ARGV[2]
    ) INTO expected_id;
    IF expected_id IS NULL OR head_id IS DISTINCT FROM expected_id THEN
        RAISE EXCEPTION 'private_server_global_revision_head_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_policy_head_from_revision
AFTER INSERT ON lab_private_server.challenge_policy_activation_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_global_revision_head(
    'challenge_policy_state', 'latest_scheduled_activation_revision_id',
    'challenge_policy_activation_revision', 'challenge_policy_activation_revision_id'
);

CREATE CONSTRAINT TRIGGER trg_validate_application_build_head_from_revision
AFTER INSERT ON lab_private_server.application_build_selection_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_global_revision_head(
    'application_build_state', 'current_application_build_selection_revision_id',
    'application_build_selection_revision', 'application_build_selection_revision_id'
);

CREATE FUNCTION lab_private_server.guard_boot_revision_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    head_id BIGINT;
    previous_row lab_private_server.private_server_boot_revision%ROWTYPE;
    selected_application_revision_id BIGINT;
    activation_effective_day DATE;
BEGIN
    SELECT latest_scheduled_boot_revision_id INTO head_id
      FROM lab_private_server.private_server_boot_state
     WHERE singleton;
    SELECT current_application_build_selection_revision_id
      INTO STRICT selected_application_revision_id
      FROM lab_private_server.application_build_state
     WHERE singleton;
    IF selected_application_revision_id <>
       NEW.application_build_selection_revision_id THEN
        RAISE EXCEPTION 'private_server_boot_application_selection_mismatch';
    END IF;
    SELECT effective_raid_day_key INTO STRICT activation_effective_day
      FROM lab_private_server.challenge_policy_activation_revision
     WHERE challenge_policy_activation_revision_id =
           NEW.challenge_policy_activation_revision_id;
    IF activation_effective_day <> NEW.effective_raid_day_key THEN
        RAISE EXCEPTION 'private_server_boot_policy_effective_day_mismatch';
    END IF;

    IF NEW.revision_number = 1 THEN
        IF head_id IS NOT NULL
           OR NEW.previous_private_server_boot_revision_id IS NOT NULL
           OR NEW.effective_raid_day_key <>
              lab_private_server.raid_day_key(NEW.materialized_at_utc) THEN
            RAISE EXCEPTION 'private_server_boot_initial_revision_invalid';
        END IF;
    ELSE
        SELECT * INTO STRICT previous_row
          FROM lab_private_server.private_server_boot_revision
         WHERE private_server_boot_revision_id =
               NEW.previous_private_server_boot_revision_id;
        IF head_id IS DISTINCT FROM NEW.previous_private_server_boot_revision_id
           OR previous_row.revision_number + 1 <> NEW.revision_number
           OR NEW.effective_raid_day_key < previous_row.effective_raid_day_key
           OR NEW.effective_raid_day_key <
              lab_private_server.raid_day_key(NEW.materialized_at_utc) + 1
           OR NEW.materialized_at_utc < previous_row.materialized_at_utc THEN
            RAISE EXCEPTION 'private_server_boot_revision_conflict';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_boot_revision_insert
BEFORE INSERT ON lab_private_server.private_server_boot_revision
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_boot_revision_insert();

CREATE FUNCTION lab_private_server.validate_boot_state_head()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_id BIGINT;
BEGIN
    SELECT private_server_boot_revision_id INTO expected_id
      FROM lab_private_server.private_server_boot_revision
     ORDER BY revision_number DESC LIMIT 1;
    IF expected_id IS NULL OR NEW.latest_scheduled_boot_revision_id IS DISTINCT FROM expected_id THEN
        RAISE EXCEPTION 'private_server_boot_state_head_invalid';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_boot_state_head
AFTER INSERT OR UPDATE ON lab_private_server.private_server_boot_state
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_boot_state_head();

CREATE CONSTRAINT TRIGGER trg_validate_boot_head_from_revision
AFTER INSERT ON lab_private_server.private_server_boot_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_private_server.validate_global_revision_head(
    'private_server_boot_state', 'latest_scheduled_boot_revision_id',
    'private_server_boot_revision', 'private_server_boot_revision_id'
);

CREATE TRIGGER trg_guard_boot_state_pointer
BEFORE UPDATE ON lab_private_server.private_server_boot_state
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_aggregate_pointer_update(
    'latest_scheduled_boot_revision_id', 'updated_at_utc'
);

CREATE TRIGGER trg_reject_boot_revision_mutation
BEFORE UPDATE OR DELETE ON lab_private_server.private_server_boot_revision
FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();

CREATE TRIGGER trg_reject_boot_state_delete
BEFORE DELETE ON lab_private_server.private_server_boot_state
FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();
