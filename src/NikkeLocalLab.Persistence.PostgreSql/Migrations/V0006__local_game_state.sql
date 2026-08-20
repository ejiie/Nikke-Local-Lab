CREATE SCHEMA lab_local_game;

CREATE FUNCTION lab_local_game.valid_fact(
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
        ELSE FALSE
    END;
$$;

CREATE FUNCTION lab_local_game.valid_lobby_display_name(value TEXT)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
    SELECT char_length(value) BETWEEN 1 AND 32
       AND value = normalize(value, NFC)
       AND ascii(left(value, 1)) NOT IN (
           9, 10, 11, 12, 13, 32, 133, 160, 5760,
           8192, 8193, 8194, 8195, 8196, 8197, 8198, 8199, 8200, 8201, 8202,
           8232, 8233, 8239, 8287, 12288
       )
       AND ascii(right(value, 1)) NOT IN (
           9, 10, 11, 12, 13, 32, 133, 160, 5760,
           8192, 8193, 8194, 8195, 8196, 8197, 8198, 8199, 8200, 8201, 8202,
           8232, 8233, 8239, 8287, 12288
       )
       AND position('/' in value) = 0
       AND position(E'\\' in value) = 0
       AND position(':' in value) = 0
       AND NOT EXISTS (
           SELECT 1
           FROM generate_series(1, char_length(value)) AS scalar_position(index)
           CROSS JOIN LATERAL (
               SELECT ascii(substring(value FROM scalar_position.index FOR 1)) AS code_point
           ) AS scalar
           WHERE scalar.code_point BETWEEN 0 AND 31
              OR scalar.code_point BETWEEN 127 AND 159
              OR scalar.code_point IN (
                  173, 1564, 1757, 1807, 2192, 2193, 2274, 6068, 6069, 6158,
                  8203, 8204, 8205, 8206, 8207, 8288, 8289, 8290, 8291, 8292,
                  65279, 65529, 65530, 65531, 69821, 69837, 917505
              )
              OR scalar.code_point BETWEEN 1536 AND 1541
              OR scalar.code_point BETWEEN 8234 AND 8238
              OR scalar.code_point BETWEEN 8294 AND 8303
              OR scalar.code_point BETWEEN 78896 AND 78911
              OR scalar.code_point BETWEEN 113824 AND 113827
              OR scalar.code_point BETWEEN 119155 AND 119162
              OR scalar.code_point BETWEEN 917536 AND 917631
       );
$$;

CREATE TABLE lab_local_game.lobby_presentation_revision (
    lobby_presentation_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lobby_presentation_revision_uid UUID NOT NULL UNIQUE CHECK (
        lobby_presentation_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_account_id BIGINT NOT NULL
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    revision_number INTEGER NOT NULL CHECK (revision_number >= 1),
    previous_lobby_presentation_revision_id BIGINT,
    validated_profile_template_revision_id BIGINT NOT NULL,
    character_catalog_snapshot_id BIGINT NOT NULL,
    display_name TEXT NOT NULL CHECK (
        lab_local_game.valid_lobby_display_name(display_name)
    ),
    commander_level_status TEXT NOT NULL CHECK (
        commander_level_status IN ('ready', 'unresolved')
    ),
    commander_level INTEGER CHECK (commander_level BETWEEN 1 AND 1000000),
    commander_level_unresolved_reason_code TEXT CHECK (
        commander_level_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    lobby_character_status TEXT NOT NULL CHECK (
        lobby_character_status IN ('ready', 'unresolved')
    ),
    lobby_character_entity_id BIGINT,
    lobby_character_definition_version_id BIGINT,
    lobby_character_unresolved_reason_code TEXT CHECK (
        lobby_character_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    profile_icon_status TEXT NOT NULL CHECK (
        profile_icon_status IN ('ready', 'unresolved')
    ),
    profile_icon_selection_uid UUID CHECK (
        profile_icon_selection_uid IS NULL
        OR profile_icon_selection_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    profile_icon_unresolved_reason_code TEXT CHECK (
        profile_icon_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    profile_frame_status TEXT NOT NULL CHECK (
        profile_frame_status IN ('ready', 'unresolved')
    ),
    profile_frame_selection_uid UUID CHECK (
        profile_frame_selection_uid IS NULL
        OR profile_frame_selection_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    profile_frame_unresolved_reason_code TEXT CHECK (
        profile_frame_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    lobby_background_status TEXT NOT NULL CHECK (
        lobby_background_status IN ('ready', 'unresolved')
    ),
    lobby_background_selection_uid UUID CHECK (
        lobby_background_selection_uid IS NULL
        OR lobby_background_selection_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    lobby_background_unresolved_reason_code TEXT CHECK (
        lobby_background_unresolved_reason_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    revision_origin TEXT NOT NULL CHECK (
        revision_origin IN (
            'system_default', 'user_edit', 'offline_sanitized_import', 'rebase'
        )
    ),
    materialized_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (local_account_id, revision_number),
    UNIQUE (lobby_presentation_revision_id, local_account_id),
    FOREIGN KEY (previous_lobby_presentation_revision_id, local_account_id)
        REFERENCES lab_local_game.lobby_presentation_revision(
            lobby_presentation_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (validated_profile_template_revision_id, local_account_id)
        REFERENCES lab_profile.profile_template_revision(
            profile_template_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (
        character_catalog_snapshot_id,
        lobby_character_entity_id,
        lobby_character_definition_version_id
    ) REFERENCES lab_catalog.character_catalog_snapshot_member(
        character_catalog_snapshot_id,
        character_entity_id,
        character_definition_version_id
    ) ON DELETE RESTRICT,
    CHECK (
        (revision_number = 1 AND previous_lobby_presentation_revision_id IS NULL)
        OR (revision_number > 1 AND previous_lobby_presentation_revision_id IS NOT NULL)
    ),
    CHECK (lab_local_game.valid_fact(
        commander_level_status,
        commander_level IS NOT NULL,
        commander_level_unresolved_reason_code
    )),
    CHECK (lab_local_game.valid_fact(
        lobby_character_status,
        lobby_character_entity_id IS NOT NULL
            AND lobby_character_definition_version_id IS NOT NULL,
        lobby_character_unresolved_reason_code
    )),
    CHECK (lab_local_game.valid_fact(
        profile_icon_status,
        profile_icon_selection_uid IS NOT NULL,
        profile_icon_unresolved_reason_code
    )),
    CHECK (lab_local_game.valid_fact(
        profile_frame_status,
        profile_frame_selection_uid IS NOT NULL,
        profile_frame_unresolved_reason_code
    )),
    CHECK (lab_local_game.valid_fact(
        lobby_background_status,
        lobby_background_selection_uid IS NOT NULL,
        lobby_background_unresolved_reason_code
    ))
);

CREATE TABLE lab_local_game.wallet_revision (
    wallet_revision_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wallet_revision_uid UUID NOT NULL UNIQUE CHECK (
        wallet_revision_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_account_id BIGINT NOT NULL
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    revision_number INTEGER NOT NULL CHECK (revision_number >= 1),
    previous_wallet_revision_id BIGINT,
    balance_count SMALLINT NOT NULL CHECK (balance_count = 2),
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    revision_origin TEXT NOT NULL CHECK (
        revision_origin IN (
            'system_default', 'user_edit', 'offline_sanitized_import', 'rebase'
        )
    ),
    materialized_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (local_account_id, revision_number),
    UNIQUE (wallet_revision_id, local_account_id),
    FOREIGN KEY (previous_wallet_revision_id, local_account_id)
        REFERENCES lab_local_game.wallet_revision(
            wallet_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    CHECK (
        (revision_number = 1 AND previous_wallet_revision_id IS NULL)
        OR (revision_number > 1 AND previous_wallet_revision_id IS NOT NULL)
    )
);

CREATE TABLE lab_local_game.wallet_balance (
    wallet_revision_id BIGINT NOT NULL
        REFERENCES lab_local_game.wallet_revision(wallet_revision_id) ON DELETE RESTRICT,
    currency_code TEXT NOT NULL CHECK (currency_code IN ('jewel', 'credit')),
    amount BIGINT NOT NULL CHECK (amount >= 0),
    PRIMARY KEY (wallet_revision_id, currency_code)
);

CREATE TABLE lab_local_game.client_feature_manifest (
    client_feature_manifest_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_feature_manifest_uid UUID NOT NULL UNIQUE CHECK (
        client_feature_manifest_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    contract_version TEXT NOT NULL CHECK (
        contract_version ~ '^nll/client-feature-manifest/v[1-9][0-9]*$'
        AND char_length(contract_version) <= 64
    ),
    entry_count INTEGER NOT NULL CHECK (entry_count > 0),
    content_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(content_sha256) = 32),
    published_at_utc TIMESTAMPTZ NOT NULL
);

CREATE TABLE lab_local_game.client_feature_manifest_entry (
    client_feature_manifest_id BIGINT NOT NULL
        REFERENCES lab_local_game.client_feature_manifest(client_feature_manifest_id)
        ON DELETE RESTRICT,
    route_code TEXT NOT NULL CHECK (route_code ~ '^[a-z][a-z0-9._-]{0,95}$'),
    capability_code TEXT NOT NULL CHECK (
        capability_code IN ('supported', 'hidden', 'visible_no_op', 'not_supported')
    ),
    PRIMARY KEY (client_feature_manifest_id, route_code)
);

CREATE TABLE lab_local_game.account_client_state (
    local_account_id BIGINT PRIMARY KEY
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    current_lobby_presentation_revision_id BIGINT NOT NULL,
    current_wallet_revision_id BIGINT NOT NULL,
    current_client_feature_manifest_id BIGINT NOT NULL
        REFERENCES lab_local_game.client_feature_manifest(client_feature_manifest_id)
        ON DELETE RESTRICT,
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (local_account_id, current_lobby_presentation_revision_id),
    UNIQUE (local_account_id, current_wallet_revision_id),
    FOREIGN KEY (current_lobby_presentation_revision_id, local_account_id)
        REFERENCES lab_local_game.lobby_presentation_revision(
            lobby_presentation_revision_id,
            local_account_id
        ) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (current_wallet_revision_id, local_account_id)
        REFERENCES lab_local_game.wallet_revision(
            wallet_revision_id,
            local_account_id
        ) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE lab_local_game.client_state_write_operation (
    client_state_write_operation_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_uid UUID NOT NULL UNIQUE CHECK (
        operation_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    operation_kind TEXT NOT NULL CHECK (
        operation_kind IN (
            'publish_feature_manifest', 'initialize', 'save_lobby', 'save_wallet'
        )
    ),
    request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256) = 32),
    local_account_id BIGINT
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    expected_revision_uid UUID,
    result_lobby_presentation_revision_id BIGINT,
    result_wallet_revision_id BIGINT,
    result_client_feature_manifest_id BIGINT,
    completed_at_utc TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (result_lobby_presentation_revision_id, local_account_id)
        REFERENCES lab_local_game.lobby_presentation_revision(
            lobby_presentation_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (result_wallet_revision_id, local_account_id)
        REFERENCES lab_local_game.wallet_revision(
            wallet_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    FOREIGN KEY (result_client_feature_manifest_id)
        REFERENCES lab_local_game.client_feature_manifest(client_feature_manifest_id)
        ON DELETE RESTRICT,
    CHECK (
        (operation_kind = 'publish_feature_manifest'
            AND local_account_id IS NULL
            AND expected_revision_uid IS NULL
            AND result_lobby_presentation_revision_id IS NULL
            AND result_wallet_revision_id IS NULL
            AND result_client_feature_manifest_id IS NOT NULL)
        OR (operation_kind = 'initialize'
            AND local_account_id IS NOT NULL
            AND expected_revision_uid IS NULL
            AND result_lobby_presentation_revision_id IS NOT NULL
            AND result_wallet_revision_id IS NOT NULL
            AND result_client_feature_manifest_id IS NOT NULL)
        OR (operation_kind = 'save_lobby'
            AND local_account_id IS NOT NULL
            AND expected_revision_uid IS NOT NULL
            AND result_lobby_presentation_revision_id IS NOT NULL
            AND result_wallet_revision_id IS NULL
            AND result_client_feature_manifest_id IS NULL)
        OR (operation_kind = 'save_wallet'
            AND local_account_id IS NOT NULL
            AND expected_revision_uid IS NOT NULL
            AND result_lobby_presentation_revision_id IS NULL
            AND result_wallet_revision_id IS NOT NULL
            AND result_client_feature_manifest_id IS NULL)
    )
);

CREATE TABLE lab_local_game.sanitized_profile_draft (
    sanitized_profile_draft_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sanitized_profile_draft_uid UUID NOT NULL UNIQUE CHECK (
        sanitized_profile_draft_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    derivation_kind TEXT NOT NULL CHECK (
        derivation_kind IN ('offline_sanitized_import', 'rebase', 'reviewed_override')
    ),
    previous_sanitized_profile_draft_id BIGINT
        REFERENCES lab_local_game.sanitized_profile_draft(sanitized_profile_draft_id)
        ON DELETE RESTRICT,
    payload_schema_code TEXT NOT NULL CHECK (
        payload_schema_code = 'nll/sanitized-profile-draft/v1'
    ),
    sanitizer_contract_sha256 BYTEA NOT NULL CHECK (
        octet_length(sanitizer_contract_sha256) = 32
    ),
    transformer_sha256 BYTEA NOT NULL CHECK (
        octet_length(transformer_sha256) = 32
    ),
    semantic_options_sha256 BYTEA NOT NULL CHECK (
        octet_length(semantic_options_sha256) = 32
    ),
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
    canonical_payload_json TEXT NOT NULL CHECK (
        octet_length(canonical_payload_json) BETWEEN 2 AND 67108864
        AND jsonb_typeof(canonical_payload_json::jsonb) = 'object'
    ),
    canonical_payload_sha256 BYTEA NOT NULL CHECK (
        octet_length(canonical_payload_sha256) = 32
    ),
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE NULLS NOT DISTINCT (
        derivation_kind,
        previous_sanitized_profile_draft_id,
        payload_schema_code,
        sanitizer_contract_sha256,
        transformer_sha256,
        semantic_options_sha256,
        canonical_payload_sha256
    ),
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
        (derivation_kind = 'offline_sanitized_import'
            AND previous_sanitized_profile_draft_id IS NULL)
        OR (derivation_kind = 'rebase'
            AND previous_sanitized_profile_draft_id IS NOT NULL)
        OR (derivation_kind = 'reviewed_override'
            AND previous_sanitized_profile_draft_id IS NOT NULL)
    ),
    CHECK (
        encode(sanitizer_contract_sha256, 'hex') =
            canonical_payload_json::jsonb #>> '{provenance,source_schema_sha256}'
        AND encode(transformer_sha256, 'hex') =
            canonical_payload_json::jsonb #>> '{provenance,transformer_binary_sha256}'
        AND encode(semantic_options_sha256, 'hex') =
            canonical_payload_json::jsonb #>> '{provenance,semantic_options_sha256}'
    ),
    CHECK (
        (derivation_kind = 'offline_sanitized_import'
            AND canonical_payload_json::jsonb #>> '{provenance,transformer_id}' =
                'offline-profile-sanitizer'
            AND canonical_payload_json::jsonb #>> '{provenance,transformer_version}' = 'v1'
            AND sanitizer_contract_sha256 = decode(
                '04f8414dc047ae761956f1f04289c826611bc97f523426da3ef9abbf83cfc509',
                'hex'
            )
            AND canonical_payload_json::jsonb #>>
                    '{provenance,transformer_fingerprint_sha256}' =
                'adf6d7061ae2274a578891681dec61b94851c64668f729a03cb7586a43b27c1b')
        OR (derivation_kind = 'rebase'
            AND canonical_payload_json::jsonb #>> '{provenance,transformer_id}' =
                'profile-catalog-rebase'
            AND canonical_payload_json::jsonb #>> '{provenance,transformer_version}' = 'v1'
            AND sanitizer_contract_sha256 = decode(
                'ca4d9b8e9f9ea9dad229ee86184be5468117bd8c5f0b5ec64a38cf9ee1a54809',
                'hex'
            )
            AND canonical_payload_json::jsonb #>>
                    '{provenance,transformer_fingerprint_sha256}' =
                'ea5bad4d95fc94fc8c12175b65877b0efbb6c0c863a6b205727607aa8d0bb147')
        OR (derivation_kind = 'reviewed_override'
            AND canonical_payload_json::jsonb #>> '{provenance,transformer_id}' =
                'profile-reviewed-override'
            AND canonical_payload_json::jsonb #>> '{provenance,transformer_version}' = 'v1'
            AND sanitizer_contract_sha256 = decode(
                '808b59e9d05340fe9849309acb3c783ad50f5379e64abaa0e2e372a9540ec524',
                'hex'
            )
            AND canonical_payload_json::jsonb #>>
                    '{provenance,transformer_fingerprint_sha256}' =
                'fee22f6faf49c6965e30f5de53d30f68420020aa9b0766e4f4cb63e7e58e5826')
    )
);

CREATE TABLE lab_local_game.sanitized_import_operation (
    sanitized_import_operation_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_uid UUID NOT NULL UNIQUE CHECK (
        operation_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    operation_kind TEXT NOT NULL CHECK (
        operation_kind IN ('sanitize', 'rebase', 'reviewed_override')
    ),
    request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256) = 32),
    result_draft_id BIGINT NOT NULL
        REFERENCES lab_local_game.sanitized_profile_draft(sanitized_profile_draft_id)
        ON DELETE RESTRICT,
    result_status TEXT NOT NULL CHECK (result_status IN ('succeeded', 'reused')),
    completed_at_utc TIMESTAMPTZ NOT NULL
);

CREATE TABLE lab_local_game.profile_edit_candidate (
    profile_edit_candidate_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    profile_edit_candidate_uid UUID NOT NULL UNIQUE CHECK (
        profile_edit_candidate_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    operation_uid UUID NOT NULL UNIQUE CHECK (
        operation_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256) = 32),
    local_account_id BIGINT NOT NULL
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    base_profile_template_revision_id BIGINT NOT NULL,
    candidate_contract_version TEXT NOT NULL CHECK (
        candidate_contract_version = 'nll/profile-edit-candidate/v1'
    ),
    canonical_operations_json TEXT NOT NULL CHECK (
        octet_length(canonical_operations_json) BETWEEN 2 AND 67108864
        AND jsonb_typeof(canonical_operations_json::jsonb) = 'object'
    ),
    canonical_operations_sha256 BYTEA NOT NULL CHECK (
        octet_length(canonical_operations_sha256) = 32
    ),
    operation_count INTEGER NOT NULL CHECK (operation_count BETWEEN 0 AND 512),
    created_at_utc TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (base_profile_template_revision_id, local_account_id)
        REFERENCES lab_profile.profile_template_revision(
            profile_template_revision_id,
            local_account_id
        ) ON DELETE RESTRICT
);

CREATE TABLE lab_local_game.profile_draft_diff (
    profile_draft_diff_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    profile_draft_diff_uid UUID NOT NULL UNIQUE CHECK (
        profile_draft_diff_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256) = 32),
    sanitized_profile_draft_id BIGINT
        REFERENCES lab_local_game.sanitized_profile_draft(sanitized_profile_draft_id)
        ON DELETE RESTRICT,
    profile_edit_candidate_id BIGINT
        REFERENCES lab_local_game.profile_edit_candidate(profile_edit_candidate_id)
        ON DELETE RESTRICT,
    local_account_id BIGINT
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    base_profile_template_revision_id BIGINT,
    diff_contract_version TEXT NOT NULL CHECK (
        diff_contract_version ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    canonical_diff_json TEXT NOT NULL CHECK (
        octet_length(canonical_diff_json) BETWEEN 2 AND 67108864
        AND jsonb_typeof(canonical_diff_json::jsonb) = 'object'
    ),
    canonical_diff_sha256 BYTEA NOT NULL CHECK (
        octet_length(canonical_diff_sha256) = 32
    ),
    change_count INTEGER NOT NULL CHECK (change_count >= 0),
    has_conflicts BOOLEAN NOT NULL,
    created_at_utc TIMESTAMPTZ NOT NULL,
    CHECK (num_nonnulls(sanitized_profile_draft_id, profile_edit_candidate_id) = 1),
    CHECK (
        (local_account_id IS NOT NULL
            AND base_profile_template_revision_id IS NOT NULL)
        OR (local_account_id IS NULL
            AND base_profile_template_revision_id IS NULL
            AND sanitized_profile_draft_id IS NOT NULL)
    ),
    FOREIGN KEY (base_profile_template_revision_id, local_account_id)
        REFERENCES lab_profile.profile_template_revision(
            profile_template_revision_id,
            local_account_id
        ) ON DELETE RESTRICT
);

CREATE TABLE lab_local_game.profile_draft_application_intent (
    profile_draft_application_intent_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_uid UUID NOT NULL UNIQUE CHECK (
        application_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256) = 32),
    application_kind TEXT NOT NULL CHECK (
        application_kind IN ('apply', 'save_as', 'rebase', 'create')
    ),
    profile_draft_diff_id BIGINT NOT NULL
        REFERENCES lab_local_game.profile_draft_diff(profile_draft_diff_id)
        ON DELETE RESTRICT,
    profile_write_operation_uid UUID NOT NULL UNIQUE CHECK (
        profile_write_operation_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    requested_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (
        profile_draft_application_intent_id,
        application_uid,
        application_kind,
        profile_draft_diff_id,
        profile_write_operation_uid
    )
);

CREATE TABLE lab_local_game.profile_draft_application (
    profile_draft_application_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_uid UUID NOT NULL UNIQUE CHECK (
        application_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256) = 32),
    profile_draft_application_intent_id BIGINT NOT NULL UNIQUE,
    application_kind TEXT NOT NULL CHECK (
        application_kind IN ('apply', 'save_as', 'rebase', 'create')
    ),
    profile_draft_diff_id BIGINT NOT NULL
        REFERENCES lab_local_game.profile_draft_diff(profile_draft_diff_id)
        ON DELETE RESTRICT,
    profile_write_operation_id BIGINT NOT NULL UNIQUE
        REFERENCES lab_profile.profile_write_operation(profile_write_operation_id)
        ON DELETE RESTRICT,
    profile_write_operation_uid UUID NOT NULL UNIQUE CHECK (
        profile_write_operation_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    source_local_account_id BIGINT
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    source_base_profile_template_revision_id BIGINT,
    result_local_account_id BIGINT NOT NULL
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    result_profile_template_revision_id BIGINT NOT NULL,
    applied_at_utc TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (
        profile_draft_application_intent_id,
        application_uid,
        application_kind,
        profile_draft_diff_id,
        profile_write_operation_uid
    ) REFERENCES lab_local_game.profile_draft_application_intent(
        profile_draft_application_intent_id,
        application_uid,
        application_kind,
        profile_draft_diff_id,
        profile_write_operation_uid
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        source_base_profile_template_revision_id,
        source_local_account_id
    ) REFERENCES lab_profile.profile_template_revision(
        profile_template_revision_id,
        local_account_id
    ) ON DELETE RESTRICT,
    FOREIGN KEY (result_profile_template_revision_id, result_local_account_id)
        REFERENCES lab_profile.profile_template_revision(
            profile_template_revision_id,
            local_account_id
        ) ON DELETE RESTRICT,
    CHECK (
        (application_kind IN ('apply', 'rebase')
            AND source_local_account_id IS NOT NULL
            AND source_base_profile_template_revision_id IS NOT NULL
            AND source_local_account_id = result_local_account_id)
        OR (application_kind = 'save_as'
            AND source_local_account_id IS NOT NULL
            AND source_base_profile_template_revision_id IS NOT NULL
            AND source_local_account_id <> result_local_account_id)
        OR (application_kind = 'create'
            AND source_local_account_id IS NULL
            AND source_base_profile_template_revision_id IS NULL)
    )
);

CREATE FUNCTION lab_local_game.reject_immutable_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'immutable_local_game_row';
END;
$$;

CREATE FUNCTION lab_local_game.guard_wallet_balance_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_count INTEGER;
BEGIN
    SELECT balance_count INTO expected_count
    FROM lab_local_game.wallet_revision
    WHERE wallet_revision_id = NEW.wallet_revision_id
    FOR UPDATE;

    IF expected_count IS NULL OR expected_count <= (
        SELECT count(*) FROM lab_local_game.wallet_balance
        WHERE wallet_revision_id = NEW.wallet_revision_id
    ) THEN
        RAISE EXCEPTION 'immutable_local_game_row';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_local_game.guard_lobby_revision_lineage()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    state_found BOOLEAN;
    current_revision_id BIGINT;
    current_revision_number INTEGER;
BEGIN
    SELECT TRUE, current_lobby_presentation_revision_id
      INTO state_found, current_revision_id
    FROM lab_local_game.account_client_state
    WHERE local_account_id = NEW.local_account_id
    FOR UPDATE;

    IF state_found IS DISTINCT FROM TRUE THEN
        IF NEW.revision_number IS DISTINCT FROM 1
           OR NEW.previous_lobby_presentation_revision_id IS NOT NULL THEN
            RAISE EXCEPTION 'local_game_revision_lineage_invalid';
        END IF;
    ELSE
        SELECT revision_number INTO current_revision_number
        FROM lab_local_game.lobby_presentation_revision
        WHERE lobby_presentation_revision_id = current_revision_id
          AND local_account_id = NEW.local_account_id;
        IF current_revision_number IS NULL
           OR NEW.previous_lobby_presentation_revision_id IS DISTINCT FROM
                  current_revision_id
           OR NEW.revision_number IS DISTINCT FROM current_revision_number + 1 THEN
            RAISE EXCEPTION 'local_game_revision_lineage_invalid';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_local_game.guard_wallet_revision_lineage()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    state_found BOOLEAN;
    current_revision_id BIGINT;
    current_revision_number INTEGER;
BEGIN
    SELECT TRUE, current_wallet_revision_id
      INTO state_found, current_revision_id
    FROM lab_local_game.account_client_state
    WHERE local_account_id = NEW.local_account_id
    FOR UPDATE;

    IF state_found IS DISTINCT FROM TRUE THEN
        IF NEW.revision_number IS DISTINCT FROM 1
           OR NEW.previous_wallet_revision_id IS NOT NULL THEN
            RAISE EXCEPTION 'local_game_revision_lineage_invalid';
        END IF;
    ELSE
        SELECT revision_number INTO current_revision_number
        FROM lab_local_game.wallet_revision
        WHERE wallet_revision_id = current_revision_id
          AND local_account_id = NEW.local_account_id;
        IF current_revision_number IS NULL
           OR NEW.previous_wallet_revision_id IS DISTINCT FROM current_revision_id
           OR NEW.revision_number IS DISTINCT FROM current_revision_number + 1 THEN
            RAISE EXCEPTION 'local_game_revision_lineage_invalid';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_local_game.require_lobby_revision_current()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM lab_local_game.account_client_state
        WHERE local_account_id = NEW.local_account_id
          AND current_lobby_presentation_revision_id =
                  NEW.lobby_presentation_revision_id
    ) THEN
        RAISE EXCEPTION 'local_game_revision_not_published';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_local_game.require_wallet_revision_current()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM lab_local_game.account_client_state
        WHERE local_account_id = NEW.local_account_id
          AND current_wallet_revision_id = NEW.wallet_revision_id
    ) THEN
        RAISE EXCEPTION 'local_game_revision_not_published';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_local_game.require_complete_wallet()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.balance_count <> (
        SELECT count(*) FROM lab_local_game.wallet_balance
        WHERE wallet_revision_id = NEW.wallet_revision_id
    ) OR NOT EXISTS (
        SELECT 1 FROM lab_local_game.wallet_balance
        WHERE wallet_revision_id = NEW.wallet_revision_id AND currency_code = 'jewel'
    ) OR NOT EXISTS (
        SELECT 1 FROM lab_local_game.wallet_balance
        WHERE wallet_revision_id = NEW.wallet_revision_id AND currency_code = 'credit'
    ) THEN
        RAISE EXCEPTION 'local_game_wallet_incomplete';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_local_game.guard_feature_entry_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected_count INTEGER;
BEGIN
    SELECT entry_count INTO expected_count
    FROM lab_local_game.client_feature_manifest
    WHERE client_feature_manifest_id = NEW.client_feature_manifest_id
    FOR UPDATE;

    IF expected_count IS NULL OR expected_count <= (
        SELECT count(*) FROM lab_local_game.client_feature_manifest_entry
        WHERE client_feature_manifest_id = NEW.client_feature_manifest_id
    ) THEN
        RAISE EXCEPTION 'immutable_local_game_row';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_local_game.require_complete_feature_manifest()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.entry_count <> (
        SELECT count(*) FROM lab_local_game.client_feature_manifest_entry
        WHERE client_feature_manifest_id = NEW.client_feature_manifest_id
    ) THEN
        RAISE EXCEPTION 'local_game_feature_manifest_incomplete';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION lab_local_game.require_lobby_profile_consistency()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM lab_profile.profile_template_revision AS profile
        WHERE profile.profile_template_revision_id =
                  NEW.validated_profile_template_revision_id
          AND profile.local_account_id = NEW.local_account_id
          AND profile.character_catalog_snapshot_id =
                  NEW.character_catalog_snapshot_id
    ) THEN
        RAISE EXCEPTION 'local_game_lobby_profile_binding_invalid';
    END IF;

    IF NEW.lobby_character_status = 'ready' AND NOT EXISTS (
        SELECT 1
        FROM lab_profile.profile_template_revision_build AS member
        JOIN lab_profile.character_build AS build
          ON build.character_build_id = member.character_build_id
        WHERE member.profile_template_revision_id =
                  NEW.validated_profile_template_revision_id
          AND build.character_entity_id = NEW.lobby_character_entity_id
    ) THEN
        RAISE EXCEPTION 'local_game_lobby_character_not_in_profile';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_local_game.guard_account_client_state_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.local_account_id <> OLD.local_account_id
       OR NEW.created_at_utc <> OLD.created_at_utc THEN
        RAISE EXCEPTION 'immutable_local_game_row';
    END IF;

    IF NEW.current_lobby_presentation_revision_id IS DISTINCT FROM
           OLD.current_lobby_presentation_revision_id
       AND NOT EXISTS (
           SELECT 1
           FROM lab_local_game.lobby_presentation_revision AS revision
           WHERE revision.lobby_presentation_revision_id =
                     NEW.current_lobby_presentation_revision_id
             AND revision.local_account_id = NEW.local_account_id
             AND revision.previous_lobby_presentation_revision_id =
                     OLD.current_lobby_presentation_revision_id
       ) THEN
        RAISE EXCEPTION 'local_game_revision_lineage_invalid';
    END IF;

    IF NEW.current_wallet_revision_id IS DISTINCT FROM OLD.current_wallet_revision_id
       AND NOT EXISTS (
           SELECT 1
           FROM lab_local_game.wallet_revision AS revision
           WHERE revision.wallet_revision_id = NEW.current_wallet_revision_id
             AND revision.local_account_id = NEW.local_account_id
             AND revision.previous_wallet_revision_id = OLD.current_wallet_revision_id
       ) THEN
        RAISE EXCEPTION 'local_game_revision_lineage_invalid';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_local_game.revalidate_lobby_after_profile_promotion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    current_lobby_id BIGINT;
    current_lobby lab_local_game.lobby_presentation_revision%ROWTYPE;
    promoted_profile lab_profile.profile_template_revision%ROWTYPE;
    promoted_character_definition_version_id BIGINT;
    replacement_lobby_id BIGINT;
BEGIN
    IF NEW.current_profile_template_revision_id IS NOT DISTINCT FROM
           OLD.current_profile_template_revision_id THEN
        RETURN NEW;
    END IF;

    SELECT state.current_lobby_presentation_revision_id
      INTO current_lobby_id
    FROM lab_local_game.account_client_state AS state
    WHERE state.local_account_id = NEW.local_account_id
    FOR UPDATE;

    IF current_lobby_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT * INTO STRICT current_lobby
    FROM lab_local_game.lobby_presentation_revision
    WHERE lobby_presentation_revision_id = current_lobby_id
      AND local_account_id = NEW.local_account_id;

    SELECT * INTO STRICT promoted_profile
    FROM lab_profile.profile_template_revision
    WHERE profile_template_revision_id = NEW.current_profile_template_revision_id
      AND local_account_id = NEW.local_account_id;

    IF current_lobby.lobby_character_status = 'ready' THEN
        SELECT revision.character_definition_version_id
          INTO promoted_character_definition_version_id
        FROM lab_profile.profile_template_revision_build AS member
        JOIN lab_profile.character_build AS build
          ON build.character_build_id = member.character_build_id
        JOIN lab_profile.character_build_revision AS revision
          ON revision.build_revision_id = member.build_revision_id
         AND revision.character_build_id = member.character_build_id
        WHERE member.profile_template_revision_id =
                  NEW.current_profile_template_revision_id
          AND build.character_entity_id =
                  current_lobby.lobby_character_entity_id;

        IF promoted_character_definition_version_id IS NULL THEN
            RAISE EXCEPTION 'local_game_lobby_character_not_in_profile';
        END IF;
    END IF;

    INSERT INTO lab_local_game.lobby_presentation_revision (
        lobby_presentation_revision_uid,
        local_account_id,
        revision_number,
        previous_lobby_presentation_revision_id,
        validated_profile_template_revision_id,
        character_catalog_snapshot_id,
        display_name,
        commander_level_status,
        commander_level,
        commander_level_unresolved_reason_code,
        lobby_character_status,
        lobby_character_entity_id,
        lobby_character_definition_version_id,
        lobby_character_unresolved_reason_code,
        profile_icon_status,
        profile_icon_selection_uid,
        profile_icon_unresolved_reason_code,
        profile_frame_status,
        profile_frame_selection_uid,
        profile_frame_unresolved_reason_code,
        lobby_background_status,
        lobby_background_selection_uid,
        lobby_background_unresolved_reason_code,
        content_sha256,
        revision_origin,
        materialized_at_utc
    ) VALUES (
        gen_random_uuid(),
        NEW.local_account_id,
        current_lobby.revision_number + 1,
        current_lobby.lobby_presentation_revision_id,
        promoted_profile.profile_template_revision_id,
        promoted_profile.character_catalog_snapshot_id,
        current_lobby.display_name,
        current_lobby.commander_level_status,
        current_lobby.commander_level,
        current_lobby.commander_level_unresolved_reason_code,
        current_lobby.lobby_character_status,
        current_lobby.lobby_character_entity_id,
        CASE WHEN current_lobby.lobby_character_status = 'ready'
             THEN promoted_character_definition_version_id ELSE NULL END,
        current_lobby.lobby_character_unresolved_reason_code,
        current_lobby.profile_icon_status,
        current_lobby.profile_icon_selection_uid,
        current_lobby.profile_icon_unresolved_reason_code,
        current_lobby.profile_frame_status,
        current_lobby.profile_frame_selection_uid,
        current_lobby.profile_frame_unresolved_reason_code,
        current_lobby.lobby_background_status,
        current_lobby.lobby_background_selection_uid,
        current_lobby.lobby_background_unresolved_reason_code,
        current_lobby.content_sha256,
        current_lobby.revision_origin,
        promoted_profile.materialized_at_utc
    )
    RETURNING lobby_presentation_revision_id INTO replacement_lobby_id;

    UPDATE lab_local_game.account_client_state
    SET current_lobby_presentation_revision_id = replacement_lobby_id
    WHERE local_account_id = NEW.local_account_id
      AND current_lobby_presentation_revision_id = current_lobby_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'local_game_revision_lineage_invalid';
    END IF;

    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_local_game.require_draft_application_consistency()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM lab_local_game.profile_draft_diff AS diff
        JOIN lab_local_game.profile_draft_application_intent AS intent
          ON intent.profile_draft_application_intent_id =
                 NEW.profile_draft_application_intent_id
         AND intent.application_uid = NEW.application_uid
         AND intent.application_kind = NEW.application_kind
         AND intent.profile_draft_diff_id = NEW.profile_draft_diff_id
         AND intent.request_sha256 = NEW.request_sha256
         AND intent.requested_at_utc = NEW.applied_at_utc
        LEFT JOIN lab_local_game.sanitized_profile_draft AS draft
          ON draft.sanitized_profile_draft_id = diff.sanitized_profile_draft_id
        LEFT JOIN lab_profile.profile_template_revision AS base
          ON base.profile_template_revision_id = diff.base_profile_template_revision_id
         AND base.local_account_id = diff.local_account_id
        JOIN lab_profile.profile_write_operation AS operation
          ON operation.profile_write_operation_id = NEW.profile_write_operation_id
        WHERE diff.profile_draft_diff_id = NEW.profile_draft_diff_id
          AND diff.local_account_id IS NOT DISTINCT FROM NEW.source_local_account_id
          AND diff.base_profile_template_revision_id IS NOT DISTINCT FROM
                  NEW.source_base_profile_template_revision_id
          AND operation.local_account_id = NEW.result_local_account_id
          AND operation.operation_uid = NEW.profile_write_operation_uid
          AND operation.result_profile_template_revision_id =
                  NEW.result_profile_template_revision_id
          AND (
              (NEW.application_kind = 'save_as'
                  AND operation.operation_kind = 'create'
                  AND operation.expected_profile_template_revision_uid IS NULL
                  AND diff.profile_edit_candidate_id IS NOT NULL
                  AND diff.sanitized_profile_draft_id IS NULL
                  AND diff.local_account_id IS NOT NULL
                  AND diff.base_profile_template_revision_id IS NOT NULL
                  AND NEW.source_local_account_id <> operation.local_account_id)
              OR (NEW.application_kind = 'create'
                  AND operation.operation_kind = 'create'
                  AND operation.expected_profile_template_revision_uid IS NULL
                  AND diff.sanitized_profile_draft_id IS NOT NULL
                  AND diff.profile_edit_candidate_id IS NULL
                  AND diff.local_account_id IS NULL
                  AND diff.base_profile_template_revision_id IS NULL
                  AND NEW.source_local_account_id IS NULL
                  AND NEW.source_base_profile_template_revision_id IS NULL)
              OR (NEW.application_kind = 'apply'
                  AND operation.operation_kind = 'save'
                  AND operation.expected_profile_template_revision_uid =
                          base.profile_template_revision_uid
                  AND NEW.source_local_account_id = operation.local_account_id
                  AND (
                      diff.profile_edit_candidate_id IS NOT NULL
                      OR draft.derivation_kind IN (
                          'offline_sanitized_import',
                          'reviewed_override'
                      )
                  ))
              OR (NEW.application_kind = 'rebase'
                  AND operation.operation_kind = 'save'
                  AND operation.expected_profile_template_revision_uid =
                          base.profile_template_revision_uid
                  AND NEW.source_local_account_id = operation.local_account_id
                  AND diff.profile_edit_candidate_id IS NULL
                  AND draft.derivation_kind = 'rebase')
          )
    ) THEN
        RAISE EXCEPTION 'local_game_draft_application_invalid';
    END IF;

    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_local_game.require_sanitized_import_operation_consistency()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM lab_local_game.sanitized_profile_draft AS draft
        WHERE draft.sanitized_profile_draft_id = NEW.result_draft_id
          AND (
              (NEW.operation_kind = 'sanitize'
                  AND draft.derivation_kind = 'offline_sanitized_import')
              OR (NEW.operation_kind = 'rebase'
                  AND draft.derivation_kind = 'rebase')
              OR (NEW.operation_kind = 'reviewed_override'
                  AND draft.derivation_kind = 'reviewed_override')
          )
    ) THEN
        RAISE EXCEPTION 'local_game_sanitized_import_operation_invalid';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_local_game_lobby_profile_consistency
BEFORE INSERT ON lab_local_game.lobby_presentation_revision
FOR EACH ROW EXECUTE FUNCTION lab_local_game.require_lobby_profile_consistency();

CREATE TRIGGER trg_local_game_lobby_lineage
BEFORE INSERT ON lab_local_game.lobby_presentation_revision
FOR EACH ROW EXECUTE FUNCTION lab_local_game.guard_lobby_revision_lineage();

CREATE CONSTRAINT TRIGGER trg_local_game_lobby_current
AFTER INSERT ON lab_local_game.lobby_presentation_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_local_game.require_lobby_revision_current();

CREATE TRIGGER trg_local_game_wallet_lineage
BEFORE INSERT ON lab_local_game.wallet_revision
FOR EACH ROW EXECUTE FUNCTION lab_local_game.guard_wallet_revision_lineage();

CREATE CONSTRAINT TRIGGER trg_local_game_wallet_current
AFTER INSERT ON lab_local_game.wallet_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_local_game.require_wallet_revision_current();

CREATE TRIGGER trg_local_game_wallet_balance_guard
BEFORE INSERT ON lab_local_game.wallet_balance
FOR EACH ROW EXECUTE FUNCTION lab_local_game.guard_wallet_balance_insert();

CREATE CONSTRAINT TRIGGER trg_local_game_wallet_complete
AFTER INSERT ON lab_local_game.wallet_revision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_local_game.require_complete_wallet();

CREATE TRIGGER trg_local_game_feature_entry_guard
BEFORE INSERT ON lab_local_game.client_feature_manifest_entry
FOR EACH ROW EXECUTE FUNCTION lab_local_game.guard_feature_entry_insert();

CREATE CONSTRAINT TRIGGER trg_local_game_feature_manifest_complete
AFTER INSERT ON lab_local_game.client_feature_manifest
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_local_game.require_complete_feature_manifest();

CREATE TRIGGER trg_local_game_account_state_update
BEFORE UPDATE ON lab_local_game.account_client_state
FOR EACH ROW EXECUTE FUNCTION lab_local_game.guard_account_client_state_update();

CREATE TRIGGER trg_local_game_account_state_delete
BEFORE DELETE ON lab_local_game.account_client_state
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();

CREATE TRIGGER trg_local_game_profile_lobby_revalidation
AFTER UPDATE OF current_profile_template_revision_id ON lab_profile.local_account
FOR EACH ROW EXECUTE FUNCTION lab_local_game.revalidate_lobby_after_profile_promotion();

CREATE CONSTRAINT TRIGGER trg_local_game_draft_application_consistency
AFTER INSERT ON lab_local_game.profile_draft_application
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_local_game.require_draft_application_consistency();

CREATE CONSTRAINT TRIGGER trg_local_game_sanitized_import_operation_consistency
AFTER INSERT ON lab_local_game.sanitized_import_operation
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION lab_local_game.require_sanitized_import_operation_consistency();

CREATE TRIGGER trg_local_game_lobby_immutable
BEFORE UPDATE OR DELETE ON lab_local_game.lobby_presentation_revision
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();

CREATE TRIGGER trg_local_game_wallet_immutable
BEFORE UPDATE OR DELETE ON lab_local_game.wallet_revision
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();

CREATE TRIGGER trg_local_game_wallet_balance_immutable
BEFORE UPDATE OR DELETE ON lab_local_game.wallet_balance
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();

CREATE TRIGGER trg_local_game_feature_manifest_immutable
BEFORE UPDATE OR DELETE ON lab_local_game.client_feature_manifest
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();

CREATE TRIGGER trg_local_game_feature_entry_immutable
BEFORE UPDATE OR DELETE ON lab_local_game.client_feature_manifest_entry
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();

CREATE TRIGGER trg_local_game_write_operation_immutable
BEFORE UPDATE OR DELETE ON lab_local_game.client_state_write_operation
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();

CREATE TRIGGER trg_local_game_draft_immutable
BEFORE UPDATE OR DELETE ON lab_local_game.sanitized_profile_draft
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();

CREATE TRIGGER trg_local_game_import_operation_immutable
BEFORE UPDATE OR DELETE ON lab_local_game.sanitized_import_operation
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();

CREATE TRIGGER trg_local_game_edit_candidate_immutable
BEFORE UPDATE OR DELETE ON lab_local_game.profile_edit_candidate
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();

CREATE TRIGGER trg_local_game_diff_immutable
BEFORE UPDATE OR DELETE ON lab_local_game.profile_draft_diff
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();

CREATE TRIGGER trg_local_game_application_immutable
BEFORE UPDATE OR DELETE ON lab_local_game.profile_draft_application
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();

CREATE TRIGGER trg_local_game_application_intent_immutable
BEFORE UPDATE OR DELETE ON lab_local_game.profile_draft_application_intent
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();

CREATE INDEX ix_local_game_lobby_account
    ON lab_local_game.lobby_presentation_revision(local_account_id);
CREATE INDEX ix_local_game_wallet_account
    ON lab_local_game.wallet_revision(local_account_id);
CREATE INDEX ix_local_game_draft_payload
    ON lab_local_game.sanitized_profile_draft(canonical_payload_sha256);
CREATE INDEX ix_local_game_diff_account
    ON lab_local_game.profile_draft_diff(local_account_id, base_profile_template_revision_id);
CREATE INDEX ix_local_game_diff_sanitized_content
    ON lab_local_game.profile_draft_diff(
        sanitized_profile_draft_id,
        base_profile_template_revision_id,
        diff_contract_version,
        canonical_diff_sha256
    ) WHERE sanitized_profile_draft_id IS NOT NULL;
CREATE INDEX ix_local_game_diff_editor_content
    ON lab_local_game.profile_draft_diff(
        profile_edit_candidate_id,
        base_profile_template_revision_id,
        diff_contract_version,
        canonical_diff_sha256
    ) WHERE profile_edit_candidate_id IS NOT NULL;
