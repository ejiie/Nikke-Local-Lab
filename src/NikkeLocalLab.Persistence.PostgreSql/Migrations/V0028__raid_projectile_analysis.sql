ALTER TABLE lab_private_server.raid_battle_observation
    DROP CONSTRAINT raid_battle_observation_mode_check;
ALTER TABLE lab_private_server.raid_battle_observation
    ADD CONSTRAINT raid_battle_observation_mode_check CHECK
    (mode IN ('solo_challenge','solo_challenge_practice','union_hard','union_hard_practice'));

CREATE TABLE lab_private_server.raid_projectile_analysis (
    battle_uid UUID NOT NULL REFERENCES lab_private_server.raid_battle_observation(battle_uid),
    analysis_version TEXT NOT NULL,
    log_sha256 TEXT NOT NULL CHECK (log_sha256 ~ '^[0-9a-f]{64}$'),
    status TEXT NOT NULL,
    analyzed_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (battle_uid, analysis_version)
);
CREATE TABLE lab_private_server.raid_character_projectile_damage (
    battle_uid UUID NOT NULL,
    analysis_version TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    projectile_damage BIGINT NOT NULL CHECK (projectile_damage >= 0),
    excluded_damage BIGINT NOT NULL CHECK (excluded_damage >= 0),
    PRIMARY KEY (battle_uid, analysis_version, ordinal),
    FOREIGN KEY (battle_uid, analysis_version)
        REFERENCES lab_private_server.raid_projectile_analysis(battle_uid, analysis_version),
    FOREIGN KEY (battle_uid, ordinal)
        REFERENCES lab_private_server.raid_character_damage(battle_uid, ordinal)
);
CREATE INDEX raid_battle_observation_scope ON lab_private_server.raid_battle_observation
    (account_uid, season_number, mode, boss_step, accepted_at_utc DESC, battle_uid);
