# Decisions

현재 상태 권위는 [HANDOFF](HANDOFF.md), 남은 작업은 [NEXT_STEPS](NEXT_STEPS.md)다.
아래 최초 Phase의 150 first-proof/미정 항목은 당시 결정 이력이며, 현재 실행 경로를 다시
미실행 상태로 되돌리거나 이미 완료된 안정화 작업을 재지시하지 않는다. 뒤의 결정이 앞의 결정을 대체한 경우
해당 줄에 `→ 대체` 표시를 남긴다.

## 2026-09-13~28 후속 결정

- 2026-09-13: 게임 실행과 화면·전투 판정은 운영자, 구현·자동 검사·검증용 설치·CI/병합은 에이전트가 맡는다.
- 2026-09-14: 보스 추가는 UI 요청부터 패턴·속성·QTE/FX 조립과 공통 실행 구성까지 하나의 공통 파이프라인으로
  처리하고, 시즌·profile 버전별 부팅·음성·종료 예외를 두지 않는다. 속성 제한 패턴에는 속성 실드가 있으며 조건과 FX를
  함께 처리한다. 새 게시는 `common-boss-runtime-admission/v1`(2026-09-15 V0022)을 쓴다.
- 2026-09-15: 정상 실행·종료에서는 FX store 전체를 다시 읽지 않고, 전체 검증은 최초 도입·원본 교체·수리로 분리한다.
- 2026-09-17: 레이드 기록은 계정+시즌+선택 약점으로 이어 쓰고 client build는 revision 출처로만 둔다. 로비 Quit은
  0~4덱이면 참여 기회만, 5덱이면 완주 1회와 참여 기회를 소모한다.
- 2026-09-17: 유니온 레이드 **하드**를 범위에 추가한다(원본 속성·QTE·FX 유지, 노멀 전투 없음).
- 2026-09-17: NLL은 현재 Windows 계정에 두고 공식 게임은 다른 Windows 계정에서 실행한다.
- 2026-09-18: 관리 PostgreSQL은 게임 실행 중에도 켜 둔다(유니온 API의 실행 중 DB transaction).
- 2026-09-18: 캐릭터 TAB 딜표는 `Attack.TotalDamage`, 결과창 총 대미지는 딜표 합 + 파츠 파괴 − 투사체 피해로 확정한다.
- 2026-09-20: 솔로 Challenge 모의전도 기록·BattleLog를 수집하고, 개인딜 기본 표시는 적 투사체 피해를 뺀 값으로 한다.
- 2026-09-28: 승인된 Epinel DLL(같은 hash, 수정·재빌드 없음)의 사용 대상을 152 복제본과 이후 봉인 복제본으로 넓힌다
  ([보안 경계](SECURITY_BOUNDARY.md)).
- 2026-09-28: 보스의 QTE 사용 여부는 조립한 행동 트리의 QTE 노드로 판정한다. QTE 노드가 없으면 대상 몬스터를
  나열한 QTE 행이 있어도 QTE 계약·변환 없이 행동 트리만 조립한다(S26 형태). 속성 실드 패턴은 별개다
  ([보스 파이프라인](features/BOSS_PIPELINE.md)).

## 2026-09-12 안정화 인수 경계

- 운영자는 직접 하는 실 테스트를 제외한 남은 안정화 작업의 완료와 테스트 안내를 요청했다.
- 불변 revision의 준비 상태만 process-local bounded cache로 재사용한다. DB head/가변 summary,
  run admission과 runtime export는 cache로 대체하지 않는다.
- 자식 기한 초과/identity 기록 실패는 자식 또는 PostgreSQL 종료의 증거가 아니다.
  뒤늦은 자식과 rollback이 겹치지 않도록 비종료 상태·identity reservation을 보존한다.
- 새 앱 배포는 검증한 커밋·개별 파일 hash·스키마 18 cold backup/읽기 전용 감사에 결박한다.
  이 배포 경로는 SQL migration·계정 변경·게임/외부 runtime 교체를 하지 않는다.
- S-08/S-09 안정화와 별도 P-01~P-09 기능은 구분한다. 자동 검사나 HTTP smoke를
  원본 UI/HUD/result의 실게임 인수로 승격하지 않는다.

## 확정

