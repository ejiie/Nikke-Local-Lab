-- Local battle keys link numeric observations; no source identifiers or report blobs.
CREATE TABLE lab_private_server.raid_battle_observation (
    battle_uid UUID PRIMARY KEY,
    account_uid UUID NOT NULL REFERENCES lab_profile.local_account(local_account_uid),
    mode TEXT NOT NULL CHECK (mode IN ('solo_challenge','union_hard','union_hard_practice')),
    season_number INTEGER NOT NULL CHECK (season_number > 0),
    raid_level INTEGER NOT NULL,
    boss_step INTEGER NOT NULL,
    team INTEGER NOT NULL,
    request_damage BIGINT NOT NULL,
    accepted_damage BIGINT NOT NULL,
    accepted_at_utc TIMESTAMPTZ NOT NULL,
    payload JSONB NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    payload_sha256 BYTEA NOT NULL CHECK (octet_length(payload_sha256) = 32)
);
CREATE INDEX raid_battle_observation_account_time
    ON lab_private_server.raid_battle_observation(account_uid,accepted_at_utc DESC);
CREATE TABLE lab_private_server.raid_character_damage (
    battle_uid UUID NOT NULL REFERENCES lab_private_server.raid_battle_observation(battle_uid),
    ordinal INTEGER NOT NULL CHECK (ordinal > 0),
    slot INTEGER NOT NULL,
    character_uid UUID,
    attack_total_damage BIGINT,
    attack_total_actual_damage BIGINT,
    skill_total_damage BIGINT,
    skill_total_actual_damage BIGINT,
    stat_function_total_damage BIGINT,
    stat_function_total_actual_damage BIGINT,
    PRIMARY KEY (battle_uid,ordinal)
);
CREATE TABLE lab_private_server.raid_monster_damage (
    battle_uid UUID NOT NULL REFERENCES lab_private_server.raid_battle_observation(battle_uid),
    ordinal INTEGER NOT NULL CHECK (ordinal > 0),
    hp_total_damage_received BIGINT,
    hp_total_actual_damage_received BIGINT,
    parts_destroy_damage_received BIGINT,
    projectile_damage_received BIGINT,
    PRIMARY KEY (battle_uid,ordinal)
);
