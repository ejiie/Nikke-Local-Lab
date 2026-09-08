CREATE TABLE lab_private_server.classic_solo_raid_runtime_state (
    classic_solo_raid_runtime_state_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    classic_solo_raid_runtime_state_uid UUID NOT NULL UNIQUE CHECK (
        classic_solo_raid_runtime_state_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    local_account_id BIGINT NOT NULL
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    raid_snapshot_id BIGINT NOT NULL,
    season_number INTEGER NOT NULL CHECK (season_number > 0),
    client_build_code TEXT NOT NULL CHECK (
        client_build_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    client_executable_sha256 BYTEA NOT NULL CHECK (
        octet_length(client_executable_sha256) = 32
    ),
    current_classic_solo_raid_runtime_state_revision_id BIGINT,
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (
        local_account_id,
        raid_snapshot_id,
        season_number,
        client_build_code,
        client_executable_sha256
    ),
    UNIQUE (
        classic_solo_raid_runtime_state_id,
        current_classic_solo_raid_runtime_state_revision_id
    ),
    FOREIGN KEY (raid_snapshot_id, season_number)
        REFERENCES lab_raid.raid_snapshot(raid_snapshot_id, season_number)
        ON DELETE RESTRICT
);

CREATE TABLE lab_private_server.classic_solo_raid_runtime_state_revision (
    classic_solo_raid_runtime_state_revision_id BIGINT
        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    classic_solo_raid_runtime_state_revision_uid UUID NOT NULL UNIQUE CHECK (
        classic_solo_raid_runtime_state_revision_uid <>
            '00000000-0000-0000-0000-000000000000'::uuid
    ),
    classic_solo_raid_runtime_state_id BIGINT NOT NULL
        REFERENCES lab_private_server.classic_solo_raid_runtime_state(
            classic_solo_raid_runtime_state_id
        ) ON DELETE RESTRICT,
    revision_number INTEGER NOT NULL CHECK (revision_number >= 1),
    previous_classic_solo_raid_runtime_state_revision_id BIGINT,
    source_launch_context_uid UUID NOT NULL UNIQUE CHECK (
        source_launch_context_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    source_profile_revision_set_sha256 BYTEA NOT NULL CHECK (
        octet_length(source_profile_revision_set_sha256) = 32
    ),
    state_schema_version SMALLINT NOT NULL CHECK (state_schema_version = 1),
    protected_payload BYTEA NOT NULL CHECK (
        octet_length(protected_payload) BETWEEN 53 AND 1048576
    ),
    protected_payload_byte_length INTEGER NOT NULL CHECK (
        protected_payload_byte_length BETWEEN 53 AND 1048576
    ),
    protected_payload_sha256 BYTEA NOT NULL CHECK (
        octet_length(protected_payload_sha256) = 32
    ),
    state_content_sha256 BYTEA NOT NULL CHECK (
        octet_length(state_content_sha256) = 32
    ),
    state_present BOOLEAN NOT NULL,
    has_open_run BOOLEAN NOT NULL,
    completed_best_total_damage BIGINT CHECK (
        completed_best_total_damage IS NULL OR completed_best_total_damage >= 0
    ),
    completed_best_team_count SMALLINT NOT NULL CHECK (
        completed_best_team_count BETWEEN 0 AND 5
    ),
    open_team_count SMALLINT NOT NULL CHECK (open_team_count BETWEEN 0 AND 4),
    raid_date_day INTEGER CHECK (raid_date_day IS NULL OR raid_date_day >= 0),
    captured_at_utc TIMESTAMPTZ NOT NULL,
    persisted_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (classic_solo_raid_runtime_state_id, revision_number),
    UNIQUE (
        classic_solo_raid_runtime_state_id,
        classic_solo_raid_runtime_state_revision_id
    ),
    UNIQUE (
        classic_solo_raid_runtime_state_id,
        classic_solo_raid_runtime_state_revision_uid
    ),
    FOREIGN KEY (
        classic_solo_raid_runtime_state_id,
        previous_classic_solo_raid_runtime_state_revision_id
    ) REFERENCES lab_private_server.classic_solo_raid_runtime_state_revision(
        classic_solo_raid_runtime_state_id,
        classic_solo_raid_runtime_state_revision_id
    ) ON DELETE RESTRICT,
    CHECK (octet_length(protected_payload) = protected_payload_byte_length),
    CHECK (
        (revision_number = 1
            AND previous_classic_solo_raid_runtime_state_revision_id IS NULL)
        OR
        (revision_number > 1
            AND previous_classic_solo_raid_runtime_state_revision_id IS NOT NULL)
    ),
    CHECK (state_present OR NOT has_open_run),
    CHECK (has_open_run OR open_team_count = 0),
    CHECK (
        (completed_best_total_damage IS NULL AND completed_best_team_count = 0)
        OR
        (completed_best_total_damage IS NOT NULL AND completed_best_team_count = 5)
    ),
    CHECK (
        state_present
        OR (
            completed_best_total_damage IS NULL
            AND completed_best_team_count = 0
            AND open_team_count = 0
            AND raid_date_day IS NULL
        )
    )
);

ALTER TABLE lab_private_server.classic_solo_raid_runtime_state
    ADD CONSTRAINT fk_classic_solo_raid_runtime_state_current_revision
    FOREIGN KEY (
        classic_solo_raid_runtime_state_id,
        current_classic_solo_raid_runtime_state_revision_id
    ) REFERENCES lab_private_server.classic_solo_raid_runtime_state_revision(
        classic_solo_raid_runtime_state_id,
        classic_solo_raid_runtime_state_revision_id
    ) ON DELETE RESTRICT
    DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE lab_private_server.classic_solo_raid_runtime_state_operation (
    source_launch_context_uid UUID PRIMARY KEY CHECK (
        source_launch_context_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256) = 32),
    classic_solo_raid_runtime_state_id BIGINT NOT NULL
        REFERENCES lab_private_server.classic_solo_raid_runtime_state(
            classic_solo_raid_runtime_state_id
        ) ON DELETE RESTRICT,
    expected_head_revision_uid UUID CHECK (
        expected_head_revision_uid IS NULL
        OR expected_head_revision_uid <>
            '00000000-0000-0000-0000-000000000000'::uuid
    ),
    operation_status TEXT NOT NULL CHECK (
        operation_status IN ('pending', 'applied', 'quarantined')
    ),
    result_code TEXT CHECK (
        result_code IS NULL OR result_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    result_revision_uid UUID CHECK (
            result_revision_uid IS NULL
            OR result_revision_uid <>
                '00000000-0000-0000-0000-000000000000'::uuid
    ),
    result_state_content_sha256 BYTEA CHECK (
        result_state_content_sha256 IS NULL
        OR octet_length(result_state_content_sha256) = 32
    ),
    created_at_utc TIMESTAMPTZ NOT NULL,
    completed_at_utc TIMESTAMPTZ,
    FOREIGN KEY (
        classic_solo_raid_runtime_state_id,
        expected_head_revision_uid
    ) REFERENCES lab_private_server.classic_solo_raid_runtime_state_revision(
        classic_solo_raid_runtime_state_id,
        classic_solo_raid_runtime_state_revision_uid
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
        classic_solo_raid_runtime_state_id,
        result_revision_uid
    ) REFERENCES lab_private_server.classic_solo_raid_runtime_state_revision(
        classic_solo_raid_runtime_state_id,
        classic_solo_raid_runtime_state_revision_uid
    ) ON DELETE RESTRICT,
    CHECK (
        (operation_status = 'pending'
            AND result_code IS NULL
            AND result_revision_uid IS NULL
            AND result_state_content_sha256 IS NULL
            AND completed_at_utc IS NULL)
        OR
        (operation_status IN ('applied', 'quarantined')
            AND result_code IS NOT NULL
            AND result_state_content_sha256 IS NOT NULL
            AND completed_at_utc IS NOT NULL)
    )
);

CREATE FUNCTION lab_private_server.guard_classic_solo_raid_runtime_state_revision_lineage()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    current_revision_id BIGINT;
    current_revision_number INTEGER;
BEGIN
    SELECT current_classic_solo_raid_runtime_state_revision_id
      INTO current_revision_id
      FROM lab_private_server.classic_solo_raid_runtime_state
     WHERE classic_solo_raid_runtime_state_id =
           NEW.classic_solo_raid_runtime_state_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'classic_solo_raid_runtime_state_aggregate_missing';
    END IF;

    IF current_revision_id IS NULL THEN
        IF NEW.revision_number <> 1
           OR NEW.previous_classic_solo_raid_runtime_state_revision_id IS NOT NULL THEN
            RAISE EXCEPTION 'classic_solo_raid_runtime_state_revision_lineage_invalid';
        END IF;
    ELSE
        SELECT revision_number
          INTO current_revision_number
          FROM lab_private_server.classic_solo_raid_runtime_state_revision
         WHERE classic_solo_raid_runtime_state_revision_id = current_revision_id
           AND classic_solo_raid_runtime_state_id =
               NEW.classic_solo_raid_runtime_state_id;
        IF current_revision_number IS NULL
           OR NEW.previous_classic_solo_raid_runtime_state_revision_id
                IS DISTINCT FROM current_revision_id
           OR NEW.revision_number <> current_revision_number + 1 THEN
            RAISE EXCEPTION 'classic_solo_raid_runtime_state_revision_lineage_invalid';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_private_server.guard_classic_solo_raid_runtime_state_operation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' OR OLD.operation_status <> 'pending' THEN
        RAISE EXCEPTION 'classic_solo_raid_runtime_state_operation_immutable';
    END IF;
    IF NEW.source_launch_context_uid IS DISTINCT FROM OLD.source_launch_context_uid
       OR NEW.request_sha256 IS DISTINCT FROM OLD.request_sha256
       OR NEW.classic_solo_raid_runtime_state_id IS DISTINCT FROM
            OLD.classic_solo_raid_runtime_state_id
       OR NEW.expected_head_revision_uid IS DISTINCT FROM OLD.expected_head_revision_uid
       OR NEW.created_at_utc IS DISTINCT FROM OLD.created_at_utc THEN
        RAISE EXCEPTION 'classic_solo_raid_runtime_state_operation_identity_immutable';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_classic_solo_raid_runtime_state_pointer
BEFORE UPDATE ON lab_private_server.classic_solo_raid_runtime_state
FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_aggregate_pointer_update(
    'current_classic_solo_raid_runtime_state_revision_id'
);

CREATE TRIGGER trg_reject_classic_solo_raid_runtime_state_delete
BEFORE DELETE ON lab_private_server.classic_solo_raid_runtime_state
FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();

CREATE TRIGGER trg_reject_classic_solo_raid_runtime_state_revision_mutation
BEFORE UPDATE OR DELETE
ON lab_private_server.classic_solo_raid_runtime_state_revision
FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();

CREATE TRIGGER trg_guard_classic_solo_raid_runtime_state_revision_lineage
BEFORE INSERT
ON lab_private_server.classic_solo_raid_runtime_state_revision
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.guard_classic_solo_raid_runtime_state_revision_lineage();

CREATE TRIGGER trg_guard_classic_solo_raid_runtime_state_operation
BEFORE UPDATE OR DELETE
ON lab_private_server.classic_solo_raid_runtime_state_operation
FOR EACH ROW EXECUTE FUNCTION
    lab_private_server.guard_classic_solo_raid_runtime_state_operation();

CREATE INDEX ix_classic_solo_raid_runtime_state_account
    ON lab_private_server.classic_solo_raid_runtime_state(local_account_id);

CREATE INDEX ix_classic_solo_raid_runtime_state_revision_state
    ON lab_private_server.classic_solo_raid_runtime_state_revision(
        classic_solo_raid_runtime_state_id,
        revision_number DESC
    );

CREATE INDEX ix_classic_solo_raid_runtime_state_revision_content
    ON lab_private_server.classic_solo_raid_runtime_state_revision(
        classic_solo_raid_runtime_state_id,
        state_content_sha256
    );
