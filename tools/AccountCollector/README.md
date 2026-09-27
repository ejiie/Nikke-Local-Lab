# Account collector

The operator requested reuse of their Nikke-Simul account import. `collector.py`
and `profile_avatar_assets.py` are copied from ejiie/Nikke-Simul revision
`e9d7410a92a8b38619c0a8c4fe4f4f4c5133d004`, tools/data-pipeline.
`presentation_assets.py` retains only the asset helpers required by those files.
`nll.py` adapts the collected responses to NLL's existing sanitizer and adds
explicit union membership and local artwork metadata. Login remains interactive;
session storage is Windows DPAPI. No authentication data is sent to the editor.

Union query and artwork mapping were checked against the public Blablalink
modules `v4-DaeRWrZK.js`, `team-combat-icon-CBKXK4H7.js` and
`union-P4IXFV-5.js` on 2026-09-18. Only GetMyGuildInfo is called; joining,
publishing, supporting, and editing an official union are not implemented.

Equipped frames correction (2026-09-19): `GetUserGamePlayerInfo.avatar_frame`
is consumed by the site's profile statistics, not its avatar renderer. It must
not be interpreted as an equipped game-frame ID, even if the number matches a
local table key. The inspected account responses do not establish the equipped
frame. Collection records `profileFrameStatus=not_provided_by_source` and no
frame ID; it does not issue a misleading extra player-info request.

The failed initial implementation also confused the game's `game_openid` with
the community `intl_openid`; the site resolves the latter through
`User/GetUserInfoNew`. Fixing that query produced a successful response with
`avatar_frame=0`, not evidence of an equipped frame. Do not restore that mapping.

`extract_profile_frames.py` maps an already decoded private UserFrame table and
local user-frame bundle to `runtime-home/ProfileFrames/index.private.json` and
content-addressed PNGs. It restores trimmed sprite offsets, composites the sub
resource, and never downloads artwork. Prism animation is not reproduced.
The asset resolver requires an independently established equipped frame ID.
Missing metadata never discards valid account specs. The current local runtime's
`ProfileFrame` is a valid selection source, but does not establish what is
equipped on an imported official account. The index's transparent zero entry
must never be selected from the website's statistic.
