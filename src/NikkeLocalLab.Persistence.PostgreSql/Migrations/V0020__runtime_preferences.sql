-- Private compatibility envelopes only. No original identifiers are relational keys.
CREATE TABLE lab_private_server.runtime_preferences (
    preferences_uid UUID PRIMARY KEY CHECK (preferences_uid <> '00000000-0000-0000-0000-000000000000'),
    local_account_uid UUID NOT NULL REFERENCES lab_profile.local_account(local_account_uid) ON DELETE RESTRICT,
    client_build_code TEXT NOT NULL CHECK (client_build_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    client_executable_sha256 BYTEA NOT NULL CHECK (octet_length(client_executable_sha256) = 32),
    current_revision_uid UUID,
    UNIQUE (local_account_uid, client_build_code, client_executable_sha256)
);
CREATE TABLE lab_private_server.runtime_preferences_revision (
    revision_uid UUID PRIMARY KEY CHECK (revision_uid <> '00000000-0000-0000-0000-000000000000'),
    preferences_uid UUID NOT NULL REFERENCES lab_private_server.runtime_preferences(preferences_uid) ON DELETE RESTRICT,
    previous_revision_uid UUID,
    revision_number INTEGER NOT NULL CHECK (revision_number > 0),
    launch_context_uid UUID NOT NULL UNIQUE CHECK (launch_context_uid <> '00000000-0000-0000-0000-000000000000'),
    protected_payload BYTEA NOT NULL CHECK (octet_length(protected_payload) BETWEEN 53 AND 16777216),
    protected_payload_sha256 BYTEA NOT NULL CHECK (octet_length(protected_payload_sha256) = 32),
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    captured_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (preferences_uid, revision_uid),
    UNIQUE (preferences_uid, revision_number),
    FOREIGN KEY (preferences_uid, previous_revision_uid)
        REFERENCES lab_private_server.runtime_preferences_revision(preferences_uid, revision_uid) ON DELETE RESTRICT
);
ALTER TABLE lab_private_server.runtime_preferences ADD CONSTRAINT fk_runtime_preferences_head
    FOREIGN KEY (preferences_uid, current_revision_uid)
    REFERENCES lab_private_server.runtime_preferences_revision(preferences_uid, revision_uid)
    ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE lab_private_server.runtime_preferences_operation (
    launch_context_uid UUID PRIMARY KEY CHECK (launch_context_uid <> '00000000-0000-0000-0000-000000000000'),
    preferences_uid UUID NOT NULL REFERENCES lab_private_server.runtime_preferences(preferences_uid) ON DELETE RESTRICT,
    request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256) = 32),
    expected_revision_uid UUID,
    result_revision_uid UUID,
    result_code TEXT NOT NULL CHECK (result_code IN ('state_advanced','state_unchanged','stale_head_quarantined')),
    quarantined_payload BYTEA CHECK (octet_length(quarantined_payload) BETWEEN 53 AND 16777216),
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    captured_at_utc TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (preferences_uid, expected_revision_uid)
        REFERENCES lab_private_server.runtime_preferences_revision(preferences_uid, revision_uid) ON DELETE RESTRICT,
    FOREIGN KEY (preferences_uid, result_revision_uid)
        REFERENCES lab_private_server.runtime_preferences_revision(preferences_uid, revision_uid) ON DELETE RESTRICT,
    CHECK ((result_code = 'stale_head_quarantined') = (quarantined_payload IS NOT NULL)),
    CHECK (result_code = 'stale_head_quarantined' OR result_revision_uid IS NOT NULL)
);
CREATE FUNCTION lab_private_server.guard_runtime_preferences_lineage() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE current_uid UUID; current_number INTEGER;
BEGIN
    SELECT current_revision_uid INTO current_uid FROM lab_private_server.runtime_preferences
        WHERE preferences_uid = NEW.preferences_uid FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'runtime_preferences_missing'; END IF;
    SELECT revision_number INTO current_number FROM lab_private_server.runtime_preferences_revision
        WHERE revision_uid = current_uid;
    IF NEW.previous_revision_uid IS DISTINCT FROM current_uid OR
       NEW.revision_number <> COALESCE(current_number, 0) + 1 THEN
        RAISE EXCEPTION 'runtime_preferences_lineage_invalid';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER runtime_preferences_lineage BEFORE INSERT ON lab_private_server.runtime_preferences_revision
    FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_runtime_preferences_lineage();
CREATE TRIGGER runtime_preferences_pointer BEFORE UPDATE ON lab_private_server.runtime_preferences
    FOR EACH ROW EXECUTE FUNCTION lab_private_server.guard_aggregate_pointer_update('current_revision_uid');
CREATE TRIGGER runtime_preferences_no_delete BEFORE DELETE ON lab_private_server.runtime_preferences
    FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();
CREATE TRIGGER runtime_preferences_revision_immutable BEFORE UPDATE OR DELETE ON lab_private_server.runtime_preferences_revision
    FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();
CREATE TRIGGER runtime_preferences_operation_immutable BEFORE UPDATE OR DELETE ON lab_private_server.runtime_preferences_operation
    FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();
