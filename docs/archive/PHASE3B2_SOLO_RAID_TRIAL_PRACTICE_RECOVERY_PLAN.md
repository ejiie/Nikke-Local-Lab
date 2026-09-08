# Phase 3B-2 Solo Raid Trial/Practice 복구 계획

> 보관 기록: 2026-09-06 문서 정리 때 이동했습니다. 본문의 ‘현재·다음·미완료’는 작성 당시 기준입니다. 현행 안내는 [문서 색인](../README.md)과 [현재 경로](../MICRON_CURRENT_PATHS.md)를 따릅니다.

## 1. 목적

Lobby 및 Solo Raid 메뉴 진입이 검증된 Micron Golden 계보를 보존하면서 다음을
달성한다.

- 시즌 26 classic Solo Raid Challenge(`Trial`) 실제 전투 진입
- Normal I~VII clear 상태 유지
- Mock Battle(`Practice`) 실제 전투 진입
- Practice가 Challenge의 일일 시도 상태를 소비하거나 변경하지 않음
- 지원 시즌이 만료되지 않는 일관된 period 응답
- 성공 응답의 client 필수 nested message가 항상 wire-safe한 형태를 가짐

Museum, Normal Solo Raid 전투, Quick Battle은 이 계획의 대상이 아니다.

## 2. 현재 판정

현 병목은 지휘관 레벨이나 `LastClearLevel`이 아니다. assessment
`6e859a33-e6c2-4d68-bf1e-15931ec282c1`에서 지휘관 레벨 893 투영 뒤 client가
다음 route를 실제로 호출했다.

- `ResGetSoloRaidInfo`: Success
- `ResOpenSoloRaidTrial`: Success
- `ResGetLevelTrialSoloRaid`: Success

그러나 직후 client는 `NKUserSoloRaid.UpdateJoinData(joinData)`에서
`NullReferenceException`을 발생시켰고, 재진입 시
`NKUserSoloRaid.UpdatePeriod(netSoloRaidPeriodData)`에서도 같은 종류의 예외를
발생시켰다.

현행 `GetLevelTrialInfo`는 open level이 없어도 먼저 `PeriodResult=Success`를
설정한 뒤 `Raid`와 `JoinData`를 비운 채 반환할 수 있다. focused test도
`GetLevelTrialWithoutOpenRunIsWireSuccessWithoutMutation`이라는 이름으로 이
형태를 정상으로 고정하고 있다.

원본 Epinel 구현도 이 경합을 계약 수준에서 해결하지 않는다. Epinel은
`OpenSoloRaid`가 현재 raid를 직접 변경하고 `JsonDb.Save`한 뒤 `GetLevel`이 그
상태를 읽는 순서를 기대한다. 요청 순서가 뒤집히거나 겹칠 때의
`Success + null nested message`를 방지하는 장치는 없다. 따라서 Epinel의 상태
의미는 유지하되 순서 의존성과 wire-shape 결손을 별도 보강해야 한다.

## 3. 불변 경계

- D 드라이브 Golden은 읽기 전용 비교·복구 기준이다.
- Micron의 Golden DB, cache, server binary, start/completion 도구는 직접
  수정하지 않는다.
- 새 구현은 Micron의 검증된 active 계보에서 파생한 별도 lane에 둔다.
- receipt나 자체 SHA를 runtime wrapper의 선행조건으로 결박하지 않는다.
- 감사 manifest와 receipt는 runtime이 참조하지 않는 detached evidence로만
  남긴다.
- `nlloperator` 전용 LocalLow 격리와 기존 `ccccc` cache 불변을 유지한다.
- 지휘관 레벨 893과 Normal I~VII clear 투영은 이번 변경 변수에서 제외한다.
- 공식 로그인, 계정, session, token, 공식 API fallback을 사용하지 않는다.

## 4. 단계별 계획

### 1단계 — 기준선 동결 (`완료`)

다음 근거로 기존 기준선은 이미 확보됐다.

- Lobby Golden seal UID:
  `15089f3e-92f2-4833-ab1b-348d1463f9fc`
- Lobby Golden receipt SHA-256:
  `ebf5c2f7692e7de7ec9b8bcf3acba112cdb8efbfbb888967acde7e429e877f9c`
- Golden restore finalization receipt SHA-256:
  `6d4c9fadd0c500cca3a95f3c2eeae7a141eacacc073167874c1eff2989d4a4e3`
- Golden DB SHA-256:
  `c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194`
- D Golden은 runtime에 연결되지 않은 read-only 복구 기준으로 보존됨
- 최신 지휘관 레벨 단일 변수 run은 completion 후 runtime cold 복원을 완료함

이 완료 판정은 기존 Golden 기준선에 관한 것이다. 앞으로 수정할 파생 후보를
D에 백업하는 작업은 8단계 acceptance 이후에만 수행한다.

### 2단계 — 요청 순서와 wire shape 오프라인 재현 (`완료`)

다음 호출 순서를 모두 재현한다.

1. `OpenTrial -> GetLevelTrial`
2. `GetLevelTrial -> OpenTrial`
3. 두 요청 동시 실행
4. `OpenTrial` 중복 실행
5. 화면 재진입 후 `GetInfo`
6. 같은 순서를 Practice route에 적용

각 응답은 실제 protobuf serialize/deserialize 왕복 뒤 검사한다. 최소 필수
검사 대상은 다음과 같다.

- `GetInfo.Info`
- `GetInfo.Info.Period`
- `GetLevelTrial.Raid`
- `GetLevelTrial.JoinData`
- Practice의 대응 `Raid`와 `JoinData`

`PeriodResult=Success`인 응답에 client 필수 nested message가 null인 경우는 모두
실패로 판정한다.

#### 2단계 실행 결과

production code를 변경하지 않고
`TrialPracticeWireOrderCharacterizationTests.cs`에 characterization 10개를
추가했다.

- 변경 전 focused suite: 67/67 pass
- 변경 후 focused suite: 77/77 pass, warning 0
- 새 characterization suite 10회 반복: 실패 0

확정된 현행 동작은 다음과 같다.

1. open state가 없는 상태에서 Trial `GetLevel`을 먼저 호출하면
   `PeriodResult=Success`, `Raid=null`, `JoinData=null`이다.
