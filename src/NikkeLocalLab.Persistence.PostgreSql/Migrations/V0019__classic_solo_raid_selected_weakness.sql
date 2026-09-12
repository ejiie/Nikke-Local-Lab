-- Old revisions retain their original authenticated payload and unknown weakness.
-- This is not a backfill from the boss's default element or today's selection.
ALTER TABLE lab_private_server.classic_solo_raid_runtime_state
    ADD COLUMN selected_weakness_code TEXT NOT NULL DEFAULT 'unresolved'
    CHECK (selected_weakness_code IN ('unresolved', 'iron', 'water', 'fire', 'wind', 'electric'));

DO $$
DECLARE
    constraint_name TEXT;
BEGIN
    SELECT constraint_row.conname INTO STRICT constraint_name
      FROM pg_constraint constraint_row
     WHERE constraint_row.conrelid =
           'lab_private_server.classic_solo_raid_runtime_state'::regclass
       AND constraint_row.contype = 'u'
       AND (SELECT array_agg(attribute.attname::text ORDER BY attribute.attname)
              FROM unnest(constraint_row.conkey) AS key_column(attnum)
              JOIN pg_attribute attribute
                ON attribute.attrelid = constraint_row.conrelid
               AND attribute.attnum = key_column.attnum) =
           ARRAY['client_build_code', 'client_executable_sha256', 'local_account_id',
                 'raid_snapshot_id', 'season_number']::text[];
    EXECUTE format('ALTER TABLE lab_private_server.classic_solo_raid_runtime_state DROP CONSTRAINT %I',
                   constraint_name);
END;
$$;

ALTER TABLE lab_private_server.classic_solo_raid_runtime_state
    ADD CONSTRAINT uq_classic_runtime_selected_weakness UNIQUE (
        local_account_id, raid_snapshot_id, season_number,
        client_build_code, client_executable_sha256, selected_weakness_code
    );

-- The existing generic pointer guard also protects this new identity column.
