CREATE TABLE lab_profile.account_workspace_save_operation (
    operation_uid UUID PRIMARY KEY CHECK (
        operation_uid <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    operation_kind TEXT NOT NULL CHECK (operation_kind IN ('save', 'save_as')),
    request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256) = 32),
    source_account_uid UUID NOT NULL
        REFERENCES lab_profile.local_account(local_account_uid) ON DELETE RESTRICT,
    operation_status TEXT NOT NULL CHECK (operation_status IN ('pending', 'completed')),
    resolved_lobby_revision_uid UUID
        REFERENCES lab_local_game.lobby_presentation_revision(
            lobby_presentation_revision_uid
        ) ON DELETE RESTRICT,
    result_account_uid UUID
        REFERENCES lab_profile.local_account(local_account_uid) ON DELETE RESTRICT,
    result_account_label TEXT,
    result_profile_revision_uid UUID
        REFERENCES lab_profile.profile_template_revision(
            profile_template_revision_uid
        ) ON DELETE RESTRICT,
    result_lobby_revision_uid UUID
        REFERENCES lab_local_game.lobby_presentation_revision(
            lobby_presentation_revision_uid
        ) ON DELETE RESTRICT,
    result_wallet_revision_uid UUID
        REFERENCES lab_local_game.wallet_revision(wallet_revision_uid) ON DELETE RESTRICT,
    result_revision_set_sha256 BYTEA CHECK (
        result_revision_set_sha256 IS NULL OR octet_length(result_revision_set_sha256) = 32
    ),
    created_at_utc TIMESTAMPTZ NOT NULL,
    completed_at_utc TIMESTAMPTZ,
    CHECK (
        (operation_status = 'pending'
            AND result_account_uid IS NULL
            AND result_account_label IS NULL
            AND result_profile_revision_uid IS NULL
            AND result_lobby_revision_uid IS NULL
            AND result_wallet_revision_uid IS NULL
            AND result_revision_set_sha256 IS NULL
            AND completed_at_utc IS NULL)
        OR
        (operation_status = 'completed'
            AND result_account_uid IS NOT NULL
            AND result_account_label IS NOT NULL
            AND result_profile_revision_uid IS NOT NULL
            AND result_lobby_revision_uid IS NOT NULL
            AND result_wallet_revision_uid IS NOT NULL
            AND result_revision_set_sha256 IS NOT NULL
            AND completed_at_utc IS NOT NULL)
    ),
    CHECK (operation_kind = 'save' OR resolved_lobby_revision_uid IS NULL)
);

CREATE INDEX ix_account_workspace_save_operation_source
    ON lab_profile.account_workspace_save_operation(source_account_uid, created_at_utc DESC);

CREATE FUNCTION lab_profile.guard_account_workspace_save_operation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.operation_status = 'completed' THEN
        RAISE EXCEPTION 'account_workspace_save_operation_immutable';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    IF NEW.operation_uid IS DISTINCT FROM OLD.operation_uid
       OR NEW.operation_kind IS DISTINCT FROM OLD.operation_kind
       OR NEW.request_sha256 IS DISTINCT FROM OLD.request_sha256
       OR NEW.source_account_uid IS DISTINCT FROM OLD.source_account_uid
       OR NEW.created_at_utc IS DISTINCT FROM OLD.created_at_utc
       OR OLD.resolved_lobby_revision_uid IS NOT NULL
          AND NEW.resolved_lobby_revision_uid IS DISTINCT FROM OLD.resolved_lobby_revision_uid THEN
        RAISE EXCEPTION 'account_workspace_save_operation_identity_immutable';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_account_workspace_save_operation_guard
BEFORE UPDATE OR DELETE ON lab_profile.account_workspace_save_operation
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_account_workspace_save_operation();