2. 이 null shape는 protobuf serialize/deserialize 뒤에도 그대로 유지된다.
3. open state를 먼저 materialize한 뒤 Trial `GetLevel`을 호출하면 `Raid`와
   `JoinData`가 모두 non-null이다.
4. persistence coordinator는 각 요청의 원자성은 보장하지만 Open/Get 두 요청을
   하나의 순서 있는 bundle로 만들지 않는다.
5. exact active Trial에 대한 `OpenTrial` replay는 현행 policy에서
   `active_run_already_exists`로 거부된다. 즉 멱등 replay가 아니다.
6. `GetInfo` failure 응답은 wire round-trip 뒤 `Info`는 non-null이지만
   `Info.Period=null`이다.
7. Practice helper도 open state가 없을 때 `Success + null Raid/JoinData`를 만들 수
   있다.
8. 현행 Practice handler 네 개는 user state, helper, selected-manager executor에
   접근하지 않고 즉시 `PeriodResult=Failure`를 반환한다.

따라서 실제 client 예외와 오프라인 재현이 일치한다. 3단계의 최소 수정 대상은
Trial Open/Get의 bundle-order 독립성, exact replay 멱등성, success wire shape다.
Practice 활성화는 이 결손을 공통 primitive에서 해결한 뒤 4단계에서 별도로
진행한다.

### 3단계 — Challenge 상태 전이의 원자성·멱등성 보강 (`완료`)

`OpenTrial`과 `GetLevelTrial`이 공유하는 exact selected-manager/level 8 상태 전이
경로를 만든다.

- 활성 Trial이 없으면 정확히 한 번만 생성한다.
- 동일 Trial이 이미 있으면 같은 상태를 성공으로 재사용한다.
- 같은 요청의 replay로 count를 중복 반영하지 않는다.
- 다른 manager, 다른 level, 복수 또는 malformed active run은 무변경 실패한다.
- 호출 순서와 관계없이 `Success + null Raid/JoinData`는 내보내지 않는다.

Challenge count의 기존 의미를 이 단계에서 임의로 재정의하지 않는다. 다만
exact replay가 count를 중복 변경하지 않는 것과 Practice가 count를 변경하지
않는 것은 강제한다.

#### 3단계 실행 결과

Golden·Micron runtime을 건드리지 않고 Git-external Epinel source의 Challenge
경로에만 공통 `EnsureTrialOpen` 상태 전이를 추가했다.

- `OpenTrial`과 `GetLevelTrial`은 같은 persistence coordinator 경계에서 exact
  selected manager/level 8 Trial을 확인·생성한다.
- 활성 Trial이 없으면 한 번만 materialize하고, exact active Trial이 있으면
  새 count나 DB write 없이 성공 상태를 재사용한다.
- `GetLevelTrial` 선호출도 완전한 `Raid`와 `JoinData`를 가진 응답을 반환한다.
- open state가 없는 helper 단독 호출은 더 이상 `Success + null`을 만들지 않고
  명시적 `Failure`를 반환한다.
- 다른 manager/level, 복수 active run, Practice 등 malformed active state는
  materializer 호출과 상태 변경 없이 실패한다.
- 일자 rollover는 exact active Trial을 파괴하지 않으며, 새 Trial 생성이 필요한
  경우에만 기존 reset 의미를 적용한다.

검증 결과는 다음과 같다.

- selected-manager focused suite: 81/81 pass
- Trial/Practice 순서·wire characterization: 14/14 pass를 10회 반복, 실패 0
- 첫 `Get` 뒤 반복 `Get`과 exact `Open` replay의 DB digest 불변 확인
- 동시 `Open`/`Get`에서 materialization 1회 및 저장 후 active Trial 1개 확인
- protobuf 왕복 뒤 Trial 성공 응답의 `Raid`·`JoinData` non-null 확인
- repository/Phase 2A1·2A2·2B/Phase 3A·3B-0·3B-1·3B-2 연쇄 gate 통과
- external 및 계획 문서 `git diff --check` 통과

이 단계에서는 Practice handler, 비만료 period provider, Micron DB/cache/tool,
D Golden 및 배포 artifact를 변경하지 않았다. 따라서 다음 작업은 독립된
4단계 Practice capability 복원이다.

### 4단계 — Practice를 독립 capability로 복원 (`완료`)

현행 selected-manager lane의 Practice handler는 controlled failure만 반환한다.
새 파생 policy에서 Epinel의 Practice 상태 의미를 복원하고 다음 경계를 둔다.

- `OpenPractice`, `GetLevelPractice`, `SetDamagePractice`, `ClosePractice` 지원
- `SoloRaidType.Practice`만 사용
- Challenge active run, Trial count, Challenge damage/result/reward 변경 금지
- Practice open/get 순서도 원자적·멱등적으로 처리
- Normal 전투 5개 route와 Fast Battle은 계속 unsupported
- `GetPeriod`와 `GetRanking`은 manager-independent 유지

새 policy의 목표 route 분류는 다음과 같다.

- selected Challenge/Practice: 11
- unsupported Normal/Fast Battle: 6
- manager-independent: 2

역사적 Phase 3B-1의 기존 route fixture나 receipt를 소급 수정하지 않고 새
versioned policy로 기록한다.

#### 4단계 실행 결과

Git-external Epinel source에서 Practice를 exact selected-manager capability로
복원했다. 기존 Golden과 Micron runtime에는 적용하지 않았다.

- `OpenPractice`, `GetLevelPractice`, `SetDamagePractice`, `ClosePractice`가 모두
  persistence coordinator와 selected-manager policy를 통과한다.
- Practice `Open`과 `GetLevel`은 어느 쪽이 먼저 와도 Practice session을 정확히
  한 번만 생성하며, replay는 DB를 다시 쓰지 않는다.
- Trial과 Practice는 같은 manager/level 8에서 type별 한 개씩 병존할 수 있다.
  resolver는 각 route가 요구하는 type의 active run만 선택한다.
- Normal, 다른 manager/level, 같은 type의 복수 active run 및 malformed run은
  무변경 실패한다.
- Practice materialization이 중간 실패하면 coordinator가 working snapshot을
  버려 partial state를 영속하지 않는다.
