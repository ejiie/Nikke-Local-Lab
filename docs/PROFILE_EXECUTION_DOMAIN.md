# Local profile and battle execution contract

## 목적

별도 관리 도구에서 합성 local account의 캐릭터 빌드와 계정 전역 전투 상태를 수정하고, 재현 가능한 실행 환경과 함께 Solo Raid Challenge 전투에 연결합니다.

이 기능은 Local Lab PostgreSQL과 loopback API만 수정합니다. 공식 계정, `C:\NIKKE`, BlaBla, 공식 API·서버로 write하지 않습니다. 원본 UI에 반영하는 경로는 `FEASIBILITY_GATES.md`가 해제된 경우에만 별도 adapter가 담당합니다.

## 개체 경계

### LocalAccount

Local Lab이 발급한 무작위 자체 UID만 사용합니다. 실제 계정 UID, 토큰, 세션 식별자를 저장하거나 export하지 않습니다.

### AccountCombatStateRevision

계정 전체에 적용되는 전투 상태의 불변 revision입니다.

- dataset snapshot UID
- synchro level과 그 해석 상태
- 자체 `console_definition_uid`별 console level
- validation mode와 readiness
- import 또는 사용자 편집 provenance

console을 각 `CharacterBuildRevision`에 복제하지 않습니다. 한 전투는 사용한 account combat state revision을 명시적으로 참조합니다.

### ProfileTemplateRevision

캐릭터 build revision 집합과 account combat state revision을 묶는 불변 템플릿입니다. portable export는 원본 ID 대신 정확한 catalog manifest와 normalized content hash로 항목을 해소합니다. 다른 dataset에 적용하려면 명시적인 rebase가 필요합니다.

### RuntimeExecutionProfileRevision

요청한 client 실행 환경을 저장하는 불변 revision입니다. 보스와 asset의 불변 근거인 `RaidSnapshot` 또는 캐릭터 build에 포함하지 않습니다.

- client/runtime build UID와 hash
- target frame-rate `fps30|fps60`, 기대 fixed delta `1/30|1/60`, VSync
- Solo Raid에서 `multiplayer_enabled=false`
- time-scale policy `normal_1x|unresolved`
- display/fullscreen mode, width, height와 effective refresh rate
- `GraphicOptionMode`, `DefaultQualityLevel`, `PostProcessFlags`, `VolumetricFogQuality`
- `BattleEffectQuality`, `BattleAnimationPhysicsFlags`, `SpineResolution`, `TextureQuality`, `MeshQuality`
- anti-aliasing enabled/step과 그 밖에 실제 client field가 확인된 그래픽 설정
- platform과 설정 artifact hash
- 각 항목의 `ready`, `unresolved`, `not_applicable` 상태

현재 정적 근거상 target FPS는 30/60에 따라 `Application.targetFrameRate`와 `Time.fixedDeltaTime`을 바꾸고, Spot 주 루프는 렌더 프레임마다 `Time.deltaTime`을 소비합니다. 따라서 FPS·fixed delta·time scale·multiplayer override 중 하나라도 unresolved이면 golden 전투 비교를 허용하지 않습니다.

graphics quality, target FPS, VSync와 resolution/display mode는 이 프로젝트의 필수 실행 입력입니다. 지원되는 값 전체를 읽고 저장하며, 단순 UI preference로 생략하지 않습니다. render scale이나 shadow처럼 아직 exact client field가 확인되지 않은 값은 추측으로 필수화하지 않고, 근거가 확보되면 versioned field로 추가합니다.

설정값을 요청했다는 사실과 runtime이 실제 적용한 값을 구분합니다. 유효한 요청값은 `launch_ready`가 될 수 있지만, effective read-back과 frame telemetry가 일치하지 않으면 `golden_ready`가 될 수 없습니다. client field와 PlayerPrefs key의 의미는 정적으로 확인됐지만 물리 저장 위치와 지원되는 apply/read-back adapter는 아직 확인되지 않았습니다. 그 전에는 registry, preference 또는 게임 파일을 관리 도구가 직접 수정하지 않으며 추정 registry key를 사용하지 않습니다.

