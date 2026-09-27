-- Runtime content identity is independent of the historical six-season server
-- directory. Preserve every existing state FK value, UUID, and authenticated hash.
CREATE SEQUENCE lab_private_server.common_runtime_snapshot_id_seq
    AS BIGINT START WITH -1 INCREMENT BY -1 MAXVALUE -1 NO CYCLE;
CREATE TABLE lab_private_server.runtime_raid_snapshot (
    raid_snapshot_id BIGINT PRIMARY KEY,
    raid_snapshot_uid UUID NOT NULL UNIQUE CHECK (raid_snapshot_uid <> '00000000-0000-0000-0000-000000000000'),
    season_number INTEGER NOT NULL CHECK (season_number > 0),
    content_sha256 BYTEA NOT NULL CHECK (octet_length(content_sha256) = 32),
    legacy_snapshot_id BIGINT UNIQUE REFERENCES lab_raid.raid_snapshot(raid_snapshot_id) ON DELETE RESTRICT,
    source_sha256 BYTEA CHECK (octet_length(source_sha256) = 32),
    created_at_utc TIMESTAMPTZ NOT NULL,
    UNIQUE (raid_snapshot_id, season_number),
    UNIQUE (season_number, source_sha256),
    CHECK ((legacy_snapshot_id IS NOT NULL AND raid_snapshot_id = legacy_snapshot_id AND source_sha256 IS NULL)
        OR (legacy_snapshot_id IS NULL AND raid_snapshot_id < 0 AND source_sha256 IS NOT NULL))
);
INSERT INTO lab_private_server.runtime_raid_snapshot
    (raid_snapshot_id, raid_snapshot_uid, season_number, content_sha256, legacy_snapshot_id, created_at_utc)
SELECT raid_snapshot_id, raid_snapshot_uid, season_number, content_sha256, raid_snapshot_id, created_at_utc
  FROM lab_raid.raid_snapshot;
CREATE FUNCTION lab_private_server.mirror_legacy_runtime_snapshot() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO lab_private_server.runtime_raid_snapshot
        (raid_snapshot_id, raid_snapshot_uid, season_number, content_sha256, legacy_snapshot_id, created_at_utc)
    VALUES (NEW.raid_snapshot_id, NEW.raid_snapshot_uid, NEW.season_number,
        NEW.content_sha256, NEW.raid_snapshot_id, NEW.created_at_utc);
    RETURN NEW;
END;
$$;
CREATE TRIGGER mirror_legacy_runtime_snapshot AFTER INSERT ON lab_raid.raid_snapshot
    FOR EACH ROW EXECUTE FUNCTION lab_private_server.mirror_legacy_runtime_snapshot();
CREATE TRIGGER runtime_raid_snapshot_immutable BEFORE UPDATE OR DELETE ON lab_private_server.runtime_raid_snapshot
    FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();
DO $$
DECLARE old_fk TEXT;
BEGIN
    SELECT conname INTO STRICT old_fk FROM pg_constraint
      WHERE conrelid = 'lab_private_server.classic_solo_raid_runtime_state'::regclass
        AND confrelid = 'lab_raid.raid_snapshot'::regclass AND contype = 'f';
    EXECUTE format('ALTER TABLE lab_private_server.classic_solo_raid_runtime_state DROP CONSTRAINT %I', old_fk);
END;
$$;
ALTER TABLE lab_private_server.classic_solo_raid_runtime_state
    ADD CONSTRAINT fk_classic_runtime_content FOREIGN KEY (raid_snapshot_id, season_number)
    REFERENCES lab_private_server.runtime_raid_snapshot(raid_snapshot_id, season_number) ON DELETE RESTRICT;

-- Immutable exact-profile publication. File publication may precede this row;
-- preparation must remain blocked until both halves agree. Retries reuse it.
CREATE TABLE lab_private_server.common_boss_runtime_binding (
    profile_sha256 BYTEA PRIMARY KEY CHECK (octet_length(profile_sha256) = 32),
    season_number INTEGER NOT NULL CHECK (season_number > 0),
    source_sha256 BYTEA NOT NULL CHECK (octet_length(source_sha256) = 32),
    candidate_sha256 BYTEA NOT NULL CHECK (octet_length(candidate_sha256) = 32),
    raid_snapshot_id BIGINT NOT NULL,
    admission_policy_id TEXT NOT NULL CHECK (admission_policy_id = 'common-boss-runtime-admission/v1'),
    created_at_utc TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (raid_snapshot_id, season_number)
        REFERENCES lab_private_server.runtime_raid_snapshot(raid_snapshot_id, season_number) ON DELETE RESTRICT
);
CREATE INDEX common_boss_runtime_source ON lab_private_server.common_boss_runtime_binding(season_number, source_sha256);
CREATE TRIGGER common_boss_runtime_binding_immutable BEFORE UPDATE OR DELETE ON lab_private_server.common_boss_runtime_binding
    FOR EACH ROW EXECUTE FUNCTION lab_private_server.reject_immutable_mutation();