- Practice damage와 close 전후에 Trial count, Normal open count, Trial
  damage/log/status의 fingerprint가 동일해야만 commit한다.
- 공용 `GetLogs`는 기존 Trial `Logs`를 유지하면서 Practice 결과만
  `PracticeLogs`에 별도로 투영한다.
- 성공한 Practice `GetLevel`과 `SetDamage` 응답은 protobuf 왕복 뒤에도 필수
  `Raid`/`Info`와 `JoinData`를 non-null로 유지한다.

route 분류는 계획한 현재형으로 고정됐다.

- selected Challenge: 6
- selected Practice: 4
- selected `GetLogs` projection: 1
- unsupported Normal/Fast Battle: 6
- manager-independent: 2

검증 결과는 다음과 같다.

- selected-manager focused suite: 89/89 pass
- 전체 89개 test를 10회 반복, 실패 0
- Trial→Practice와 Practice→Trial 양방향 생성 순서, 동시 Practice Open/Get,
  replay, DB reload, damage/log/close 격리 확인
- repository/Phase 2A1·2A2·2B/Phase 3A·3B-0·3B-1·3B-2 연쇄 gate 통과
- external 및 계획 문서 `git diff --check` 통과

이 단계에서는 period 계산, Golden/Micron DB·cache·tool, D 백업 및 배포
artifact를 변경하지 않았다. 다음 작업은 5단계의 비만료 period provider
통일이다.

### 5단계 — 비만료 period provider 통일 (`완료`)

고정된 최대 timestamp 대신 `Asia/Seoul` 05:00 raid-day를 기준으로 rolling
period를 계산한다.

- 시즌 26은 논리적으로 만료되지 않는다.
- `GetPeriod`, `GetInfo.Info.Period` 및 Trial/Practice 판정은 같은 provider를
  사용한다.
- 날짜 비교와 protobuf tick 범위에서 overflow가 없어야 한다.
- 재진입 응답에서도 `Info.Period`는 항상 non-null이어야 한다.

#### 5단계 실행 결과

Git-external Epinel source에 classic Solo Raid 전용
`ClassicSoloRaidPeriodProvider`를 추가했다. 고정 최대 timestamp를 사용하지 않고,
서울 05:00부터 다음 날 05:00 직전까지 동일한 raid day로 계산한다.

- 각 raid day의 `EndDate`는 그날 서울 05:00 기준 정확히 5일 뒤다.
- 다음 서울 05:00에 전체 period window가 정확히 하루 앞으로 이동하므로 시즌 26은
  논리적으로 만료되지 않는다. 화면의 남은 시간은 하루 동안 5일에서 4일 방향으로
  감소하다가 다음 05:00에 다시 5일로 올라간다.
- `GetPeriod`, `GetInfo.Info.Period`, 신규 Solo Raid state의 `LastDateDay` 및
  Trial 일일 count reset이 같은 provider를 사용한다.
- 기존 전역 `User.GetDateDay()`와 다른 이벤트의 reset 동작은 변경하지 않았다.
- `GetInfo`의 controlled-failure wire에도 non-null `Info.Period`를 넣어 재진입
  null dereference 경로를 닫았다.
- 지원 tick 범위의 양끝에서 period 산술이 overflow 없이 동작하고, 산술 여유가
  없는 비현실적 극값은 계산 전에 controlled exception으로 fail closed한다.

검증 결과는 다음과 같다.

- selected-manager focused suite: 96/96 pass
- 전체 96개 test를 10회 반복, 실패 0
- 서울 04:59:59/05:00:00 경계, 호출자 UTC offset 독립성, 5일 rolling horizon,
  일일 count reset, protobuf period round-trip 및 tick 범위 경계 확인
- repository/Phase 1B·1C·1D/Phase 2A1·2A2·2B/Phase 3A·3B-0·3B-1·3B-2
  연쇄 gate 통과
- Phase 0, tracked repository policy 및 Actions contract 통과
- working-tree repository policy는 이번 변경과 무관한 기존
  `tools/Phase3B2/ContentVersionContractInspector/.tmp-dotnet-cli-home` telemetry
  파일 때문에 실패했으며 해당 사용자 파일은 삭제하지 않았다.

이 단계에서는 Golden/Micron DB·cache·tool, D 백업 및 배포 artifact를 변경하지
않았다. 다음 작업은 6단계 오프라인 검증·변경 범위 감사다.

### 6단계 — 오프라인 검증과 변경 범위 감사 (`완료`)

Micron 배포 전에 다음을 모두 통과한다.

- 기존 selected-manager focused test 전부
- 순차, 역순, 동시, 중복 요청 test
- protobuf wire round-trip test
- 활성 Trial/Practice 세션이 type별 최대 1개인지 검사
- Challenge replay의 count 중복 변경 0
- Practice 전후 Trial count 변경 0
- 저장 후 DB reload에서 동일 상태 보존
- 잘못된 manager/level 요청의 DB 변경 0
- Golden과 비교해 허용 파일 외 drift 0
- official outbound, Museum, latest-manager fallback 호출 0

현행의 `GetLevelTrialWithoutOpenRunIsWireSuccessWithoutMutation` test는 제거하거나
`Success`일 때 non-null 완전 응답을 요구하는 test로 교체한다.

#### 6단계 실행 결과

Micron에 쓰지 않고 Samsung에서 source·test·Golden evidence를 읽기 전용으로
감사했다. Golden artifact manifest SHA-256
`25a3a7696c486098bedf5184c31d80380543c3ab4809467e71b0a4594c332be7`
및 Epinel source bundle SHA-256
`d3206ec8c2070f06943b0f4d2959ae18d45d689efd959b16eb576721572f519e`가
1단계 seal과 일치했고, `git bundle verify`가 통과했다. Bundle HEAD는
`aa01ad90b807be1c2ceffe958519cb529622d472`다.

Golden bundle HEAD부터 현 작업 상태까지의 전체 source drift를 exact allowlist와
비교했다.

- 전체 변경 파일: 17개
- 운영 source: 9개
- test source: 8개
- allowlist 밖 drift: 0개
- 누락된 expected drift: 0개
- 삭제: 0개
- binary diff: 0개
- canonical source manifest SHA-256:
  `1c58deb41bef14e2d8c64699198e291898238319155c3cbd1b05f9d4f2fd54e5`