### CombatControlProfileRevision

PC 필수 전투 입력은 `AimSensitivity`, `UseAimAssistant`, 활성화 시의 `AimAssistantIntensity`, `UsePcAimSync`와 `MaxPerShotCorrect`입니다. 캐릭터 전환과 조준 위치 초기화처럼 실제 조준 결과에 영향을 주는 설정도 검증된 항목만 저장합니다. 모바일용 `UseAimSync`와 X/Y 축 동기화 값은 PC에서는 `not_applicable`이며, PC relevance가 따로 입증되기 전에는 필수화하지 않습니다.

auto combat과 auto burst는 초기 완성 조건이 아닙니다. 지원할 경우 optional 설정으로 기록할 수 있지만, 미구현 또는 unresolved여도 수동 전투 session의 readiness를 막지 않습니다.

`MaxPerShotCorrect`는 이 profile이 authoritative하게 소유합니다. 이 값에 따라 기본 무기 update와 frame-delta 보정 무기 update 경로가 갈리므로 unresolved이면 전투 비교를 막습니다. execution profile에 값을 중복 저장하지 않고 battle record가 두 profile UID를 함께 결합합니다.

### BattleExecutionRecord

전투 결과는 최소한 다음 조합을 참조합니다.

    raid_snapshot_uid
    account_combat_state_revision_uid
    squad_revision_uid
    character_build_revision_uid[]
    runtime_execution_profile_revision_uid
    combat_control_profile_revision_uid

요청한 frame-rate만으로 60 FPS 실행을 주장하지 않습니다. 실제 render frame, behavior tick, fixed update, wall-clock duration, frame-time median/p95/p99와 dropped/stalled frame 관측치를 별도 telemetry로 저장합니다.

설정은 영향 범위를 `scheduler_critical`, `simulation_path`, `asset_selection`, `presentation_load`로 분류합니다. 예를 들어 target FPS와 fixed delta는 scheduler critical, `max_per_shot_correct`는 simulation path, mesh quality처럼 prefab/addressable 선택에 쓰이는 값은 asset selection입니다. 나머지 그래픽 값도 부하와 frame drop에 영향을 줄 수 있어 presentation load로 보존합니다.

Phase 1C의 behavior/timeline 근거는 `behavior_tick`, `render_frame`, `fixed_update`, `wall_clock` 중 clock basis와 scheduler-order evidence를 명시합니다. animation event frame을 절대 battle frame으로 자동 동일시하지 않습니다.

### In-battle ESC and execution segments

전투 중 ESC 화면에서 누적 damage와 전투 중 노출되는 설정을 확인할 수 있어야 합니다. 원본 UI의 damage는 현재 client `StatisticsContext`에서 계산되므로 backend가 재계산해 화면에 공급하는 값이 아닙니다. Local Lab은 이 원본 경로를 막지 않고, 검증과 저장을 위해 다음 live snapshot을 관찰·보존합니다.

- battle run UID
- 관측 battle frame/tick과 wall-clock
- 현재까지의 cumulative damage
- 현재 runtime execution profile revision UID
- 현재 combat control profile revision UID

전투 중 ESC에서 실제로 노출·변경 가능한 graphics/FPS/VSync/resolution 또는 마우스 동기화·조준 보정이 바뀌면 기존 revision을 수정하지 않습니다. 변경 요청 frame과 적용 후 전투가 재개되어 effective 값이 관찰된 frame을 구분하고, 후자에서 새 profile revision과 execution segment를 원자적으로 시작합니다. 최종 결과는 겹치거나 비는 구간 없이 모든 segment를 참조합니다. 설정 변경이 없으면 segment는 하나입니다. ESC pause 동안 battle clock이 멈추는지와 wall clock 처리 방식은 실측 전까지 unresolved입니다.

## Console 해석

console definition은 Phase 1D 전투 보조 catalog가 source에서 정규화합니다. 저장값은 자체 UID와 level이며, 원본 console ID를 API나 export에 넣지 않습니다.