- 별도 신규 저장소이며 기존 Git history를 상속하지 않는다.
- 최종 목표는 자체 local backend에 연결된 원본 NIKKE UI와 실제 전투 runtime으로 검증하는 것이다.
- 제품 형태는 원본 client에 필요한 기능만 공급하는 제한된 local private server다. 별도 UI, harness 또는 damage simulator를 최종 client로 만들지 않는다.
- 원본 client는 UI·asset·animation·전투 simulation·damage 계산과 표시의 권위이고, Local Lab은 local session·profile projection·기능 개방·Solo Raid session/result의 권위다.
- lab-owned harness는 개발·계약 검증 도구이며 최종 인수 조건을 대체하지 않는다.
- 실제 계정이 아닌 자체 계정·자체 ID만 사용한다.
- Phase 3 원본 client 연구는 운영자가 승인한 개인·비상업·비배포·로컬 전용 범위다. 권리자 승인은 주장하지 않으며 법적 상태는 `not_determined`로 둔다.
- public EpinelPS commit `28b2f5413a0a1e3521a11ae162f91851335c8b40`은 exact `150.6.9` client에 대한 기술적 prior art/reference로 고정한다. 공개 저장소의 존재를 Shift Up의 승인·묵인·비집행 약속으로 해석하지 않는다.
- EpinelPS는 Local Lab source tree에 vendor하지 않고 별도 checkout/process로 먼저 평가한다. generated protocol source, game data, certificate와 patched binary는 이 저장소에 넣지 않는다.
- Micron `C:\NIKKE`는 공식 launcher 소유의 mutable official-current 설치본이다. 공식 update/fresh capture 외에는 사용하지 않고 Local Lab/EpinelPS가 수정하거나 private-server 실행 대상으로 삼지 않는다. 실험 권위는 별도 version/hash로 봉인한 `C:\NLL\Clients\NIKKE-<build>-*` lane이며 현재 경로 계약은 [MICRON_CURRENT_PATHS.md](MICRON_CURRENT_PATHS.md)를 따른다.
- system hosts/root CA는 disposable VM/OS에서만 바꾸고, client-local certificate bundle/native compatibility shim은 사전 backup, 원본·적용 SHA-256과 검증 가능한 rollback을 갖춘 경우에만 허용한다.
- 캐릭터 빌드는 revision 기반이며 과거 revision은 불변이다.
- 생성 기본 프리셋은 `combat-max/v1`이다.
- 캐릭터 레벨은 사용자 명시값으로 자유 설정한다.
- 장비 기본값은 네 부위 모두 Tier 10, 강화 Level 5다.
- 큐브는 자유 장착·해제하며, 장착 시 기본 Level 15다. 큐브 종류는 추측하지 않는다.
- 스킬은 기본 10/10/10이다.
- 오버로드는 `research` 모드에서 exact 값 자유 write를 지원한다.
- 원본 데이터와 런타임 DB는 저장소 밖에 둔다.
- Solo Raid는 Challenge만 지원한다.
- 목표 콘텐츠는 원본 시즌제/classic `SoloRaid`다. 결과에 영향을 주는 별도 공식 buff가 있는 `SoloRaidMuseum`은 구현·검증·fallback 대상이 아니다.
- 첫 live compatibility target은 시즌 26 프로비던스다. manager→preset→Challenge wave→monster/stat→client asset closure가 닫히지 않으면 `runtime_blocked_season_26`으로 기록하고 다른 시즌이나 Museum으로 자동 대체하지 않는다.
- Phase 3B-0에서 시즌 26 manager→Challenge preset→wave→단일 boss/model/stat→current behavior/asset root closure를 exact하게 닫았다. Focused behavior/timeline artifact는 prior local reference archive에서 생성하고 target pack과의 required-entry/selected-row/skill-row/parts-entry equivalence를 별도로 검증했다. aggregate verdict는 `ready_for_selected_manager_patch_with_timing_analysis_blocker`이며 static/content는 통과, absolute timing 분석만 native scheduler contract 부재로 blocked다. focused artifact는 `promotion_eligible=false`이므로 Phase 1C의 published `static_exact` tier는 유지한다.
- 보스 admission은 `challenge-boss-support/v1`을 따른다. → 대체(2026-09-14): 새 보스는 공통 파이프라인과 `common-boss-runtime-admission/v1`.
- 현재 지원 시즌은 `7, 13, 26, 29, 34, 40`이다. → 대체: Phase 1C 당시 목록. 현재 등록은 [보스 파이프라인](features/BOSS_PIPELINE.md).
- 시즌 14와 39는 전격·철갑 조건을 만족해도 명시적으로 제외한다.
- 일반 1~7단계는 `lastClearLevel=7` 해금 stub이고 `challengeUnlocked=true`가 기본이며 전투 구현 대상이 아니다.
- published 지원 시즌은 종료되지 않는 local content다. `SeasonAvailability=permanent`, `seasonEndsAt=null`이고 만료·정산 job을 만들지 않는다.
- lobby season directory는 여러 지원 시즌을 표시하며, 선택된 한 시즌만 클래식 Solo Raid 실행 context에 투영한다.
- Quick Battle은 지원하지 않으며 endpoint, reward와 persistence를 만들지 않는다.
- Challenge daily state는 IANA `Asia/Seoul`의 매일 05:00에 초기화한다.
- 공식 global ranking, reward mail과 live-service 시즌 정산은 모방하지 않는다. 필요한 경우 자체 local record만 별도 계약으로 표시한다.
- 첫 시즌 26 수직 proof에서는 custom widget 제거·six-season folder를 요구하지 않는다. proof 뒤 presentation을 별도 평가해, 안전한 client variant가 확인되고 사용자가 채택할 때만 기존 홍보·상점·social widget 제거와 좌측 Solo Raid season folder를 구현한다. 하단 니케·스쿼드·로비·인벤토리·대원모집 유지 및 대원모집 controlled no-op도 같은 후속 presentation 결정에 속한다.
- Union Raid는 비활성 확장 지점이다. → 대체(2026-09-17): 유니온 레이드 하드 지원.
- 공식-current `C:\NIKKE`, 공식 계정과 공식 서비스 경로는 modified-local 실행 대상으로 계속 blocked다. 공식 launcher 업데이트와 운영자가 수행하는 fresh capture는 별도 공식 경로이며, modified-local 연구 lane은 [PHASE3AR.md](contracts/PHASE3AR.md)의 `ready_for_local_compatibility_spike` 판정과 [FEASIBILITY_GATES.md](contracts/FEASIBILITY_GATES.md)의 격리 조건을 따른다.
- Phase 3A의 `blocked_insufficient_evidence`는 rights-holder-approved route를 전제로 한 역사적 정상 종료로 보존한다. Phase 3A-R은 이를 성공으로 덮어쓰지 않고 operator-authorized modified-local lane을 별도 재기준화한다.
- Phase 3은 3B-0 시즌 26 closure, 3B-1 classic selected-manager extension, 3B-2 disposable reference run, 3C Local Lab shadow bridge, 3D exact authority correlation의 작은 수직 단계로 진행한다. custom six-season lobby는 첫 classic proof 뒤에 평가한다.
- 3B-1 v1의 선택 권위는 external EpinelPS account다. Listener 시작 전 account-specific startup binding으로 write-once 저장하고 session override는 두지 않으며, account당 하나의 active classic run이 immutable manager pin을 가진다. `Trial` wire는 Challenge이고 Museum·Normal·Practice·FastBattle/Quick은 범위 밖이다. `GetLogs`의 exact target projection/denial은 B1a characterization gate다.
- raid 호환성 tier는 `static_exact`, `behavior_exact`, `asset_exact_runtime_current`, `historical_runtime_exact` 네 단계다.
- published raid snapshot 계약은 v2이며 `ready` 상태와 non-null dataset-scoped compatibility binding marker를 강제한다. raw client mapping은 이 단계에서 materialize하지 않으며 불완전 후보는 import diagnostic으로 분리한다.
- 현재 시즌 목록은 dataset에서 정책으로 파생한 문서화 결과이지 config에 고정된 두 번째 allowlist가 아니다.
- v1 lobby directory는 review된 시즌 `7, 13, 26, 29, 34, 40`으로 versioning한다. 새 dataset candidate는 자동 노출하지 않고 evidence review와 directory contract revision 뒤에 추가한다.
- 공개 구현과 활동 이력은 기술적 feasibility 근거로 사용할 수 있지만 permission의 근거로 사용하지 않는다.
- Phase 1A source 보호는 importer capability 수준의 read-only 보장이다. OS 전체 쓰기 방지로 표현하지 않는다.
- source path, file name, raw ID, decoded payload, exception text는 import ledger schema에 두지 않는다.
- dataset snapshot은 경로가 없는 canonical source manifest hash로 식별하고, 동일 입력은 기존 snapshot을 재사용한다.
- PostgreSQL은 loopback 연결만 허용하며 migration history는 embedded SQL checksum으로 잠근다.
- Windows local 개발·통합 시험의 PostgreSQL 17은 Docker Desktop, WSL2 또는 Hyper-V backend가 아니라 native Windows binary를 on-demand로 실행한다. Windows service 자동 시작은 사용하지 않고 loopback 전용 비표준 port에서 시작하며, 검증 종료와 게임 실행 전에 `postgres.exe`가 0개인지 확인한다(→ 대체(2026-09-18): 관리 cluster는 게임 중에도 유지하며 이 확인은 폐기 가능한 시험 cluster에만 적용). GitHub Actions의 격리 PostgreSQL service는 이 local runtime 결정과 별개로 유지한다. 상세 설치·운영 계약은 [WINDOWS_NATIVE_POSTGRESQL_RUNTIME.md](operations/WINDOWS_NATIVE_POSTGRESQL_RUNTIME.md)를 따른다.
- source alias HMAC fingerprint는 entity UID로 재사용하지 않고 private registry에서 무작위 lab UUID에 연결한다.
- 캐릭터 catalog의 ledger 완료와 snapshot publish는 한 PostgreSQL transaction에서 원자적으로 처리한다.
- 캐릭터 subtype과 sd.bin runtime cap을 함께 사용해 호감도 최대값을 해소한다.
- 현재 설치본만으로 전체 캐릭터 StaticData를 구성할 수 없으므로 보관된 pack과의 혼합 입력은 검증 전용이며 current-authoritative로 게시하지 않는다.
- 전투 보조 장비 catalog는 profile 이관 범위에 맞춰 Tier 9·10의 24개 정의만 게시한다. Tier 0은 미장착 상태이며 Tier 1~8은 unsupported다.
- 콘솔은 9개 좌표마다 source snapshot에서 확인한 연속 Level `1..MaximumLevel` legality와 별도의 level당 flat stat 계수를 저장한다. Level 0은 기여 없는 account state다. 보존된 Aug13 snapshot은 최대 680, 이전 snapshot은 580이므로 상한을 코드에 고정하지 않는다.
- OL은 표준 Tier 10 group의 9종 옵션, 각 15개 이산 값과 확률 band를 보존한다. 같은 장비 내 중복 옵션 정책만 `unresolved`이며 research exact write는 허용한다.
- synchro와 9개 Recycler Room console은 캐릭터 build가 아니라 불변 `AccountCombatStateRevision`이 소유한다.
- 그래픽·FPS와 전투 조작 설정은 `RaidSnapshot`이나 character build에 넣지 않고 별도 execution/control profile revision으로 저장한다.
- target FPS, fixed delta, time scale, multiplayer override와 `MaxPerShotCorrect`가 unresolved인 전투는 golden 비교 대상으로 승격하지 않는다.
- graphics quality, FPS, VSync와 resolution/display mode는 필수 execution profile 입력이다. exact client field가 없는 render scale·shadow는 근거 확보 전 필수화하지 않는다.
- PC의 `UsePcAimSync`, 조준 보조·조건부 강도, 감도와 `MaxPerShotCorrect`는 필수 combat control 입력이며 auto combat·auto burst는 선택 기능이다.
- 요청 설정만 유효한 상태는 launch-ready일 수 있지만 effective read-back과 frame telemetry가 일치해야 golden-ready가 된다.
- 전투 중 필수 설정이 바뀌면 변경 frame을 경계로 새 execution segment와 profile revision을 기록한다.
- 미장착 cube·collection 전체 inventory와 OL lock/reset history는 전투 프로필 범위 밖이다.
- 공식 장비 instance UID는 import하지 않는다. 필요한 경우 Local Lab이 자체 UID를 발급한다.
- 기존 credential-bearing raw profile은 네트워크 없이 호스트에서 읽고 allowlist field만 메모리 정규화한다. crawler와 authenticated replay는 Local Lab에 이식하지 않는다.
- 사용자가 수동 실행하는 `getFromBlaLink.py`는 외부 raw producer로 유지하고 Local Lab은 최신 raw의 offline refresh만 수행한다. 중복 판정에는 credential-bearing raw hash가 아니라 sanitized payload canonical hash를 사용한다.
- 별도 profile editor는 PostgreSQL 직접 편집기가 아니라 loopback API command client로 만든다.
- `Save`와 `Save As`는 합성 local account revision만 수정하며 공식 계정이나 게임 파일에 write하지 않는다.
- profile revision은 character catalog와 combat-support catalog를 각각 `(catalog snapshot UID, dataset snapshot UID, manifest hash)`로 고정한다. 두 catalog가 같은 dataset을 사용한다고 가정하지 않는다.
- `combat-max/v1` profile 해소기는 Phase 1B character facts와 Phase 1D의 Tier 9·10 definition grid를 명시적으로 결합한다. Phase 1B의 unresolved equipment placeholder를 전투 장비로 재사용하지 않는다.
- `combat-max/v1`의 core는 적용 가능한 snapshot 최대값으로 해소하고, 기업 일치 여부는 사용자가 선택하거나 근거가 있을 때까지 `unresolved`로 둔다.
- collection/favorite 기본 선택은 적용 가능한 전용 favorite가 정확히 하나면 그 최대값을, 아니면 무기와 일치하는 최고 rarity generic collection의 최대값을 사용한다. 둘을 동시에 적용하지 않는다.
- OL line은 장비별 고정 좌표 `1..3`의 sparse subset이다. 중간 빈 line을 보존하며 삭제 시 뒤 line을 당기지 않는다.
- console EXP는 nullable 숫자가 아니라 `ready|unresolved|not_applicable` fact로 저장한다. level이 있어도 EXP가 유실되면 full-fidelity readiness만 미완료다.
- roster level과 detail level은 별도 observation이다. 의미가 확정되기 전에는 하나의 character level로 자동 병합하지 않는다.
- Phase 3B-2의 `4/7` resource closure는 독자적인 catalogue projection을 더 만들지 않고 Epinel의 NKDB decrypt와 Addressables host-token 해석을 권위로 사용한다. Samsung cold environment에서 catalog가 exact remote path로 지시한 bundle만 Git-external native cache로 materialize하고, provider metadata와 `RuntimePath` row는 원격 수집 대상에서 제외한다. 전체 cache가 봉인되기 전에는 Micron retry를 소비하지 않는다.