이 17개에는 Golden 이후 이미 완료한 Normal I~VII 표시 호환성 source/test가
포함된다. 현 3~5단계의 작업 기준 HEAD는
`317c4f352b91e76470e2b035ada426ff443f9de4`이며, 여기서 추가된 drift는 정확히
17개다. Normal `Open/GetLevel/Enter/SetDamage/Close`, Fast Battle handler는
변경되지 않았다.

Focused suite 96개를 책임별로 분리해 다시 실행했고 모두 통과했다.

- Trial/Practice 순서·동시성·중복·wire·격리: 21/21
- selection 저장·reload·quarantine: 18/18
- 잘못된 manager/level·latest decoy·rollover: 14/14
- 서울 05:00 rolling period·tick·wire: 7/7
- route policy와 unsupported 경계: 17/17
- 기존 wire shape: 7/7
- local-only/outbound 차단: 7/7
- Normal I~VII 표시 projection: 2/2
- 전체 handler 분류 감사: 3/3

따라서 다음 항목을 모두 확인했다.

- Trial과 Practice active run은 type별 최대 1개다.
- Challenge replay는 materialization/count를 중복 반영하지 않는다.
- Practice open/get/damage/close 전후 Challenge state와 Trial count가 같다.
- persistence coordinator 저장 후 reload에서도 exact run pin이 유지된다.
- 잘못된 manager/level, malformed 또는 duplicate run은 DB 변경 없이 거부된다.
- 성공 wire의 필수 nested message와 재진입 `Info.Period`가 non-null이다.
- 변경 운영 source와 전체 classic Solo Raid production에서 Museum 참조는 0이다.
- 변경 운영 source의 outbound API 참조는 0이다.
- resolver/executor의 latest-manager fallback pattern은 0이다.

Focused 96/96 suite의 10회 반복 결과도 5단계 이후 source가 바뀌지 않은 상태로
계속 유효하다. Phase 0, Phase 1B~3B-2 연쇄 gate, tracked repository policy,
Actions contract와 양쪽 `git diff --check`도 통과했다. Working-tree repository
policy의 기존 telemetry 예외는 5단계 기록과 동일하다.

이 감사에서 Micron runtime, Golden DB/cache/server/tool, hosts/firewall 또는 D
백업은 수정하지 않았다. 7단계도 Golden 파일을 교체하지 않고 별도 파생
runtime/launcher와 detached manifest만 생성해야 한다.

### 7단계 — 파생 lane 배포와 Micron 검증

Golden을 수정하지 않고 별도 runtime/launcher 이름으로 배포한다. 실행 전
detached manifest에서 예상 drift가 새 Epinel server artifact와 파생 launcher에만
한정되는지 확인한다.

Micron validation은 최대 두 번으로 제한한다.

1. Challenge validation
   - Solo Raid 메뉴 진입
   - Challenge 선택
   - squad 또는 실제 battle runtime 진입 확인
   - client를 운영자가 닫고 completion 실행
   - runtime cold 및 DB 복원 확인
2. Practice validation
   - Mock Battle 선택
   - squad 또는 실제 battle runtime 진입 확인
   - Challenge count 불변 확인
   - client를 운영자가 닫고 completion 실행
   - runtime cold 및 DB 복원 확인

한 번이라도 실패하면 즉석 patch나 자동 재시작을 하지 않는다. redacted server
route timeline, Player.log의 packet/stack 위치, DB before/after digest를 회수한 뒤
Samsung에서 다시 분류한다.

#### 7단계 Samsung 배포 완료 상태 — 2026-08-27

Samsung에서 배포 전 `-AuditOnly` 변환 감사, 생성될 네 PowerShell tool의 구문
검사, selected-manager focused test 96/96, Phase 0~3B-2 연쇄 gate와 Actions
contract를 통과했다. working-tree repository policy의 기존 `origin` remote 및 과거
dotnet telemetry `.trn` 예외는 이번 변경과 무관하며 새 예외는 추가되지 않았다.

독립 파생 lane을 Micron에 배포했다.

- deployment UID:
  `396f1808-173d-482b-9158-dbdf2ae8abfd`
- deployment receipt SHA-256:
  `51a47dfe74b3147aa2c621cc1ff63b86edd3b1edb4868780e2d986bfc3589584`
- derived runtime:
  `C:\NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v1`
- parent runtime 대비 drift: `EpinelPS.dll` 한 개
- DB SHA-256:
  `dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019`
- derived server DLL SHA-256:
  `a28965089f0fcf68d063e6d36fe137e19e68b8618bc01e2e1008c51b18fc64ef`
- historical receipt binding: 적용하지 않음
- wrapper self-hash binding: 적용하지 않음
- source manifest receipt binding: 적용하지 않음
- cache: 복사·수정 없이 기존 검증 cache에 junction으로 연결

배포 전후 parent runtime manifest SHA-256은
`4a682d571e395ea3c84b37ce2cba5ceac54f2f0aeb9cc0ff179787b186f24d56`로
동일하다. Micron Lobby Golden과 D Lobby Golden도 변경되지 않았으며, D backup
seal SHA-256은 계속
`e4c1f9af044387f1624a828421800b29c9a0aa4c015f4e82f3534f70484ea613`이다.

따라서 7단계의 Samsung 배포 절반은 완료됐다. 다음 작업은 운영자가 Micron에서
Challenge validation 한 번을 수행하는 것이다. Challenge 성공과 completion 복원
확인 전에는 Practice validation을 실행하지 않는다.

#### 7단계 첫 preflight 결함과 복구 — 2026-08-27

첫 Micron Challenge 실행은 client/server 시작 전에
`phase3b2_solo_raid_trial_practice_start_cache_link_invalid`로 중단됐다. 원인은
Samsung에서 파생 runtime을 만들 때 junction 대상에 offline mount 문자 `E:`를
저장한 것이다. 같은 볼륨을 Micron으로 부팅하면 대상 cache는 `C:`에 있으므로
launcher의 올바른 부팅 경계 검사와 충돌했다.