현재 모델의 좌표는 개인 공용 1개, 클래스 3개(화력형·방어형·지원형), 기업 5개(엘리시온·미실리스·테트라·필그림·어브노멀)로 총 9개입니다. 캐릭터에는 개인 공용 + 해당 클래스 + 해당 기업 기여가 합산됩니다. 전투 입력은 level로 해소할 수 있지만 무손실 계정 복원을 목표로 하면 각 좌표의 EXP도 별도 상태로 보존해야 합니다.

console level의 stat 기여는 definition version에서 해소하고 전투 시 account combat state revision과 캐릭터 build를 결합합니다. 사용자 프로필에서 console 값이 결손되거나 progress EXP가 유실된 경우 level을 추측하지 않고 `unresolved` 또는 부분 관측으로 남깁니다.

## Offline legacy profile import

`Nikke-Dmg-Simulator/Database/processed`의 기존 파일은 네트워크 없이 읽는 legacy source로만 취급합니다. Local Lab이 공식 로그인, API replay 또는 재수집을 수행하지 않습니다. 파일 경로, 파일명, 실제 계정 UID와 원본 ID는 ledger, API, diagnostic, export에 남기지 않습니다.

현재 processed 형식에서 안전하게 관찰할 수 있는 항목은 다음과 같습니다.

- 적용된 캐릭터 level 관측치
- limit break와 core 스칼라
- bond level
- 세 skill level
- 장비 부위별 tier, 강화 level, 제조사 코드 관측치
- 장착 cube와 level 관측치
- synchro level
- console별 관찰 level

다음 항목은 손실이 있어 lossless write 입력으로 사용할 수 없습니다.

- native investment level과 synchro 적용 level의 구분
- 장비 definition과 inventory instance
- OL의 equipment slot, line index, 빈 line, 정확한 option reference
- cube 미장착과 결손의 구분
- generic collection과 character-specific favorite item의 식별
- console EXP와 완전한 진행 상태
- capture 시점의 단일 원자 snapshot 보장

부분 importer는 손실 필드를 추측하지 않고 controlled reason code를 사용합니다.

- `native_level_not_retained`
- `equipment_definition_not_retained`
- `overload_slot_line_not_retained`
- `collection_favorite_identity_not_retained`
- `console_progress_not_retained`
- `detached_vs_missing_ambiguous`

기존 merged 파일의 정적 캐릭터 정보는 import하지 않습니다. 현재 Local Lab catalog를 사용하고, raw source 식별자는 ephemeral HMAC alias 해소 뒤 폐기합니다. 파생 combat power는 write 입력이 아니라 검산용 observation으로만 둘 수 있습니다.

기존 `getFromBlaLink.py`는 사용자가 필요할 때 직접 실행하는 외부 수집 도구로 유지합니다. Local Lab이 이 crawler를 호출하거나 로그인·request replay를 자동화하지 않습니다. 관리 도구의 `Refresh from latest raw`는 사용자가 선택했거나 이미 생성된 최신 파일을 offline sanitizer로 다시 읽습니다. 중복 판정은 credential-bearing raw file hash를 저장하는 방식이 아니라 민감 필드를 제거한 canonical sanitized-payload hash로 수행합니다. 변경된 payload는 새 immutable import snapshot과 diff를 만들며, 기존 local editor revision을 자동 덮어쓰지 않습니다.

### Credential-bearing raw artifact

기존 raw capture에는 processed 형식에서 유실된 다음 관측치가 남아 있습니다.

- roster level과 character-detail level의 서로 다른 두 관측치
- 각 장비 부위의 definition reference, tier, 강화 level, 제조사
- 각 부위의 OL 1~3번 line reference와 exact state-effect integer
- 장착 cube와 level
- collection/favorite item reference와 level
- synchro level과 occupied slot count
- 9개 console의 level과 EXP

이 정보로 전투용 local profile을 더 정확히 복원할 수 있지만, 원본 raw 파일에는 실제 계정 UID, open identifier, URL과 로그인 응답 token도 함께 존재합니다. 따라서 이 파일 자체를 Local Lab DB, vault export, CLI output 또는 Git로 복사하지 않습니다.

