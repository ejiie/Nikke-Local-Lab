DO $migration$
DECLARE
    permissive_constraint_names TEXT[];
    permissive_constraint_name TEXT;
BEGIN
    SELECT array_agg(constraint_row.conname ORDER BY constraint_row.conname)
      INTO permissive_constraint_names
      FROM pg_constraint AS constraint_row
     WHERE constraint_row.conrelid =
               'lab_private_server.classic_solo_raid_runtime_state_revision'::regclass
       AND constraint_row.contype = 'c'
       AND pg_get_constraintdef(constraint_row.oid) LIKE
               '%completed_best_total_damage IS NULL%'
       AND pg_get_constraintdef(constraint_row.oid) LIKE
               '%completed_best_team_count >= 1%'
       AND pg_get_constraintdef(constraint_row.oid) LIKE
               '%completed_best_team_count <= 5%';

    IF cardinality(permissive_constraint_names) IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'phase_d_permissive_completed_best_shape_constraint_cardinality_invalid';
    END IF;

    FOREACH permissive_constraint_name IN ARRAY permissive_constraint_names
    LOOP
        EXECUTE format(
            'ALTER TABLE lab_private_server.classic_solo_raid_runtime_state_revision DROP CONSTRAINT %I',
            permissive_constraint_name);
    END LOOP;
END
$migration$;

-- Historical V0015 rows are immutable audit evidence, so the corrected
-- constraint is intentionally NOT VALID. PostgreSQL still enforces it for all
-- new revisions while retaining the bad historical rows until a valid capture
-- advances the aggregate head.
ALTER TABLE lab_private_server.classic_solo_raid_runtime_state_revision
    ADD CONSTRAINT ck_classic_solo_raid_runtime_state_revision_completed_best_shape
    CHECK (
        (completed_best_total_damage IS NULL AND completed_best_team_count = 0)
        OR
        (completed_best_total_damage IS NOT NULL AND completed_best_team_count = 5)
    ) NOT VALID;
