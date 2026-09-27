# Scope

## 목적

원본 NIKKE 클라이언트에 필요한 기능만 공급하는 자체 ID 기반 local private server를 만들고, 캐릭터 빌드와 지원 레이드의
데이터·asset·runtime 근거를 고정하여 **운영자가 승인한 비배포·로컬 전용 환경의 원본 UI와 실제 전투 runtime**으로
실행·검증합니다.

원본 client는 UI, asset, animation, 전투 simulation, damage 계산과 HUD의 권위입니다. Local Lab은 local session,
profile projection, 기능 개방, 레이드 session과 결과 저장의 권위입니다. lab-owned harness와 `Nikke-Dmg-Simulator`는
계약 검사·데이터 해석·대조용 sidecar이며 최종 게임 client를 대체하지 않습니다.

로비와 Solo Raid의 제품 계약은 [PRIVATE_SERVER_UI.md](contracts/PRIVATE_SERVER_UI.md)가 권위입니다.

pinned public EpinelPS 구현을 prior art/reference로 사용하는 modified-local compatibility 연구입니다. 공개 저장소의 존재는
원본 client와 local server 사이의 기술적 실행 가능성 증거이지 Shift Up의 허가 또는 묵인을 뜻하지 않습니다. 권리자 승인은
주장하지 않으며 법적 상태는 이 프로젝트에서 확정하지 않습니다. 운영 범위를 비배포·개인 로컬 실험으로 제한하고, 범위가
바뀌면 다시 검토합니다.

## 현재 제품 범위

| 영역 | 포함 | 근거·현행 문서 |
|---|---|---|
| 솔로 레이드 | original/classic Solo Raid **Challenge** 실전과 모의전. 보스별 5약점 선택 | [보스 파이프라인](features/BOSS_PIPELINE.md), [RAID_DOMAIN](contracts/RAID_DOMAIN.md) |
| 유니온 레이드 | **하드** 실전·연습전, NLL 유니온 소속·노멀 완료 상태. 원본 속성·QTE·FX 유지 | 2026-09-17 운영자 요청, [유니온 레이드](features/UNION_RAID.md) |
| 계정·니케 | 계정 생성·편집·Save/Save As, 사용자 직접 로그인 기반 가져오기, 캐릭터 목록 동기화 | [계정 관리](features/ACCOUNTS.md) |
| 기록·분석 | 솔로 실전/모의전·유니온 하드 결과의 딜표와 BattleLog 분석 | 2026-09-20 운영자 요청, [레이드 기록](features/RAID_RECORDS.md) |
| 실행 | 봉인된 로컬 client 복제본 + 로컬 Epinel 서버의 시작·종료·복구·영속화 | [실행 수명주기](features/EXECUTION_LIFECYCLE.md) |

## 범위 밖

- 결과에 별도 공식 buff가 적용되는 Solo Raid Museum(구현·검증·fallback 모두 제외)
- 일반 솔로 레이드 1~7단계 전투, 유니온 레이드 노멀 전투·노멀 연습전, Quick Battle
- 공식 로그인·계정·session·token 사용, live 공식 traffic 가로채기/replay, 게임 프로세스 주입·후킹·memory patch
  (승인된 Epinel DLL의 내장 동작은 [보안 경계](SECURITY_BOUNDARY.md)의 2026-09-06 예외)
- 사격장 전투, 유니온 채팅 전송·운영 기능, 스테이지·타워·아레나·상점·전초기지·보상 경제
- 기존 대미지 시뮬레이터를 최종 전투 runtime으로 쓰는 것

## 캐릭터 빌드 기본값

| 항목 | `combat-max/v1` 기본값 | 저장 원칙 |
|---|---|---|
| 캐릭터 레벨 | 사용자 명시 입력 필수 | snapshot이 허용하는 범위 안에서 자유 설정하고 revision에 실제 정수를 저장 |
| 돌파 | 해당 snapshot에서 지원하는 최대치 | 일반 돌파와 코어 레벨을 별도 값으로 materialize |
| 호감도 | 해당 캐릭터의 최대치 | 캐릭터별 최대치를 해소하여 저장 |
| 장비 | 전 부위 Tier 10, 강화 Level 5 | 4개 부위와 실제 해소값을 저장; 기업 일치는 별도 상태 |
| 큐브 | 최초 미장착, 장착 시 Level 15 | 종류를 임의 선택하지 않으며 장착/해제를 명시적 상태로 저장 |
| 스킬 | Skill 1/Skill 2/Burst 모두 Level 10 | 세 축을 독립 값으로 저장 |
| 오버로드 | 자유 write | 줄 추가·교체·삭제, 순서, exact 값을 손실 없이 보존 |
| 소장품 | 적용 가능한 최대치 | 미지원과 결손 데이터를 0으로 표현하지 않음 |
| 애장품 | 적용 가능한 최대치 | 미지원 캐릭터는 `not_applicable` |