별도 offline sanitizer가 source를 read-only로 열고 허용한 packet·field만 메모리에서 정규화한 뒤 즉시 폐기해야 합니다. credential, URL, trace, profile/social/outpost 비전투 필드는 읽더라도 결과 모델에 전달하지 않습니다. Local Lab은 이 capture를 새로 만들기 위한 브라우저 로그인, request interception 또는 authenticated replay를 구현하거나 실행하지 않습니다.

raw capture에도 graphics/FPS/control setting은 없습니다. 이는 별도 execution/control capture에서 가져옵니다. roster와 detail의 두 level 의미도 authoritative mapping 전에는 병합하지 않고 각각의 observation으로 보존합니다.

미장착 cube·collection의 공식 계정 보유 inventory와 OL lock/reset history는 전투 프로필 범위 밖이며 import completeness 조건이 아닙니다. 현재 장착 상태와 OL의 부위·줄·exact 값만 보존합니다. 다만 editor가 자유롭게 장착할 수 있도록 게임 데이터에서 정규화한 전체 equipment/cube/collection/favorite **definition catalog**는 필요합니다. 이는 사용자가 실제로 보유한 inventory를 복제한다는 뜻이 아닙니다.

공식 장비 instance UID도 요구하지 않습니다. Character build는 네 slot의 definition과 상태를 직접 소유할 수 있습니다. 향후 client compatibility가 instance reference를 요구할 때만 Local Lab이 자체 무작위 equipment instance UID를 발급하며, 원본 계정의 inventory identity를 복사하지 않습니다.

## Save 동작

### Save

같은 local profile의 수정된 부분에 새 immutable revision을 생성하고, 예상 이전 revision을 조건으로 current pointer를 원자적으로 교체합니다. 동시 수정 충돌은 덮어쓰지 않고 사용자에게 diff를 반환합니다.

### Save As

새 profile UID와 revision 1을 발급합니다. 새 합성 local account로 복제할 때 build와 account-state revision UID를 새로 발급하고, compatibility상 equipment instance가 필요하면 그 UID도 새로 발급합니다. source account UID와 import alias는 복사하지 않습니다.

### Apply to another account

같은 Local Lab DB의 합성 account만 대상입니다. 적용 전에 catalog/dataset 호환성, unresolved 값, validation mode와 전체 diff를 보여주고 사용자가 선택한 범위만 새 revision으로 적용합니다.

지원할 복제 범위는 명시적으로 분리합니다.

- 전체 profile: builds와 account combat state
- builds only: 대상 account의 synchro/console 유지
- account state only: 대상 account의 builds 유지

### Export and import

`Save As`와 portable export는 다른 동작입니다. export에는 schema version, catalog manifest hash, canonical payload hash와 normalized value만 포함합니다. 실제 계정 식별자, 원본 ID, 파일 경로, 자격증명, raw payload는 금지합니다. dataset이 다르면 자동 이름 매칭하지 않고 명시적 mapping/rebase를 요구합니다.

## 별도 관리 도구

별도 관리 UI는 권장합니다. 단, PostgreSQL을 직접 편집하는 DB client가 아니라 loopback Application/API의 command client여야 합니다.

필수 화면은 profile/account 선택, roster/build 편집, synchro/console 편집, execution/control profile 편집, validation 상태, Save/Save As/Apply diff입니다. 모든 write command는 새 revision을 만들고 audit receipt에는 자체 UID와 controlled code만 남깁니다.

## 구현 순서

1. Phase 1C — Challenge snapshot importer와 `V0003__raid_snapshot.sql`
2. Phase 1D — equipment, cube, console, OL option 전투 보조 catalog와 `V0004__combat_support_catalog.sql`
3. Phase 2A1 — local account, account combat state, character build/profile revision과 `V0005__local_account_profile.sql`
4. Phase 2A2 — offline legacy importer, export, loopback API와 별도 editor
5. Phase 2B — runtime/control profile, Challenge session과 `V0006__battle_execution_context.sql`

Phase 1C 구현과 legacy source 감사·계약 설계는 병행할 수 있습니다. migration, solution, CLI, workflow와 integration test가 충돌하므로 profile persistence와 editor 구현은 Phase 1C 병합 후 시작합니다.
