ALTER TABLE lab_profile.account_workspace_save_operation
ADD COLUMN observation_provenance_resolved BOOLEAN NOT NULL DEFAULT FALSE,
ADD COLUMN resolved_observation_snapshot_uid UUID
    REFERENCES lab_profile.fetched_account_snapshot(fetched_account_snapshot_uid)
    ON DELETE RESTRICT,
ADD CONSTRAINT ck_account_workspace_save_observation_resolution CHECK (
    (operation_kind = 'save_as')
    OR (
        observation_provenance_resolved = FALSE
        AND resolved_observation_snapshot_uid IS NULL
    )
),
ADD CONSTRAINT ck_account_workspace_save_observation_snapshot CHECK (
    resolved_observation_snapshot_uid IS NULL
    OR observation_provenance_resolved = TRUE
);

CREATE TABLE lab_profile.account_observation_provenance_binding (
    target_local_account_id BIGINT PRIMARY KEY
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    save_as_source_account_uid UUID NOT NULL
        REFERENCES lab_profile.local_account(local_account_uid) ON DELETE RESTRICT,
    source_snapshot_uid UUID
        REFERENCES lab_profile.fetched_account_snapshot(fetched_account_snapshot_uid)
        ON DELETE RESTRICT,
    binding_kind TEXT NOT NULL CHECK (
        binding_kind IN ('save_as/v1', 'legacy_parent_fallback/v1')
    ),
    save_operation_uid UUID UNIQUE
        REFERENCES lab_profile.account_workspace_save_operation(operation_uid)
        ON DELETE RESTRICT,
    bound_at_utc TIMESTAMPTZ NOT NULL,
    CHECK (
        (binding_kind = 'save_as/v1' AND save_operation_uid IS NOT NULL)
        OR
        (binding_kind = 'legacy_parent_fallback/v1' AND save_operation_uid IS NULL)
    )
);

CREATE INDEX ix_account_observation_provenance_source
    ON lab_profile.account_observation_provenance_binding(
        save_as_source_account_uid,
        bound_at_utc DESC
    );

WITH RECURSIVE ancestry AS (
    SELECT
        workspace.local_account_id AS target_local_account_id,
        workspace.save_as_parent_account_uid AS direct_source_account_uid,
        workspace.save_as_parent_account_uid AS ancestor_account_uid,
        1 AS depth
    FROM lab_profile.account_workspace AS workspace
    WHERE workspace.save_as_parent_account_uid IS NOT NULL

    UNION ALL

    SELECT
        ancestry.target_local_account_id,
        ancestry.direct_source_account_uid,
        parent_workspace.save_as_parent_account_uid,
        ancestry.depth + 1
    FROM ancestry
    JOIN lab_profile.local_account AS parent_account
      ON parent_account.local_account_uid = ancestry.ancestor_account_uid
    JOIN lab_profile.account_workspace AS parent_workspace
      ON parent_workspace.local_account_id = parent_account.local_account_id
    WHERE parent_workspace.save_as_parent_account_uid IS NOT NULL
      AND ancestry.depth < 64
),
legacy_binding AS (
    SELECT DISTINCT ON (ancestry.target_local_account_id)
        ancestry.target_local_account_id,
        ancestry.direct_source_account_uid,
        snapshot.fetched_account_snapshot_uid AS source_snapshot_uid
    FROM ancestry
    LEFT JOIN lab_profile.local_account AS ancestor_account
      ON ancestor_account.local_account_uid = ancestry.ancestor_account_uid
    LEFT JOIN LATERAL (
        SELECT candidate.fetched_account_snapshot_uid,
               candidate.captured_at_utc,
               candidate.imported_at_utc,
               candidate.fetched_account_snapshot_id
        FROM lab_profile.fetched_account_snapshot AS candidate
        WHERE candidate.target_local_account_id = ancestor_account.local_account_id
        ORDER BY candidate.captured_at_utc DESC,
                 candidate.imported_at_utc DESC,
                 candidate.fetched_account_snapshot_id DESC
        LIMIT 1
    ) AS snapshot ON TRUE
    ORDER BY ancestry.target_local_account_id,
             (snapshot.fetched_account_snapshot_uid IS NULL),
             ancestry.depth,
             snapshot.captured_at_utc DESC,
             snapshot.imported_at_utc DESC,
             snapshot.fetched_account_snapshot_id DESC
)
INSERT INTO lab_profile.account_observation_provenance_binding (
    target_local_account_id,
    save_as_source_account_uid,
    source_snapshot_uid,
    binding_kind,
    save_operation_uid,
    bound_at_utc
)
SELECT
    legacy_binding.target_local_account_id,
    legacy_binding.direct_source_account_uid,
    legacy_binding.source_snapshot_uid,
    'legacy_parent_fallback/v1',
    NULL,
    workspace.created_at_utc
FROM legacy_binding
JOIN lab_profile.account_workspace AS workspace
  ON workspace.local_account_id = legacy_binding.target_local_account_id;

CREATE TRIGGER trg_account_observation_provenance_binding_immutable
BEFORE UPDATE OR DELETE ON lab_profile.account_observation_provenance_binding
FOR EACH ROW EXECUTE FUNCTION lab_local_game.reject_immutable_mutation();