이 실패는 inner start 이전이므로 server/client 실행, active pointer 생성 또는
validation run 소비가 없었다. DB, DLL, cache 내용, Golden과 D 백업도 변경되지
않았다.

재배치 로직은 junction에 Micron 부팅 경로 `C:\NLL\...\cache`를 기록하도록
수정했다. 이미 배치된 lane에는 다음 독립 복구 도구를 추가했다.

`C:\NLL\Tools\Repair-Phase3B2-Epinel-SoloRaidTrialPractice-CacheJunction-v1.ps1`

이 도구는 Micron에서 runtime cold, 기존 `E:` junction shape, DB/DLL/header 및
deployment receipt를 확인한 뒤 junction만 `C:` 대상으로 교체한다. cache 복사,
cache 내용 변경, DB/server 변경, receipt/self-hash 결박은 수행하지 않는다.

#### 7단계 첫 Challenge 실전 결함 원인 확정 — 2026-08-27

첫 Challenge validation은 Solo Raid 메뉴와 `OpenTrial`까지 성공했지만 실제 전투
진입 전 재검증에서 season-end 경로로 이탈했다. exact deployed DLL과 시즌 26
`StaticData.pack`을 결합한 Samsung read-only 재현으로 원인을 단일 대입까지
좁혔다.

- `OpenSoloRaid`가 stat-enhance ID를 조회하는 과정에서 공유 정적
  `MonsterRecord.SkillData`를 빈 배열로 덮어썼다.
- pristine target observation의 monster 역할은 96줄이었지만, 이 대입 뒤에는
  scalar/header 19줄만 남았다.
- 다음 `GetLevelTrial` target 재검증은
  `canonical_role_cardinality_mismatch`로 fail closed했고, client에는 완전한
  `JoinData`가 전달되지 않았다.
- 여기서 19/96은 진행도나 raid count가 아니라 동일 monster 정적 관측의
  실제/계약 canonical role line 수다.

Golden·Micron runtime을 변경하지 않고 Git-external 파생 source에서 이 파괴적
대입 한 줄만 제거하고 source audit 회귀 test를 추가했다. Samsung 후보 DLL의
검증 결과는 다음과 같다.

- selected-manager focused suite: 97/97 pass
- 후보 DLL SHA-256:
  `2366129e5974291ce7ae61d5c10f12991b01fc6b5752b6dcb2d60a551177cd33`
- exact 시즌 26 pack SHA-256:
  `8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3`
- `OpenSoloRaid` 전후 skill shape: 총 30개, nonzero 15개로 동일
- expected/exact 역할 수: `[3, 13, 13, 96, 12, 12]`로 동일
- pristine 및 Open 이후 target observation: 모두 `trusted_target`
- materialization 및 replay verdict:
  `exact_materialization_and_replay_verified`
- official outbound 및 Micron runtime mutation: 0

이 후보는 아직 Micron에 배포하지 않았다. 다음 작업은 기존 파생 lane과 Golden을
그대로 보존하면서 새 DLL만 별도 versioned repair로 오프라인 배치한 뒤,
Challenge validation 한 번을 다시 수행하는 것이다.

### 8단계 — 성공 상태 승격과 D 백업

Challenge와 Practice가 모두 실제 전투에 진입하고 completion 복원까지 정상일
때만 파생 상태를 새 안정 후보로 승격한다.

- 기존 D Golden은 덮어쓰지 않는다.
- 새 성공 후보는 별도 이름과 manifest로 D에 백업한다.
- code, DB, tools, source-free verification metadata를 보존한다.
- 39 GB cache는 기존 검증 정책에 따라 전체 복사 여부를 별도로 결정하며,
  복사하지 않을 경우 exact member manifest와 content digest를 보존한다.
- 성공 전에는 D에 새 후보 백업을 만들지 않는다.

### 합딜·최고기록·로컬 랭킹 v6 후보 — 2026-08-28

Regroup v5에서 Challenge 5개 덱 완주와 결과 화면 합계
`31,145,048,111`은 확인됐지만 결과의 `My High Score`는 0, Solo Raid 로비는
이전 합계 `30,014,266,925`, Ranking은 미등록 상태였다. 원인은 완료 run의
다섯 로그와 합계는 DB에 존재하지만, classic Epinel이 이를 최고 기록·랭킹
응답으로 투영하지 않았기 때문이다.

Git-external의 별도 v6 후보는 다음 불변식을 구현한다.

- 완료된 Challenge 중 `TotalDamage`가 가장 큰 단 하나를 최고 기록으로 선택한다.
- `GetInfo.TrialDamage`, 결과 High Score, 로비 합계와 `/soloraid/getranking`의
  rank 1 damage가 같은 최고 기록 합계를 사용한다.
- 낮은 점수의 후속 5덱 완주는 현재 run 결과에는 표시되지만, 기존 최고 기록과
  그 다섯 로그를 덮어쓰지 않는다.
- Ranking 상세 UI의 실제 요청 `/soloraid/getrankersquad`를 추가했다. 이 응답은
  랭킹 합계를 만든 동일한 최고 기록의 로그 정확히 5개를 덱 1~5 순서로 반환한다.
  따라서 상세 로그 damage 합은 Ranking damage와 반드시 같다.
- 로컬 전용이므로 Ranking은 현재 사용자 한 명만 `rank=1`로 반환한다. 타 USN
  조회는 빈 응답이며 공식 ranking/backend로 fallback하지 않는다.
- 완료 `BattleResult=1`은 `completed_consuming`, retry `4`와 Regroup `6`은
  `non_consuming`으로 completion 진단에서 구분한다.

Focused selected-manager suite는 `106/106` 통과했다. 고정 source manifest는
20개/SHA-256 `ca72c8933e0cc7f3c037dbca042d78dcdb98cbd2201e569e6ae744d5080fb207`,
후보 DLL은 15,382,016 bytes/SHA-256
`f9bb3696e8e2b550cebf01bd0065c3757cc9eb2fb064d93b000885f13fa0dba2`다.
Samsung read-only audit에서 v5·Micron Golden·D checkpoint 통합 지문
`9d20896ad82984e90cd63a14bbccc323e3b80678676ef243ab87daea4df7c095`를
확인했다.

