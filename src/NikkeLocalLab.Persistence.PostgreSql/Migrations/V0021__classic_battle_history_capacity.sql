-- Full histories replace the former best/open-only envelope. Never trim old
-- battles to fit. Exceeding this resource ceiling keeps the pending capture
-- recoverable and fails completion rather than deleting records.
DO $$
DECLARE constraint_row RECORD; changed INTEGER := 0;
BEGIN
    FOR constraint_row IN
        SELECT conname FROM pg_constraint
         WHERE conrelid = 'lab_private_server.classic_solo_raid_runtime_state_revision'::regclass
           AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%1048576%'
    LOOP
        EXECUTE format('ALTER TABLE lab_private_server.classic_solo_raid_runtime_state_revision DROP CONSTRAINT %I', constraint_row.conname);
        changed := changed + 1;
    END LOOP;
    IF changed <> 2 THEN RAISE EXCEPTION 'classic_history_capacity_baseline_mismatch'; END IF;
END;
$$;
ALTER TABLE lab_private_server.classic_solo_raid_runtime_state_revision
    ADD CONSTRAINT classic_history_protected_capacity CHECK (octet_length(protected_payload) BETWEEN 53 AND 67108864),
    ADD CONSTRAINT classic_history_length_capacity CHECK (protected_payload_byte_length BETWEEN 53 AND 67108864);
