CREATE SCHEMA lab_import;

CREATE TABLE lab_import.source_artifact (
    source_artifact_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_artifact_uid UUID NOT NULL UNIQUE,
    artifact_kind TEXT NOT NULL CHECK (artifact_kind ~ '^[a-z][a-z0-9._-]{0,63}$'),
    content_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(content_sha256) = 32),
    byte_length BIGINT NOT NULL CHECK (byte_length >= 0),
    first_observed_at_utc TIMESTAMPTZ NOT NULL
);

CREATE TABLE lab_import.dataset_snapshot (
    dataset_snapshot_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dataset_snapshot_uid UUID NOT NULL UNIQUE,
    manifest_version SMALLINT NOT NULL CHECK (manifest_version = 1),
    canonical_sha256 BYTEA NOT NULL UNIQUE CHECK (octet_length(canonical_sha256) = 32),
    created_at_utc TIMESTAMPTZ NOT NULL
);

CREATE TABLE lab_import.dataset_snapshot_source_artifact (
    dataset_snapshot_id BIGINT NOT NULL REFERENCES lab_import.dataset_snapshot(dataset_snapshot_id) ON DELETE RESTRICT,
    source_artifact_id BIGINT NOT NULL REFERENCES lab_import.source_artifact(source_artifact_id) ON DELETE RESTRICT,
    role_code TEXT NOT NULL CHECK (role_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    PRIMARY KEY (dataset_snapshot_id, role_code, ordinal),
    UNIQUE (dataset_snapshot_id, role_code, source_artifact_id)
);

CREATE TABLE lab_import.import_run (
    import_run_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    import_run_uid UUID NOT NULL UNIQUE,
    dataset_snapshot_id BIGINT REFERENCES lab_import.dataset_snapshot(dataset_snapshot_id) ON DELETE RESTRICT,
    extractor_id TEXT NOT NULL CHECK (extractor_id ~ '^[a-z][a-z0-9._-]{0,63}$'),
    extractor_version TEXT NOT NULL CHECK (extractor_version ~ '^[a-z][a-z0-9._-]{0,63}$'),
    extractor_contract_sha256 BYTEA NOT NULL CHECK (octet_length(extractor_contract_sha256) = 32),
    semantic_options_sha256 BYTEA NOT NULL CHECK (octet_length(semantic_options_sha256) = 32),
    request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256) = 32),
    output_manifest_sha256 BYTEA CHECK (output_manifest_sha256 IS NULL OR octet_length(output_manifest_sha256) = 32),
    status TEXT NOT NULL CHECK (status IN ('succeeded', 'reused', 'failed')),
    result_code TEXT NOT NULL CHECK (result_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    reused_from_import_run_id BIGINT REFERENCES lab_import.import_run(import_run_id) ON DELETE RESTRICT,
    started_at_utc TIMESTAMPTZ NOT NULL,
    finished_at_utc TIMESTAMPTZ NOT NULL CHECK (finished_at_utc >= started_at_utc),
    CHECK (
        (status = 'succeeded' AND dataset_snapshot_id IS NOT NULL AND output_manifest_sha256 IS NOT NULL AND reused_from_import_run_id IS NULL) OR
        (status = 'reused' AND dataset_snapshot_id IS NOT NULL AND output_manifest_sha256 IS NOT NULL AND reused_from_import_run_id IS NOT NULL) OR
        (status = 'failed' AND output_manifest_sha256 IS NULL AND reused_from_import_run_id IS NULL)
    )
);

CREATE INDEX ix_import_run_request_sha256 ON lab_import.import_run(request_sha256);

CREATE TABLE lab_import.import_run_source_artifact (
    import_run_id BIGINT NOT NULL REFERENCES lab_import.import_run(import_run_id) ON DELETE RESTRICT,
    source_artifact_id BIGINT NOT NULL REFERENCES lab_import.source_artifact(source_artifact_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    PRIMARY KEY (import_run_id, ordinal)
);

CREATE TABLE lab_import.import_diagnostic (
    import_diagnostic_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    import_diagnostic_uid UUID NOT NULL UNIQUE,
    import_run_id BIGINT NOT NULL REFERENCES lab_import.import_run(import_run_id) ON DELETE RESTRICT,
    sequence_number INTEGER NOT NULL CHECK (sequence_number >= 0),
    severity TEXT NOT NULL CHECK (severity IN ('info', 'warning', 'error')),
    stage_code TEXT NOT NULL CHECK (stage_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    diagnostic_code TEXT NOT NULL CHECK (diagnostic_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    occurrence_count INTEGER NOT NULL CHECK (occurrence_count >= 1),
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (import_run_id, sequence_number)
);