첫 관리자 배포 preflight의 `candidate_dll_drift`는 external source 커밋 뒤
`AssemblyInformationalVersion`에 새 Git HEAD가 자동 포함되면서 발생했다. 기능
source와 DLL 길이는 변하지 않았다. v6 빌드는 이제
`IncludeSourceRevisionInInformationalVersion=false`를 명시하여 repository HEAD와
artifact identity를 분리한다. 같은 clean source에서 두 번 연속 빌드한 DLL의
길이와 SHA-256이 위 값으로 동일함을 확인했다.

배포 도구는
`scripts/deploy-phase3b2-epinel-solo-raid-score-ranking-v6-offline.ps1`이다.
이 도구는 기존 v5나 두 Golden을 수정하지 않고 `E:\NLL\...ScoreRanking-v6`와
`P3SRSR6`에만 새 파생 lane을 만든다. Codex 비관리자 실행은 관리자 preflight에서
mutation 전에 중단됐으므로, 현재 상태는 `audited_deployable_not_deployed`다.
Samsung 관리자 PowerShell에서 도구가 성공 receipt를 출력하기 전에는 Micron v6
검증을 시작하지 않는다.

배포 직전 재감사는 2026-08-28에 다시 통과했다. `-AuditOnly`는 external
selected-manager suite `106/106`, 후보 DLL과 source manifest digest, v5 runtime
cold 상태, Micron Golden과 D checkpoint 불변성을 재확인했다. 저장소 계약
게이트는 Phase 0, Phase 2A1, Phase 2A2, Phase 2B unit, Phase 3A, Phase 3B-0,
Phase 3B-1, Phase 3B-2가 모두 통과했다. `verify-repository.ps1` umbrella만 이번
변경과 무관한 기존 `origin` remote 및 과거 도구의 `.trn` 산출물 때문에 계속
실패한다. v6 배포 스크립트 PowerShell syntax error는 0이고 변경 파일의
`git diff --check`도 통과했다.

### 점수 표면 일관성 v7 파생 후보 — 2026-08-28

v6 actual play의 다섯 덱 기록은 각각 `6,552,069,396`, `7,380,661,799`,
`9,564,236,818`, `7,097,076,893`, `12,148,004,419`였고 합은 정확히
`42,742,049,325`였다. 전투 결과와 Battle Records는 이 값을 보였지만 결과의
`My High Score`는 0, Solo Raid 로비 및 Raid Ranking 요약은 서로 같은
`41,…` 값을 보였다.

같은 assessment의 redacted server stdout을 route별로 재검사했다.

- `/v1/soloraid/getperiod`: 4회
- `/v1/soloraid/trial/setdamage`: 8회
- `/v1/soloraid/get`: 0회
- `/v1/soloraid/getranking`: 0회
- `/v1/soloraid/getrankersquad`: 0회

따라서 `41,…`은 서버의 별도 ranking 계산이나 저장된 합계가 아니다. 클라이언트가
마지막 `trial/setdamage` 응답을 받은 뒤 dedicated ranking route 호출 없이 만든
in-memory fallback 요약이다. v6 응답은 `Info.Damage=42,742,049,325`를 보냈지만
같은 응답의 ranking summary인 `User`와 `TotalUserCount`를 채우지 않았다. 이 결손이
클라이언트 fallback을 활성화한 직접 원인이다. stripped IL2CPP metadata와 raw request
비보존 정책 때문에 fallback의 내부 산식 자체는 재구성하지 않으며, 관측되지 않은
공식을 추정하지 않는다.

v7은 v6를 수정하지 않는 새 파생 lane이다. `trial/setdamage`의 완료 응답에
`User.Damage=best completed five-deck TotalDamage`, `User.Ranking=1`,
`TotalUserCount=1`을 투영한다. `/soloraid/get`, `/soloraid/getranking`,
`/soloraid/getrankersquad`도 같은 최고 완료 기록을 계속 사용한다. 따라서 한 run의
결과, High Score, 로비, Raid Ranking, 상세 다섯 덱 합은 모두 하나의 권위 값으로
수렴한다. 과거 숫자 `42,742,049,325`를 상수로 하드코딩하지 않는다. 새 run에서는
새 다섯 덱 합이 권위 값이며, v6 관측 run을 동일 상태로 재현할 때만 위 숫자가 다시
나온다.

구현·오프라인 검증 상태는 다음과 같다.

- 변경 source manifest: 21개/SHA-256
  `caf873d9b353a4879ab4ef4ace596d478d3c3b6c65b3e33103d400b66d7ef4dd`
- focused selected-manager suite: `106/106`
- `trial/setdamage` ranking summary는 protobuf round-trip 뒤에도 동일 score/rank/count를
  유지한다.
- 결정적 후보 DLL: 15,383,552 bytes/SHA-256
  `39949e0d490d5d4996cd26fb1cd6a990ff57c20bfd99676c14878b9dba4e0a39`
- v6 부모·Micron Golden·D Golden: read-only, 통합 fingerprint
  `7dc68f09db0fb74b57326d39d1d7de7a8f412c87d7746c89ffb6d4fe143b33ff`
- 파생 start/completion 네 도구: PowerShell parse error 0, v6 lane 참조 잔존 0
- completion은 raw payload 없이 `NLL_SOLO_RAID_SCORE_RESPONSE/v1` marker만
  봉인한다. 성공 `battle_result`에서 마지막 완료 응답의 `Info.Damage`,
  `User.Damage`, DB의 다섯 덱 합과 `TotalUserCount=1`을 필수 교차검증한다.
  dedicated 조회 marker가 관측된 경우 같은 합계와 상세 로그 5개도 검증한다.

배포 도구는
`scripts/deploy-phase3b2-epinel-solo-raid-score-consistency-v7-offline.ps1`이다.
`-AuditOnly` 뒤 Samsung 관리자 PowerShell actual 배포가 deployment UID
`f2bc1e96-0f06-47b3-989b-2e1451e84312`로 성공했다. deployment receipt SHA-256은
`dc9b7cce0b14bf6203f7f4c406699878ee7a2525bf30b51fb9843a0bb374c35e`,
적용 DLL은 15,383,552 bytes/SHA-256
`39949e0d490d5d4996cd26fb1cd6a990ff57c20bfd99676c14878b9dba4e0a39`다.
실제 E: receipt, DLL, 네 tool을 개별 재해시하여 전부 receipt와 일치함을 확인했다.
runtime은 cold, active pointer와 SQLite runtime은 없고 validation run은 미소모다.
v6 DLL과 두 Golden도 변경되지 않았다. 다음 작업은 Micron `nlloperator`에서 5덱을
한 번 완주하고 result/High Score/lobby/ranking/ranking detail의 합계를 교차검증하는
것이다. 성공 actual-play 전에는 D에 v7 백업을 만들지 않는다.