## 남은 미정사항

- 기업 일치 장비를 기본으로 적용할지
- Tier 10과 오버로드 장비 상태의 정확한 관계
- 소장품·애장품의 단계/레벨 표현과 스킬 변형 모델
- client graphics/control setting의 authoritative local capture 위치와 적용 경로
- 각 지원 시즌의 runtime exact 증거 확보 범위
- pinned EpinelPS의 per-request handler factory와 account-keyed serialization을 기존 JsonDb/dispatch에 가장 작게 넣을 exact 구현 shape
- 시즌 26 client `150.6.9` native scheduler contract와 미해소 event timing `7`개의 absolute frame/ms mapping
- disposable environment에서 시즌 26 classic runtime이 실제 battle/result를 반환하는지 여부. 운영자는 지정 실험 OS인 Micron에서
  151/S26 실게임 결과를 확인했다(2026-09-06). Phase 3B-2의 disposable reference run 판정은 계약상 not executed로 남는다.
- custom client UI variant가 고정 lobby widget 제거, season folder와 영구 시즌 표시를 지원할 수 있는지
- 권리자 또는 법률 전문가의 별도 검토가 필요한지 여부. 이는 현재 local technical spike의 선행 기술 gate가 아니며 배포·제3자 접속·상업화 시 반드시 다시 결정
- Challenge 일일 entry 수, 소비 시점과 `per_season`/`shared_directory` counter 범위
- 05:00을 가로지르는 active run 처리
- Mock Battle과 local record/ranking 표시 범위. 모의전 기록 수집·표시는 2026-09-20에 결정했고, 솔로 local ranking 범위는 미정이다.

미정값은 임의 기본값으로 채우지 않고 contract에서 `unresolved`로 표현합니다.
