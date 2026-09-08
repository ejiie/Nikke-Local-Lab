CREATE TABLE lab_profile.account_workspace (
    local_account_id BIGINT PRIMARY KEY
        REFERENCES lab_profile.local_account(local_account_id) ON DELETE RESTRICT,
    workspace_uid UUID NOT NULL UNIQUE CHECK (
        workspace_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    account_label TEXT NOT NULL UNIQUE CHECK (
        char_length(account_label) BETWEEN 1 AND 64
        AND account_label = btrim(account_label)
        AND account_label !~ '[/\\:]'
    ),
    save_as_parent_account_uid UUID
        REFERENCES lab_profile.local_account(local_account_uid) ON DELETE RESTRICT,
    fetched_snapshot_uid UUID CHECK (
        fetched_snapshot_uid IS NULL
        OR fetched_snapshot_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    last_fetched_at_utc TIMESTAMPTZ,
    last_execution_result_code TEXT CHECK (
        last_execution_result_code IS NULL
        OR last_execution_result_code ~ '^[a-z][a-z0-9._-]{0,63}$'
    ),
    created_at_utc TIMESTAMPTZ NOT NULL,
    updated_at_utc TIMESTAMPTZ NOT NULL,
    CHECK (
        (fetched_snapshot_uid IS NULL) = (last_fetched_at_utc IS NULL)
    )
);

INSERT INTO lab_profile.account_workspace (
    local_account_id,
    workspace_uid,
    account_label,
    save_as_parent_account_uid,
    fetched_snapshot_uid,
    last_fetched_at_utc,
    last_execution_result_code,
    created_at_utc,
    updated_at_utc
)
SELECT
    account.local_account_id,
    account.local_account_uid,
    'account_' || account.local_account_uid::text,
    NULL,
    NULL,
    NULL,
    NULL,
    account.created_at_utc,
    account.created_at_utc
FROM lab_profile.local_account AS account;

CREATE INDEX ix_account_workspace_label
    ON lab_profile.account_workspace(account_label);

CREATE INDEX ix_account_workspace_parent
    ON lab_profile.account_workspace(save_as_parent_account_uid)
    WHERE save_as_parent_account_uid IS NOT NULL;