### v7 actual-play 반증과 피해 출처 관측 v8 — 2026-08-28

v7 actual play의 다섯 덱 기록은 `4,719,633,610`, `5,288,151,013`,
`4,948,022,981`, `10,657,573,515`, `9,563,998,779`였고 합은
`35,177,379,898`이었다. Battle Records와 결과 화면의 파란 합계는 이 값과
정확히 일치했다. 그러나 결과의 `My High Score`와 Raid Ranking은
`34,046,598,712`를 표시했다.

이 관측은 위 v7 설계의 "ranking summary 결손이 직접 원인"이라는 판정을
반증한다. v7 app log와 DB를 다시 조사한 결과는 다음과 같다.

- 마지막 `trial/setdamage` 응답의 `Info.Damage`와 `User.Damage`는 모두
  `35,177,379,898`이었다.
- 직후 `/soloraid/get`의 `TrialDamage`도 `35,177,379,898`이었다.
- 세 차례 `/soloraid/getranking`의 `Rankings[0].Damage`와 `User.Damage`도 모두
  `35,177,379,898`이었다.
- `/soloraid/getrankersquad`의 다섯 로그 합도 `35,177,379,898`이었다.
- runtime `db.json`, E: 전체 NLL evidence, LocalLow 파일의 평문 검색 어디에도
  `34,046,598,712`가 존재하지 않았다. 해당 시간대 LocalLow에서 갱신된 파일은
  값 본문을 기록하지 않는 `Player.log` 하나뿐이었다.

따라서 서버에서 `34,046,598,712`를 반환하거나 보존한 코드는 없으며, 그 값을
삭제할 서버 분기는 존재하지 않는다. 클라이언트가 `request.Damage` 누계와 별개로
전투 요청의 anti-cheat/battle-report 자료에서 in-memory ranking score를 만든다는
새 가설을 먼저 검증해야 한다. 특히 요청에는 `TotalDamage`와
`TotalActualDamage`/`TotalActualDamageReceived`가 동시에 존재하므로, raw 피해와
실제 적용 피해의 차이가 가장 먼저 검사할 후보이다. 두 값의 차이는
`1,130,781,186`이다.

이를 위해 v7을 수정하지 않는 `SoloRaidDamageSourceObserver-v8` 후보를 만들었다.
서버 응답, DB mutation, ranking 정책은 v7과 완전히 동일하고 다음 비식별 숫자만
각 `trial/setdamage` marker에 추가한다.

- request damage
- 캐릭터 일반 공격·스킬·stat-function의 raw/actual damage 합
- 몬스터 HP의 raw/actual damage-received 합
- parts/projectile damage-received 합
- character/monster 개수와 report-data byte length

캐릭터 ID, 팀, report bytes, raw protobuf payload는 기록하지 않는다. 합성 집계
단위 test 2개를 추가했으며 selected-manager focused suite는 `108/108` 통과했다.
후보 DLL은 15,392,256 bytes/SHA-256
`7220be7819121c38acfe9b221bfa6a89b7f894e737bd5df97a955289e2417519`, source
manifest는 22개/SHA-256
`4a0a1f71fe9b7a235703293d6a9c6adb9626ab18b0a8d8daf885c01008fe1f02`다.

배포 도구는
`scripts/deploy-phase3b2-epinel-solo-raid-damage-source-observer-v8-offline.ps1`이다.
현재 v7 assessment `450862f3-3419-4f4d-bb52-1aaa0abca161`의 completion이 아직
실행되지 않아 `-AuditOnly`는 의도대로
`phase3b2_damage_source_observer_v8_parent_run_not_completed`에서 fail closed한다.
먼저 Micron에서 v7 completion으로 DB·hosts·runtime을 복원한 뒤에만 v8 audit 및
배포를 진행한다. 관측 합계 중 하나가 다음 UI ranking score와 정확히 일치하기
전에는 ranking 산식이나 응답 값을 다시 변경하지 않는다.

Samsung의 `E:\Program Files\dotnet\dotnet.exe`는 현재 .NET SDK 8.0.407이라
`net10.0` focused suite를 실행할 수 없다. v8 배포 도구는 저장소 안의 격리된
`.tmp-dotnet-sdk-10.0.400\dotnet.exe`를 기본 검증 runtime으로 선택하고 SDK major가
10인지 별도로 검사한다. 같은 runtime으로 focused suite `108/108`과 후보 DLL
byte/hash 재현을 다시 확인했다. 파생 도구 네 개도 메모리상 완전 재구성하여
PowerShell parse error 0, v7 부모 참조 잔존 0을 확인했다. 배포 commit 이후 검증이
실패하는 경우에는 이번 실행이 새로 만든 v8 runtime·evidence·deployment·tool 및
protected copy만 제거하며 v7과 두 Golden은 rollback 대상으로 삼지 않는다.

#### v7 completion 부분 실패와 복구 — 2026-08-28

assessment `450862f3-3419-4f4d-bb52-1aaa0abca161`의 첫 completion은 runtime 정지,
marker-only evidence 생성, app log 제거까지 끝낸 뒤
`phase3b2_score_consistency_v7_projection_verification_failed`로 중단되었다. DB·hosts·
SQLite·active pointer 복원보다 앞에서 실패했으므로 Samsung에서 v8을 바로 파생해서는
안 된다.

봉인된 marker 26개를 재검사한 결과 최종 완료 응답 이후의 `/soloraid/get` 1개,
`/soloraid/getranking` 3개, `/soloraid/getrankersquad` 3개는 모두
`35,177,379,898`과 일치했다. 실패 원인은 completion이 전투 시작 전과 중간 덱 완료
후의 정상적인 0점 조회까지 최종 점수와 같아야 한다고 검사한 데 있다. 전투·점수
projection 실패가 아니다.

