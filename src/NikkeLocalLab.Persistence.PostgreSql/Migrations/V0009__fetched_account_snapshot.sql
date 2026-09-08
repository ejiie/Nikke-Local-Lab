CREATE TABLE lab_profile.fetched_account_snapshot (
    fetched_account_snapshot_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fetched_account_snapshot_uid UUID NOT NULL UNIQUE CHECK (
        fetched_account_snapshot_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    target_local_account_id BIGINT NOT NULL
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    sanitized_profile_draft_id BIGINT NOT NULL
        REFERENCES lab_local_game.sanitized_profile_draft(sanitized_profile_draft_id)
        ON DELETE RESTRICT,
    snapshot_contract_id TEXT NOT NULL CHECK (
        snapshot_contract_id = 'nll/fetched-account-snapshot/v1'
    ),
    captured_at_utc TIMESTAMPTZ NOT NULL,
    completeness_status_code TEXT NOT NULL CHECK (
        completeness_status_code IN ('complete', 'incomplete', 'failed')
    ),
    roster_count INTEGER NOT NULL CHECK (roster_count >= 0),
    character_detail_count INTEGER NOT NULL CHECK (character_detail_count >= 0),
    equipment_character_count INTEGER NOT NULL CHECK (equipment_character_count >= 0),
    missing_character_count INTEGER NOT NULL CHECK (missing_character_count >= 0),
    canonical_snapshot_json TEXT NOT NULL CHECK (
        octet_length(canonical_snapshot_json) BETWEEN 2 AND 67108864
        AND jsonb_typeof(canonical_snapshot_json::jsonb) = 'object'
    ),
    canonical_snapshot_sha256 BYTEA NOT NULL CHECK (
        octet_length(canonical_snapshot_sha256) = 32
    ),
    source_artifact_byte_length INTEGER NOT NULL CHECK (
        source_artifact_byte_length >= 0
    ),
    source_artifact_sha256 BYTEA NOT NULL CHECK (
        octet_length(source_artifact_sha256) = 32
    ),
    imported_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (target_local_account_id, fetched_account_snapshot_uid),
    UNIQUE (target_local_account_id, canonical_snapshot_sha256),
    CHECK (
        canonical_snapshot_json::jsonb #>> '{contractId}' = snapshot_contract_id
        AND canonical_snapshot_json::jsonb #>> '{snapshotUid}' =
            fetched_account_snapshot_uid::text
        AND canonical_snapshot_json::jsonb #>> '{completeness,statusCode}' =
            completeness_status_code
        AND (canonical_snapshot_json::jsonb #>> '{source,credentialOrSessionPersisted}')::boolean = false
        AND (canonical_snapshot_json::jsonb #>> '{source,rawSourcePersisted}')::boolean = false
        AND encode(source_artifact_sha256, 'hex') =
            canonical_snapshot_json::jsonb #>> '{source,artifactSha256}'
    )
);

ALTER TABLE lab_profile.account_workspace
ADD CONSTRAINT fk_account_workspace_fetched_snapshot
FOREIGN KEY (local_account_id, fetched_snapshot_uid)
REFERENCES lab_profile.fetched_account_snapshot(
    target_local_account_id,
    fetched_account_snapshot_uid
)
ON DELETE RESTRICT;

CREATE INDEX ix_fetched_account_snapshot_target_time
    ON lab_profile.fetched_account_snapshot(target_local_account_id, captured_at_utc DESC);

CREATE TRIGGER trg_fetched_account_snapshot_immutable
BEFORE UPDATE OR DELETE ON lab_profile.fetched_account_snapshot
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();
