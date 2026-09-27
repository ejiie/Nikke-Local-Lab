-- Local presentation identity; never stores a remote account/session identifier.
ALTER TABLE lab_private_server.local_union DROP CONSTRAINT local_union_local_union_id_check;
ALTER TABLE lab_private_server.local_union DROP CONSTRAINT local_union_display_name_check;
ALTER TABLE lab_private_server.local_union DROP CONSTRAINT local_union_union_level_check;
ALTER TABLE lab_private_server.local_union ADD CHECK (local_union_id > 0);
ALTER TABLE lab_private_server.local_union ADD CHECK (length(display_name) BETWEEN 1 AND 64);
ALTER TABLE lab_private_server.local_union ADD CHECK (union_level BETWEEN 1 AND 1000000);
ALTER TABLE lab_private_server.local_union ADD COLUMN union_uid UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE;
ALTER TABLE lab_private_server.local_union ADD COLUMN source_fingerprint BYTEA UNIQUE CHECK (octet_length(source_fingerprint)=32);
ALTER TABLE lab_private_server.local_union ADD COLUMN emblem_path TEXT CHECK (emblem_path ~ '^/admin-api/v1/account-art/[0-9a-f-]{36}-emblem-[0-9a-f]{64}[.]png$');
CREATE TABLE lab_profile.account_directory_presentation (
  local_account_id BIGINT PRIMARY KEY REFERENCES lab_profile.local_account(local_account_id),
  portrait_path TEXT CHECK (portrait_path ~ '^/admin-api/v1/account-art/[0-9a-f-]{36}-portrait-[0-9a-f]{64}[.]png$'),
  frame_path TEXT CHECK (frame_path ~ '^/admin-api/v1/account-art/[0-9a-f-]{36}-frame-[0-9a-f]{64}[.]png$'),
  imported_at_utc TIMESTAMPTZ
);
CREATE TABLE lab_profile.account_directory_creation (
  operation_uid UUID PRIMARY KEY,
  request_sha256 BYTEA NOT NULL CHECK (octet_length(request_sha256)=32)
);
