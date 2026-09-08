-- Additive inventory on immutable account revisions. Legacy revisions retain zero rows.
ALTER TABLE lab_profile.account_state_revision
    ADD COLUMN cube_count INTEGER NOT NULL DEFAULT 0 CHECK (cube_count BETWEEN 0 AND 10000);

CREATE TABLE lab_profile.account_cube_state (
    account_state_revision_id BIGINT NOT NULL,
    support_catalog_snapshot_id BIGINT NOT NULL,
    definition_entity_id BIGINT NOT NULL,
    definition_version_id BIGINT NOT NULL,
    definition_kind TEXT NOT NULL CHECK (definition_kind = 'cube'),
    level INTEGER NOT NULL CHECK (level BETWEEN 1 AND 15),
    PRIMARY KEY (account_state_revision_id, definition_entity_id),
    FOREIGN KEY (account_state_revision_id, support_catalog_snapshot_id)
        REFERENCES lab_profile.account_state_revision(account_state_revision_id, support_catalog_snapshot_id),
    FOREIGN KEY (support_catalog_snapshot_id, definition_entity_id, definition_version_id, definition_kind)
        REFERENCES lab_combat_support.catalog_snapshot_member(
            catalog_snapshot_id, definition_entity_id, definition_version_id, definition_kind)
);

CREATE FUNCTION lab_profile.guard_account_cube_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE expected_count INTEGER;
BEGIN
    SELECT cube_count INTO expected_count FROM lab_profile.account_state_revision
    WHERE account_state_revision_id = NEW.account_state_revision_id FOR UPDATE;
    IF expected_count IS NULL OR expected_count <= (
        SELECT count(*) FROM lab_profile.account_cube_state
        WHERE account_state_revision_id = NEW.account_state_revision_id
    ) THEN
        RAISE EXCEPTION 'immutable_profile_row';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM lab_combat_support.definition_level_coordinate
        WHERE definition_version_id = NEW.definition_version_id AND level = NEW.level
    ) THEN
        RAISE EXCEPTION 'profile_cube_level_not_in_catalog';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lab_profile.require_complete_cube_inventory()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.cube_count <> (
        SELECT count(*) FROM lab_profile.account_cube_state
        WHERE account_state_revision_id = NEW.account_state_revision_id
    ) THEN
        RAISE EXCEPTION 'profile_account_cube_inventory_incomplete';
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_account_cube_guard_insert BEFORE INSERT ON lab_profile.account_cube_state
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_account_cube_insert();
CREATE TRIGGER trg_account_cube_immutable BEFORE UPDATE OR DELETE ON lab_profile.account_cube_state
FOR EACH ROW EXECUTE FUNCTION lab_profile.reject_immutable_mutation();
CREATE CONSTRAINT TRIGGER trg_account_cube_complete AFTER INSERT ON lab_profile.account_state_revision
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION lab_profile.require_complete_cube_inventory();
