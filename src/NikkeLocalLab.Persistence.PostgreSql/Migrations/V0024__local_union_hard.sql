-- Local identity and membership outlive client/runtime releases.
CREATE TABLE lab_private_server.local_union (
    local_union_id SMALLINT PRIMARY KEY CHECK (local_union_id = 1),
    display_name TEXT NOT NULL CHECK (display_name = 'NLL'),
    union_level INTEGER NOT NULL CHECK (union_level >= 3),
    selected_season_number INTEGER CHECK (selected_season_number BETWEEN 1 AND 999)
);
INSERT INTO lab_private_server.local_union VALUES (1, 'NLL', 3, NULL);

CREATE TABLE lab_private_server.local_union_member (
    local_account_id BIGINT PRIMARY KEY REFERENCES lab_profile.local_account(local_account_id),
    local_union_id SMALLINT NOT NULL REFERENCES lab_private_server.local_union(local_union_id),
    joined_at_utc TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO lab_private_server.local_union_member(local_account_id, local_union_id)
SELECT local_account_id, 1 FROM lab_profile.local_account;

CREATE FUNCTION lab_private_server.join_local_union() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO lab_private_server.local_union_member(local_account_id, local_union_id)
    VALUES (NEW.local_account_id, 1);
    RETURN NEW;
END;
$$;
CREATE TRIGGER local_account_join_union AFTER INSERT ON lab_profile.local_account
FOR EACH ROW EXECUTE FUNCTION lab_private_server.join_local_union();

CREATE TABLE lab_private_server.local_union_raid_season (
    local_union_id SMALLINT NOT NULL REFERENCES lab_private_server.local_union(local_union_id),
    season_number INTEGER NOT NULL CHECK (season_number BETWEEN 1 AND 999),
    normal_cleared BOOLEAN NOT NULL DEFAULT TRUE CHECK (normal_cleared),
    catalog_sha256 BYTEA NOT NULL CHECK (octet_length(catalog_sha256) = 32),
    publication_root TEXT NOT NULL CHECK (length(publication_root) BETWEEN 1 AND 2048),
    receipt_sha256 BYTEA NOT NULL CHECK (octet_length(receipt_sha256) = 32),
    selected_at_utc TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (local_union_id, season_number)
);