기본값은 빌드 생성 시 한 번 적용합니다. 이후 게임 데이터가 갱신되어도 기존 revision을 자동 변경하지 않습니다.
니케 도감의 `모두 보유로 설정`은 운영자가 따로 지정한 기본 육성(레벨·스킬 1, 돌파·코어 0)을 쓰는 별도 기능입니다.

## Challenge 규칙

- 목표 화면과 규칙은 original/classic `SoloRaid` Challenge입니다.
- 일반 1~7단계는 `implemented=false`, `lastClearLevel=7`인 UI 해금 stub이며 `challengeUnlocked=true`가 기본입니다.
  일반 단계의 전투 진입, 보상, 결과 저장 API는 만들지 않습니다.
- 지원 시즌은 만료되지 않는 local content이며 season end timestamp를 만들지 않습니다. lobby directory에는 여러 시즌을
  나열하지만 원본 클래식 Solo Raid 화면에는 사용자가 선택한 한 시즌만 투영합니다.
- Quick Battle은 구현하지 않고 원본 button은 숨김 또는 controlled disabled/no-op으로 처리합니다.
- daily Challenge state는 `Asia/Seoul`의 매일 05:00에 초기화합니다.
- Challenge unlock UI state와 run admission을 구분합니다. checked-in 기본 `challenge-operational-policy/unresolved/v1`에서는
  Challenge가 open이지만 새 run은 fail closed하며, configured policy는 여섯 운영 축을 모두 명시한 새 versioned ID를 사용합니다.
- **보스 admission**: Phase 1C snapshot의 여섯 시즌 `[7, 13, 26, 29, 34, 40]`은 `challenge-boss-support/v1`
  (`season == 40 OR (전격 AND 철갑 약점 AND season NOT IN [14, 39])`)로 게시했습니다. 2026-09-14 운영자의 공통
  파이프라인 요구 이후 새 보스는 공통 조립·검증을 통과해 `common-boss-runtime-admission/v1`로 등록합니다. 기존 여섯 시즌의
  역사 snapshot은 바꾸지 않습니다. 현재 등록 목록은 [보스 파이프라인](features/BOSS_PIPELINE.md)을 따릅니다.
- 결손이면 Museum이나 다른 시즌으로 자동 대체하지 않고 controlled blocked 결과를 기록합니다.

## 역사적 범위

아래는 Phase 0 당시의 범위이며 현재 제품 범위를 제한하지 않습니다. 이후 Phase 2에서 local private server를 구현했고,
Phase 3A는 rights-holder-approved route를 전제로 감사해 `blocked_insufficient_evidence`로 종료했으며 그 결과는 변경하지
않습니다. [PHASE3AR.md](contracts/PHASE3AR.md)는 사용자 결정과 공개 EpinelPS prior art를 근거로 operator-authorized
modified-local lane을 재기준화했습니다. 첫 live compatibility test는 시즌 26이었고 2026-09-06 운영자가 151/S26 실게임 검증
완료를 보고했습니다.

Phase 0 확정 범위:

- 별도 Git 저장소와 데이터 보존 경계를 만든다.
- `CharacterDefinition`, `CharacterBuild`, `CharacterBuildRevision`의 책임을 정의한다.
- 생성 기본 프리셋 `combat-max/v1`을 정의한다.
- 자체 ID와 원본 ID 격리 원칙을 정의한다.
- Challenge 전용 `RaidSnapshot`과 네 단계 호환성 등급을 정의한다.
- `challenge-boss-support/v1` admission policy를 정의한다.
- 일반 솔로 레이드 1~7단계는 전투가 아닌 Challenge 해금 상태 stub으로만 정의한다.
- 주 설치본을 보존하고 snapshot 가능한 disposable VM/별도 OS에서만 modified-local compatibility live proof를 실행하는
  fail-closed 게이트를 정의한다. 단순 client 복제본은 정적 검산용이다.
- 계약용 JSON Schema와 직접 만든 합성 fixture를 둔다.
- 저장소 정책 검사를 자동화한다.

Phase 0에서 하지 않았던 것: 서버/API/DB 구현, 원본 리테일 클라이언트 연결 또는 실행, endpoint/auth 흐름 변조, 공식
계정·로그인·토큰 사용, 안티치트·launcher·보호 기능의 우회, 일반 솔로 레이드 1~7단계 전투, Union Raid·스테이지·타워·
아레나·상점·전초기지 구현, 실제 게임 데이터 import 또는 원본 자산 복사, 기존 대미지 시뮬레이터를 최종 전투 runtime으로 사용.
Micron은 이 lane의 별도 실험 OS입니다([경로 권위](MICRON_CURRENT_PATHS.md)).