복구 도구는
`scripts/repair-phase3b2-epinel-solo-raid-score-consistency-v7-completion-offline.ps1`
이다. 원래 inner completion 23,342 bytes/SHA-256
`734d2c50f43f57f3acedcbbb35536d8ca0b573147bd4887cf0c7c71d187e63fb`를 보호
백업하고, 최종 완료 UTC 이후의 조회만 엄격히 검사하는 24,272 bytes/SHA-256
`6b84316b208f125e4c74aa7982eed754935b19be640ad54e65ce8df79c3549b2` 후보로
교체한다. `-AuditOnly`는 원인 재현과 post-final 검증 통과를 확인했으며 DB, hosts,
pointer, marker, Golden에는 mutation을 수행하지 않았다. 교체 후 Micron에서 기존 v7
completion을 start 없이 다시 실행하면 보존된 marker를 재사용하여 정상 rollback과
receipt 생성을 마친다. v7 배포 원본과 v8 파생 도구에도 같은 post-final 시간 경계를
반영했다.

### ranking wire 과잉 차감 원인과 v9 수정 — 2026-08-31

동결된 150.6.9 원본 클라이언트의 소비 경로와 시즌 26 Static Data를 함께 대조해
`1,130,781,186` 고정 차이의 원인을 확정했다. `NetTrialSoloRaid.Damage`는
Challenge-local raw 점수지만 `NetSoloRaidRankingData.Damage`와
`NetUserSoloRaidInfo.TrialDamage`는 Common I~VII를 포함한 누적 wire 점수다. 원본
클라이언트는 ranking 도메인에서 Common I~VII 최대 체력 합을 차감한다. v7/v8은 모든
필드에 raw 점수를 동일하게 넣어 ranking 표면에서만 해당 합이 한 번 과잉 차감됐다.

수정은 DB나 덱 로그를 바꾸지 않는다. `SoloRaidLevelData.TotalDamage`,
`SoloRaidLogData.Damage`, `trial/setdamage`의 `Info.Damage`, ranker-squad 로그는 raw를
유지한다. `TrialDamage`와 ranking `Damage`에만 선택 manager Static Data에서 엄격히
해소한 Common prefix를 응답 경계에서 더한다. prefix 결손·중복·모호성 및 산술
overflow는 mutation 전 fail closed한다. 누적값을 저장하지 않으므로 재시작·반복 조회
때 이중 적용되지 않는다.

선택 경로 focused suite는 `114/114` 통과했다. 동결 Static Data probe는 Common 7개와
Trial 1개의 exact closure 및 prefix `1,130,781,186`을 확인했다. 후보 DLL은
15,398,400 bytes/SHA-256
`98d4f4d12ff83c694ee052f9eca3c63ae782f2c4747a80993ee257384eef2498`, 19개 source
manifest SHA-256은
`be2b0107ecec425d3c6dc4538d33306f81c55e0142f312fa3da9bd10ed29a1d7`이다.

새 v9 lane은 repaired v8을 읽기 전용 부모로 사용하고 v8을 제자리 수정하지 않는다.
배포 스크립트
`scripts/deploy-phase3b2-epinel-solo-raid-ranking-prefix-v9-offline.ps1`의 `-AuditOnly`는
통과했다. Micron `nlloperator` 관리자 배포도 deployment UID
`3b57e48d-51f2-4d65-96b8-2b7a7d683108`로 성공했다. deployment receipt는
3,501 bytes/SHA-256
`d360b29ca19fa36c6c1504d7b29a30d541621bf5855b45810f87e43d9e63a269`이며, v9 runtime
DLL과 네 start/completion tool은 receipt의 길이·해시와 다시 일치했다. v8 DLL은
`7220be7819121c38acfe9b221bfa6a89b7f894e737bd5df97a955289e2417519`로 불변이고 관련
runtime process는 0이다. Control Center coordinator는 봉인 v9를 부모로 사용하고
실행별 DB hash만 파생 도구에 치환한다.

2026-08-31 운영자가 v9 lane으로 원본 150.6.9 클라이언트의 Solo Raid Challenge
5덱을 실제 완료했다. 최종 결과 화면의 파란 총점과 노란 `My High Score`가 모두
`24,972,784,671`로 정확히 일치했고, 기존의 고정 과잉 차감 `1,130,781,186`은
재현되지 않았다. 따라서 ranking wire 과잉 차감과 두 결과 점수 불일치 문제는 원본
클라이언트 acceptance까지 통과한 **해결 완료** 상태다. 게임 재실행 뒤 최고 기록과
5개 덱 기록을 유지하는 영속성 검증은 이 판정과 분리된 후속 과제다.

v9 resolver는 시즌 26 ID나 prefix 상수를 응답에 하드코딩하지 않고 선택 manager의
Common I~VII Static Data를 따라 prefix를 계산한다. 같은 7 Common + 1 Trial classic
구조를 가진 다른 시즌에도 일반 적용되며, 결손·중복·다중 target·비표준 `HpRatio`,
stage-change 또는 overflow에서는 mutation 전에 fail closed한다. 현재 actual-play가
실증한 시즌은 시즌 26이므로, 다른 보스를 publish할 때는 해당 manager closure와 원본
클라이언트 점수 일치 smoke를 다시 통과시킨다. Museum은 대상이 아니다.

## 5. 역할 분담

- 1~6단계: Samsung에서 오프라인 분석·구현·검증
- 7단계의 Micron UI 조작과 client 종료: 운영자
- 각 Micron run의 completion 결과 분류: Samsung에서 오프라인 수행
- 8단계 D 백업: 실제 플레이 acceptance가 모두 통과한 뒤 수행

## 6. 중단 조건

다음 중 하나라도 발생하면 추가 retry 없이 중단한다.

- `Success + null` nested message 재발
- Challenge와 Practice 상태 또는 count 교차 오염
- Golden 대상 drift 발생
- official outbound 또는 launcher 실행 관측
- completion 뒤 runtime이 cold가 아님
- DB restore digest 불일치
- client가 실제 battle 전에 `System Error` 또는 season-end 경로로 이탈
