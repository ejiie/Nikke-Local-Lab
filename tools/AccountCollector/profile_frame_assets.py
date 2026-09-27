"""Resolve equipped frame metadata using the installed local bundle index only."""
import hashlib
import json
from pathlib import Path
import re
import shutil


def frame_id(payload, area):
    # GetUserGamePlayerInfo.avatar_frame feeds a profile statistic in the
    # website, not its avatar renderer. Neither zero nor a table-matching
    # number establishes which frame is equipped. Preserve unknown.
    return None


def prepare(value, runtime_root, account_root):
    if type(value) is not int or value < 0:
        return None
    root = Path(runtime_root) / "ProfileFrames"
    try:
        index = json.loads((root / "index.private.json").read_text(encoding="utf-8"))
        if index.get("contract") != "local-profile-frames/v1":
            return None
        digest = index["frames"].get(str(value))
        if not isinstance(digest, str) or not re.fullmatch(r"[a-f0-9]{64}", digest):
            return None
        source = root / (digest + ".png")
        content = source.read_bytes()
        if not content.startswith(b"\x89PNG\r\n\x1a\n") or hashlib.sha256(content).hexdigest() != digest:
            return None
        target = Path(account_root) / ("frame-" + digest + ".png")
        shutil.copyfile(source, target)
        return str(target.resolve())
    except (OSError, ValueError, KeyError):
        return None
