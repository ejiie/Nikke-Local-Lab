-- No guessed payload backfill: legacy operations remain recognizable by absence.
ALTER TABLE lab_profile.account_workspace_save_operation
    ADD CONSTRAINT uq_workspace_save_request_binding
    UNIQUE (operation_uid, source_account_uid, operation_kind, request_sha256);

CREATE TABLE lab_profile.account_workspace_save_request (
    operation_uid UUID PRIMARY KEY,
    source_account_uid UUID NOT NULL,
    operation_kind TEXT NOT NULL,
    request_sha256 BYTEA NOT NULL,
    contract_id TEXT NOT NULL CHECK (contract_id = 'nll/account-workspace-save-envelope/v1'),
    request_payload BYTEA NOT NULL CHECK (octet_length(request_payload) BETWEEN 1 AND 16384),
    payload_sha256 BYTEA NOT NULL CHECK (payload_sha256 = sha256(request_payload)),
    FOREIGN KEY (operation_uid, source_account_uid, operation_kind, request_sha256)
        REFERENCES lab_profile.account_workspace_save_operation
            (operation_uid, source_account_uid, operation_kind, request_sha256) ON DELETE RESTRICT
);

CREATE FUNCTION lab_profile.guard_workspace_save_request()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'account_workspace_save_request_immutable';
END;
$$;

CREATE TRIGGER trg_workspace_save_request_immutable
BEFORE UPDATE OR DELETE ON lab_profile.account_workspace_save_request
FOR EACH ROW EXECUTE FUNCTION lab_profile.guard_workspace_save_request();
