-- Shared NLL raid state. Identity is union/season, never a client build or profile revision.
-- Payload contains local account/character UUIDs and boss ordinals, not source game IDs.
CREATE TABLE lab_private_server.local_union_raid_runtime (
    local_union_id SMALLINT NOT NULL,
    season_number INTEGER NOT NULL,
    revision BIGINT NOT NULL DEFAULT 0 CHECK (revision >= 0),
    payload JSONB NOT NULL,
    updated_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (local_union_id, season_number),
    FOREIGN KEY (local_union_id, season_number)
      REFERENCES lab_private_server.local_union_raid_season(local_union_id, season_number),
    CHECK (jsonb_typeof(payload) = 'object')
);
