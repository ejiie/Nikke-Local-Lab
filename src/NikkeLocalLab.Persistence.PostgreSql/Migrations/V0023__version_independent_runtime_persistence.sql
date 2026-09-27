-- Logical ownership is independent of the executable and content snapshot.
-- Keep historical aggregates and ciphertext intact; designate one continuation.
CREATE TABLE lab_private_server.classic_raid_persistence_scope (
    local_account_id BIGINT NOT NULL REFERENCES lab_profile.local_account(local_account_id),
    season_number INTEGER NOT NULL CHECK (season_number > 0),
    selected_weakness_code TEXT NOT NULL,
    state_id BIGINT NOT NULL UNIQUE REFERENCES lab_private_server.classic_solo_raid_runtime_state(classic_solo_raid_runtime_state_id),
    PRIMARY KEY (local_account_id, season_number, selected_weakness_code)
);
INSERT INTO lab_private_server.classic_raid_persistence_scope
SELECT DISTINCT ON (s.local_account_id, s.season_number, s.selected_weakness_code)
       s.local_account_id, s.season_number, s.selected_weakness_code, s.classic_solo_raid_runtime_state_id
  FROM lab_private_server.classic_solo_raid_runtime_state s
  LEFT JOIN lab_private_server.classic_solo_raid_runtime_state_revision r
    ON r.classic_solo_raid_runtime_state_revision_id = s.current_classic_solo_raid_runtime_state_revision_id
 ORDER BY s.local_account_id, s.season_number, s.selected_weakness_code,
          r.persisted_at_utc DESC NULLS LAST, r.classic_solo_raid_runtime_state_revision_id DESC NULLS LAST,
          s.classic_solo_raid_runtime_state_id DESC;

CREATE TABLE lab_private_server.classic_raid_revision_context (
    revision_uid UUID PRIMARY KEY REFERENCES lab_private_server.classic_solo_raid_runtime_state_revision(classic_solo_raid_runtime_state_revision_uid),
    raid_snapshot_uid UUID NOT NULL REFERENCES lab_private_server.runtime_raid_snapshot(raid_snapshot_uid),
    raid_snapshot_sha256 BYTEA NOT NULL CHECK (octet_length(raid_snapshot_sha256) = 32),
    client_build_code TEXT NOT NULL CHECK (client_build_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    client_executable_sha256 BYTEA NOT NULL CHECK (octet_length(client_executable_sha256) = 32)
);
INSERT INTO lab_private_server.classic_raid_revision_context
SELECT r.classic_solo_raid_runtime_state_revision_uid, sn.raid_snapshot_uid, sn.content_sha256,
       s.client_build_code, s.client_executable_sha256
  FROM lab_private_server.classic_solo_raid_runtime_state_revision r
  JOIN lab_private_server.classic_solo_raid_runtime_state s USING (classic_solo_raid_runtime_state_id)
  JOIN lab_private_server.runtime_raid_snapshot sn ON sn.raid_snapshot_id = s.raid_snapshot_id;

CREATE TABLE lab_private_server.runtime_preferences_scope (
    local_account_uid UUID PRIMARY KEY REFERENCES lab_profile.local_account(local_account_uid),
    preferences_uid UUID NOT NULL UNIQUE REFERENCES lab_private_server.runtime_preferences(preferences_uid)
);
INSERT INTO lab_private_server.runtime_preferences_scope
SELECT DISTINCT ON (s.local_account_uid) s.local_account_uid, s.preferences_uid
  FROM lab_private_server.runtime_preferences s
  LEFT JOIN lab_private_server.runtime_preferences_revision r ON r.revision_uid = s.current_revision_uid
 ORDER BY s.local_account_uid, r.captured_at_utc DESC NULLS LAST, r.revision_number DESC NULLS LAST, s.preferences_uid;

CREATE TABLE lab_private_server.runtime_preferences_revision_context (
    revision_uid UUID PRIMARY KEY REFERENCES lab_private_server.runtime_preferences_revision(revision_uid),
    client_build_code TEXT NOT NULL CHECK (client_build_code ~ '^[a-z][a-z0-9._-]{0,63}$'),
    client_executable_sha256 BYTEA NOT NULL CHECK (octet_length(client_executable_sha256) = 32)
);
INSERT INTO lab_private_server.runtime_preferences_revision_context
SELECT r.revision_uid, s.client_build_code, s.client_executable_sha256
  FROM lab_private_server.runtime_preferences_revision r
  JOIN lab_private_server.runtime_preferences s USING (preferences_uid);

CREATE TRIGGER classic_raid_scope_immutable BEFORE UPDATE OR DELETE ON lab_private_server.classic_raid_persistence_scope
    FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();
CREATE TRIGGER classic_raid_context_immutable BEFORE UPDATE OR DELETE ON lab_private_server.classic_raid_revision_context
    FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();
CREATE TRIGGER runtime_preferences_scope_immutable BEFORE UPDATE OR DELETE ON lab_private_server.runtime_preferences_scope
    FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();
CREATE TRIGGER runtime_preferences_context_immutable BEFORE UPDATE OR DELETE ON lab_private_server.runtime_preferences_revision_context
    FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();
