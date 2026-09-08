CREATE TABLE lab_profile.fetched_progression_observation (
    fetched_account_snapshot_uid UUID PRIMARY KEY
        REFERENCES lab_profile.fetched_account_snapshot(fetched_account_snapshot_uid)
        ON DELETE RESTRICT,
    observation_contract_id TEXT NOT NULL CHECK (
        observation_contract_id = 'nll/fetched-progression-observation/v2'
    ),
    captured_at_utc TIMESTAMPTZ NOT NULL,
    completeness_status_code TEXT NOT NULL CHECK (
        completeness_status_code IN ('complete', 'incomplete')
    ),
    available_component_count INTEGER NOT NULL CHECK (
        available_component_count BETWEEN 0 AND 5
    ),
    derived_component_count INTEGER NOT NULL CHECK (
        derived_component_count BETWEEN 0 AND 5
    ),
    unavailable_component_count INTEGER NOT NULL CHECK (
        unavailable_component_count BETWEEN 0 AND 5
    ),
    completed_scenario_count INTEGER CHECK (completed_scenario_count >= 0),
    main_quest_completed_count INTEGER CHECK (main_quest_completed_count >= 0),
    main_quest_reward_claimed_count INTEGER CHECK (main_quest_reward_claimed_count >= 0),
    contents_open_unlocked_count INTEGER CHECK (contents_open_unlocked_count >= 0),
    stage_clear_history_count INTEGER CHECK (stage_clear_history_count >= 0),
    trigger_count INTEGER CHECK (trigger_count >= 0),
    canonical_observation_json TEXT NOT NULL CHECK (
        octet_length(canonical_observation_json) BETWEEN 2 AND 67108864
        AND jsonb_typeof(canonical_observation_json::jsonb) = 'object'
    ),
    canonical_observation_sha256 BYTEA NOT NULL CHECK (
        octet_length(canonical_observation_sha256) = 32
    ),
    imported_at_utc TIMESTAMPTZ NOT NULL,
    CHECK (
        available_component_count + derived_component_count + unavailable_component_count = 5
    ),
    CHECK (
        (canonical_observation_json::jsonb #>> '{schemaVersion}')::integer = 2
        AND canonical_observation_json::jsonb #>> '{contractId}' = observation_contract_id
        AND canonical_observation_json::jsonb #>> '{snapshotUid}' =
            fetched_account_snapshot_uid::text
        AND (canonical_observation_json::jsonb #>> '{capturedAtUtc}')::timestamptz =
            captured_at_utc
        AND canonical_observation_json::jsonb #>> '{completeness,statusCode}' =
            completeness_status_code
        AND (canonical_observation_json::jsonb #>>
            '{completeness,availableComponentCount}')::integer = available_component_count
        AND (canonical_observation_json::jsonb #>>
            '{completeness,derivedComponentCount}')::integer = derived_component_count
        AND (canonical_observation_json::jsonb #>>
            '{completeness,unavailableComponentCount}')::integer = unavailable_component_count
        AND ((canonical_observation_json::jsonb #>>
            '{completedScenarios,summary,itemCount}')::integer)
            IS NOT DISTINCT FROM completed_scenario_count
        AND ((canonical_observation_json::jsonb #>>
            '{mainQuestData,completedCount}')::integer)
            IS NOT DISTINCT FROM main_quest_completed_count
        AND ((canonical_observation_json::jsonb #>>
            '{mainQuestData,rewardClaimedCount}')::integer)
            IS NOT DISTINCT FROM main_quest_reward_claimed_count
        AND ((canonical_observation_json::jsonb #>>
            '{contentsOpenUnlocked,summary,itemCount}')::integer)
            IS NOT DISTINCT FROM contents_open_unlocked_count
        AND ((canonical_observation_json::jsonb #>>
            '{stageClearHistorys,summary,itemCount}')::integer)
            IS NOT DISTINCT FROM stage_clear_history_count
        AND ((canonical_observation_json::jsonb #>>
            '{triggers,summary,itemCount}')::integer)
            IS NOT DISTINCT FROM trigger_count
        AND (canonical_observation_json::jsonb #>> '{source,credentialOrSessionPersisted}')::boolean = false
        AND (canonical_observation_json::jsonb #>> '{source,officialUserIdentifierPersisted}')::boolean = false
        AND (canonical_observation_json::jsonb #>> '{source,rawSourcePersisted}')::boolean = false
        AND (canonical_observation_json::jsonb #>> '{source,rawSourcePathPersisted}')::boolean = false
        AND (canonical_observation_json::jsonb #>> '{source,rawSourceHashPersisted}')::boolean = false
    )
);

CREATE INDEX ix_fetched_progression_observation_capture
    ON lab_profile.fetched_progression_observation(captured_at_utc DESC);

CREATE TRIGGER trg_fetched_progression_observation_immutable
BEFORE UPDATE OR DELETE ON lab_profile.fetched_progression_observation
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();
