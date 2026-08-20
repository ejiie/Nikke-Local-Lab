# Scope

## 목적

원본 NIKKE 클라이언트에 필요한 기능만 공급하는 자체 ID 기반 local private server를 만들고, 캐릭터 빌드와 지원 Solo Raid Challenge의 데이터·asset·runtime 근거를 고정하여 **원본 UI와 실제 전투 runtime**으로 실행·검증합니다.

원본 client는 UI, asset, animation, 전투 simulation, damage 계산과 HUD의 권위입니다. Local Lab은 local session, profile projection, 기능 개방, Solo Raid session과 결과 저장의 권위입니다. lab-owned harness와 `Nikke-Dmg-Simulator`는 계약 검사·데이터 해석·최적화·대조용 sidecar이며 최종 게임 client를 대체하지 않습니다.

로비와 Solo Raid의 제품 계약은 [PRIVATE_SERVER_UI.md](PRIVATE_SERVER_UI.md)가 단일 권위입니다.

## Phase 0 확정 범위

- 별도 Git 저장소와 데이터 보존 경계를 만든다.
- `CharacterDefinition`, `CharacterBuild`, `CharacterBuildRevision`의 책임을 정의한다.
- 생성 기본 프리셋 `combat-max/v1`을 정의한다.
- 자체 ID와 원본 ID 격리 원칙을 정의한다.
- Challenge 전용 `RaidSnapshot`과 네 단계 호환성 등급을 정의한다.
- `challenge-boss-support/v1` admission policy를 정의한다.
- 일반 솔로 레이드 1~7단계는 전투가 아닌 Challenge 해금 상태 stub으로만 정의한다.
- 원본 리테일 클라이언트 연결의 fail-closed 실행 게이트를 정의한다.
- 계약용 JSON Schema와 직접 만든 합성 fixture를 둔다.
- 저장소 정책 검사를 자동화한다.

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

## Challenge 범위

- 지원 모드는 `challenge` 하나뿐입니다.
- 지원 판정은 `season == 40 OR (bossElement == electric AND weaknessCode == iron AND season NOT IN [14, 39])`입니다.
- 현재 authoritative snapshot의 파생 allowlist는 `[7, 13, 26, 29, 34, 40]`입니다.
- 일반 1~7단계는 `implemented=false`, `lastClearLevel=7`인 UI 해금 stub이며 `challengeUnlocked=true`가 기본입니다.
- 일반 단계의 전투 진입, 보상, 결과 저장 API는 만들지 않습니다.
- 모든 published 지원 시즌은 종료되지 않는 local content이며 season end timestamp를 만들지 않습니다.
- lobby directory에는 여러 지원 시즌을 나열하지만 원본 클래식 Solo Raid 화면에는 사용자가 선택한 한 시즌만 투영합니다.
- Quick Battle은 구현하지 않고 원본 button은 숨김 또는 controlled disabled/no-op으로 처리합니다.
- daily Challenge state는 `Asia/Seoul`의 매일 05:00에 초기화합니다.
- Union Raid는 향후 확장 지점만 예약하고 현재 비활성화합니다.

## Phase 0에서 하지 않았던 것

- 서버/API/DB 구현
- 원본 리테일 클라이언트 연결 또는 실행
- endpoint/auth 흐름 변조, 공식 계정·로그인·토큰 사용
- 안티치트, launcher, 보호 기능의 우회
- 일반 솔로 레이드 1~7단계 전투
- Union Raid, 스테이지, 타워, 아레나, 상점, 전초기지 구현
- 실제 게임 데이터 import 또는 원본 자산 복사
- 기존 대미지 시뮬레이터를 최종 전투 runtime으로 사용

Phase 0의 "하지 않는 것"은 해당 단계의 범위입니다. 이후 Phase 2에서는 local private server를 구현합니다. Phase 3A는 client 연결 없이 승인 증거를 먼저 감사하고, `ready_for_phase3b` 뒤에만 승인 범위의 transport 평가를 시작합니다. lobby UI variant 연결은 별도 3D presentation gate를 통과해야 합니다.
