# 레이드 개인별 대미지 원자료 수집

> 2026-09-27 보관: 작성 당시의 기록이며 현재 작업 지시가 아닙니다. 현행 문서는 [문서 색인](../../README.md)에서 찾습니다.

2026-09-20 후속: [실제 기록 연결](RAID_RECORDS_LIVE.md)에서 솔로 Challenge 모의전 수집, 지속 원문 보존, 개인별 투사체 차감값 V0028 저장과 관리도구 조회를 적용했다. 아래 진단 세션 및 미연결 설명은 당시 조사 이력이다.

BattleLog의 읽는 법과 모든 이벤트·필드 설명은 [BattleLog 전체 해설](../../reference/battlelog/BATTLE_LOG_GUIDE.md)을 참고한다. 아래는 수집 경로·확정 공식·저장 계약과 작업 이력을 다룬다.

2026-09-18 운영자는 TAB 딜표의 출처를 대조하기 위해 우선 원래 통계를 확보하도록 요청했다.
다른 보스에서의 기존 확인과 크리스탈 체임버의 실제 보고서·TAB 딜표 대조를 바탕으로, 운영자는 아래 관계를 확정하고 추가 공식 검증을 종료하도록 지시했다.

## 확정된 대미지 공식

```text
캐릭터별 TAB 대미지 = Characters[i].Attack.TotalDamage

덱 딜표 합계 = Σ Characters[i].Attack.TotalDamage
결과창 총 대미지 = 덱 딜표 합계
                  + Σ Monsters[j].Hp.TotalPartsDestroyDamageReceived
                  - Σ Monsters[j].Hp.TotalProjectileDamageReceived
```

캐릭터별 딜표 값에 `Skill.TotalDamage`나 `StatFunctionAttack.TotalDamage`를 추가로 더하지 않는다. `Attack.TotalActualDamage`도 TAB 표시값으로 대체하지 않는다. 해당 원값들은 비교·분석용으로 각각 별도 보존한다.

DB의 개인별 딜표 값은 `raid_character_damage.attack_total_damage`다. 결과창 총 대미지는 원본 요청의 `raid_battle_observation.request_damage`를 보존하며, 서버가 승인한 값은 `accepted_damage`에 별도 저장한다. 공식은 두 값의 차이를 임의로 덮어쓰는 용도가 아니다. 메시지 결손은 아래 null 규칙을 유지한다.

확정 근거: 이전 다른 보스 확인에 대한 운영자 확인 및 크리스탈 체임버 실제 전투 대조. 실제 계정·수치 증거는 Git 제외 `artifacts/raid-damage-capture-20260918/crystal-comparison.private.json`에 보존하며, 공식 확인을 위한 추가 실게임 검증은 요구하지 않는다.

## 수집 경로

### BattleLog 조사 — 2026-09-19

개인별 투사체 대미지의 추가 출처를 찾기 위해 현재 152 프로토콜과 로컬 보존
로그를 읽기 전용 조사했다. `NetAntiCheatBattleData.BattleLog`는 field 22의
`bytes`이며 기본값은 `ByteString.Empty`다. 문자열/JSON/압축 형식이나 이벤트
구조를 선언하는 nested message는 없다. 현재 Solo/Union 결과 요청은 이 보고서를
전달할 수 있지만, 필드 존재만으로 실제 전송·내용·개인별 귀속 가능성을 확정할 수 없다.

현재 Epinel의 결과 처리와 통계 projector는 이 필드를 해석하거나 저장하지 않는다.
이름이 유사한 `GetUnionRaidWholeBattleLog/UserBattleLog/StepBattleLog`는 기존
레이드 결과 목록 API로서 이 바이트 필드의 decoder가 아니다.

실행별 `server.stdout.log` 및 정해진 runtime 로그 위치에서 비어 있지 않은 파일
88개를 검사했으나 해당 보고서 JSON/BattleLog는 발견되지 않았다. `LobbyMessage`는
본문을 Debug로 출력하지만 설치 경로의 콘솔 기본 수준은 Info이고, 조사한 runtime에는
log4net 설정 파일과 원문 rolling log가 없었다. 통계 DB도 숫자 whitelist만 저장하므로
과거 저장 자료에서 BattleLog를 복원할 수 있는 근거를 찾지 못했다. 이것은 실제
클라이언트가 빈 BattleLog를 보냈다는 관측이 아니다.

152 복제본의 디스크 정적 검사에서 global-metadata.dat는 0바이트이고
GameAssembly에는 BattleLog/battle_log/StatisticsContext/TotalProjectileDamageReceived의
ASCII·UTF-16 심볼을 찾지 못했다. 이 검사만으로 생성 함수나 내부 형식을 추정하지 않는다.
게임 프로세스 접근·후킹·실행, 서버/DB/설치본 변경은 수행하지 않았다.

다음 증거는 새 로컬 전투 결과의 BattleLog 단일 필드다. 우선 길이·hash·빈 값 여부를
관측하고, 비어 있지 않을 때만 제한된 비공개 진단 파일에서 형식을 판별해야 한다.
공격자·대상 종류·피해량의 연결이 실제 포함됐는지 확인하기 전에는 개인별 투사체
대미지 확보 가능성을 약속하지 않는다. 기존 확정 공식의 재검증은 필요하지 않다.
조사 근거: `artifacts/battlelog-investigation-20260919/`.

### BattleLog 단일 필드 수집 적용 — 2026-09-19

운영자의 “일단 BattleLog에 뭐가 있는지는 보죠” 요청에 따라 기존 로컬 결과 처리에서
이 필드만 별도 비공개 진단 파일로 수집하도록 적용했다. 전체 요청/인증정보 출력이나
게임 프로세스 후킹은 사용하지 않는다. 기존 숫자 전용 통계 DB 계약은 유지한다.

`BattleLogDiagnostics.cs`는 `%LOCALAPPDATA%/NikkeLocalLab/Diagnostics/BattleLog/capture.json`의
명시적 진단 세션이 있을 때만 동작한다. 이번 세션은 설치 시점부터 2일, 최대 10건,
건당 8MiB로 제한한다. 세션 UUID 폴더에 로컬 BattleUid를 이름으로 원본 바이트와
길이/hash/문맥 receipt를 저장한다. 보고서 결손·빈 값·크기 초과를 구분하며 중복은
저장하지 않는다. 폴더는 현재 사용자/SYSTEM/Administrators만 접근하도록 설치했다.
진단 실패가 기존 전투 결과 처리를 중단하지 않도록 예외를 격리한다.

16:54 KST 설치 완료. 서버 DLL 두 사본과 실행 bundle/selection/pipeline 연결을 함께
갱신했다. 합성 수집 검사 27개 및 기존 서버 검사 180개 통과. 서버 SHA-256은
`ca082dee3a7d1efdf3225a95ee83218b2eadb6b6cbd8339a447b6ba6c5e9faf2`.
근거와 롤백 파일은 Git 제외 `artifacts/battlelog-capture-20260919/`에 있다.
실제 BattleLog는 아직 미관측이며 다음 새 전투 결과가 필요하다. 개인별 투사체 피해
귀속 가능성이나 내부 형식은 확인되지 않았다.

후속 실전 관측: 2026-09-19 17:54:58 KST의 Solo Challenge 결과는 총 대미지
10,187,383,912와 캐릭터 5명의 숫자 통계를 runtime receipt에 저장했다. 실행 DLL은
위 설치 SHA-256과 일치하지만 진단 폴더에는 활성화 파일만 있고 전투 receipt/blob는
없다. 따라서 BattleLog가 빈 값이었다고 판정할 수 없다. 미수집 원인은 아직 미확정이다.
기존 구현은 비활성/설정 결손/중복/상한 도달 시 조용히 반환해 구분 근거가 없었다.
각 상태와 보고서 존재·바이트 길이를 제한된 로그에 남기는 보완본을 준비했고 합성
검사 30개가 통과했다. `artifacts/battlelog-capture-20260919/followup/`의 보완본은
운영자 종료 확인 후 18:10 KST 설치 완료했다. 서버 DLL 두 사본과 bundle/selection/
pipeline 연결 파일 총 5개를 갱신했고 설치 해시 및 연결 검사를 통과했다. 새 서버
SHA-256은 `016dda84679b25a4a8fc5bc1fe739c0100ae1a0a44f12fc804fb1e4218dda299`.
DB 변경은 없으며 실제 BattleLog 관측은 여전히 다음 전투 대기 상태다.
Solo Practice 수집은 운영자 요청에 따라
추가하지 않았다. 이번 실전의 원문을 소급 복원했다는 의미가 아니다.

18:19:41 KST 후속 Solo Challenge 실전에서 총 대미지 10,109,411,308 및 캐릭터
5명 통계 저장을 확인했다. 진단 로그는 `reportPresent=True byteLength=154726`과
`status=config_missing_or_inaccessible`을 기록했다. 따라서 BattleLog의 실제 전송과
비어 있지 않음은 확인됐지만 원문 저장·형식 해석은 아직 완료하지 못했다. 설치
계정에서 AppData 활성화 파일과 ACL은 정상 조회되며, 서버에서 조회되지 않는
구체적인 Windows 경로/실행 문맥 차이는 미확정이다.

프로필별 경로 의존을 제거하기 위해 CommonApplicationData 아래
`C:/ProgramData/NikkeLocalLab/Diagnostics/BattleLog`를 쓰는 수정본을 준비했다.
첫 DB 저장(서버 시작 시 수행)에서 한 번 설정 유효성 및 probe 파일 생성·flush·삭제를
검사하고 `NLL_BATTLE_LOG_READY/v1` 상태를 남긴다. `ready`를 실제 서버 로그에서
확인하기 전에는 다음 전투 수집 가능을 단정하지 않는다. 합성 검사 34개 및 기존
서버 검사 180개 통과. 운영자 진행 지시 후 18:29 KST에
`artifacts/battlelog-capture-20260919/path-fix/` 수정본 설치를 완료했다. 서버 SHA-256은
`7f25297a18ae6c84022c7fe3b7655087c2b3fccf1026ec28ea70a575ab62d08b`이다.
같은 DLL을 쓰는 별도 진단 프로세스에서 공용 폴더 설정 읽기·쓰기·삭제 `ready`를
확인했다. 이는 실제 게임 서버 프로세스의 준비 상태나 원문 수집 성공 증거는 아니며,
새 게임 실행의 `NLL_BATTLE_LOG_READY/v1 status=ready`를 먼저 확인해야 한다.

후속 로비 진입에서 실제 서버 로그의 `NLL_BATTLE_LOG_READY/v1 status=ready`를
확인했다. 실행 DLL 해시도 위 경로 수정본과 일치한다. 근거는
`artifacts/automation/phase-d-executions/eb4fe77a-c778-4177-a0bc-b1f055cc51d0/evidence/8ad99617-cac7-4cba-a4a1-7c9618ee9697/server.stdout.log`다.
실제 서버의 설정 읽기·쓰기 준비 상태는 확인됐으며 BattleLog 원문은 새 전투 대기다.

### 실제 BattleLog 확보 및 개인별 투사체 피해 분리 — 2026-09-19

18:43:28 KST Solo Challenge 3분 전투에서 원문 121,396바이트를 비공개 진단
폴더에 저장했다. SHA-256은
`de1abad540a7bdb7c1958585f0e057cceee03e7aa56980145f0035c2a05a1210`이다.
로컬 전투 UUID는 `ab8389b0-7921-4f9b-b97c-b59a030c5496`이며 원문·압축 해제물·
상세 이벤트는 `C:/ProgramData/NikkeLocalLab/Diagnostics/BattleLog/`의 해당 세션
폴더에만 보관한다. Git에 넣지 않는다.

관측한 이진 구조는 다음과 같다. 현재 한 샘플에서 본문 전체가 정확히 소진되는
파서를 확보한 것이며, 모든 빌드에 일반화한 제품용 decoder는 아니다.

- unsigned base-128 길이 3,731 뒤에 그 길이만큼의 헤더가 이어진다.
- 헤더에 스탯 이름 12개, 이벤트/자료형 이름·필드 이름 정의 62개가 있다.
- offset 3,733 이후 raw DEFLATE 본문 117,663바이트를 1,523,468바이트로 해제했다.
  압축 스트림 EOF와 잔여 바이트 없음, 본문 전체 파싱을 확인했다.
- 레코드는 정의 인덱스와 문맥 값, 필드 순서의 ZigZag/base-128 숫자로 파싱된다.
  추가 스탯 목록이 있는 정의는 개수와 스탯 인덱스/값 쌍을 가진다. 문맥 값의
  상세 의미 및 일부 kind/flag 의미는 아직 미확정이다.
- 실제 레코드 168,842개. `DamageFormula` 30,608개, `CommonHurtEvent` 30,608개,
  `OnEntityGetDamage` 7,788개, `ProjectileSpawn` 69개, `MonsterPartsDestory` 2개.
  `StatisticsTakeDamage`는 사전에만 있고 이번 본문에는 없다.

`Entity` 정의 순번으로 공격자·대상 참조를 해소했다. `ProjectileSpawn.projectile`
집합 69개가 Entity kind 4 집합과 정확히 같으며 이번 샘플에서는 모두 같은 보스가
owner다. 해당 대상을 향한 `CommonHurtEvent`의 `HurtShape.caster/target`으로
피해량을 공격자별 집계했다. `DamageFormula`의 같은 대상 합계도 일치한다.
Entity의 캐릭터 참조는 로컬 계정 캐릭터와 기존 캐릭터 UUID를 경유하여 5개 편성
슬롯에 모두 연결했다. 원본 게임 ID를 출력/도메인 키로 추가하지 않았다.

| 편성 슬롯 | 투사체에 입힌 대미지 |
|---|---:|
| 1 | 2,697,276 |
| 2 | 2,857,087 |
| 3 | 7,885,543 |
| 4 | 32,260,087 |
| 5 | 61,760,553 |
| 합계 | 107,460,546 |

합계는 같은 전투 보고서 `TotalProjectileDamageReceived=107,460,546`과 정확히
일치한다. `CommonHurtEvent`에서 보스 대상만 합산한 값도 결과창 총 대미지
8,524,114,569와 일치한다. 기존 확정 공식의 추가 보스 재검증이 아니라 이 로그의
decoder와 참조 연결을 확인한 것이다. `OnEntityGetDamage`만 합산하면 투사체
피해가 72,730,664로 누락되므로 이 이벤트 하나만 개인별 투사체 피해 권위로 쓰지 않는다.

따라서 **이번 실제 로그에서 캐릭터별 투사체 피해 분리가 가능함을 확인했다.**
피해 계산 상세 인자, 스킬/버프, 재장전, 회복, 코어/크리티컬/관통 등의 정의도
있지만 각 의미를 모두 검증했다는 뜻은 아니다. DB에 개인별 투사체 피해 컬럼을
추가하거나 자동 투영하지 않았다. 분석 스크립트와 수치 요약은 Git 제외
`artifacts/battlelog-capture-20260919/analysis/`에 있다.

- Solo Challenge: `/soloraid/trial/setdamage`, 승인된 덱 결과만 수집. Retry/Regroup은 제외.
- Union Hard: `/guild/unionraid/hard/setdamage`.
- Union Hard Practice: `/guild/unionraid/pratice/setdamage/hard` (원래 wire 철자).

기존 로컬 서버가 받은 `AntiCheatBattleData`에서 다음 숫자만 복사한다.

- 캐릭터별 `Attack`, `Skill`, `StatFunctionAttack` 각각의 `TotalDamage`, `TotalActualDamage`.
- 몬스터별 `Hp.TotalDamageReceived`, `TotalActualDamageReceived`, `TotalPartsDestroyDamageReceived`, `TotalProjectileDamageReceived`.
- 요청의 총 대미지, 실제 승인 대미지, 전투 시간 원값, 모드·시즌·보스 순번·단계·팀·수신 시각·profile hash·client build.
- 모의전 요청의 초기 HP와 본전/솔로의 BattleResult는 전달되는 경로에서만 보존.

메시지 블록 결손은 null, 존재하는 블록의 0은 0으로 유지한다. protobuf가 presence를 제공하지 않는 scalar의 0으로 파츠/투사체의 부재를 단정하지 않는다. 모든 피해량은 signed 64-bit 정수다. 몬스터는 보고서 내 순번으로만 저장한다. 캐릭터는 로컬 UUID로 해소하며 실패하면 null이다. 원본 Csn/Tid/WaveId, report 원문·바이트·인증정보는 통계 저장소에 넣지 않는다.

## 저장

V0027은 같은 PostgreSQL DB에 세 테이블을 추가한다.

| 테이블 | 역할 |
|---|---|
| `lab_private_server.raid_battle_observation` | 기존 덱/전투의 BattleUid를 PK로 쓰는 관측 부모. 계정 UID FK, 문맥 및 원자료 JSON, replay digest |
| `lab_private_server.raid_character_damage` | `(battle_uid, ordinal)` PK, battle_uid FK, 로컬 캐릭터·슬롯 및 6개 피해량 |
| `lab_private_server.raid_monster_damage` | `(battle_uid, ordinal)` PK, battle_uid FK, 몬스터별 4개 피해량 |

유니온은 기존 진행 JSON과 관측 부모/자식을 동일 transaction에 기록한다. 원래 `LocalUnionBattle.BattleUid`와 정확히 같다. 실패하면 양쪽을 rollback하고 동일 요청 replay는 추가 행을 만들지 않는다.

덱 완주 기록 한 건의 연결은 다음과 같다. 여기서 덱 완주는 한 번의 덱 전투 결과이며, 솔로 레이드 5덱 전체 run 완주와 구분한다.

```text
local_union_raid_runtime.payload.Battles[].Battle.BattleUid
    = raid_battle_observation.battle_uid (PK)
        ← raid_character_damage.battle_uid (FK, 캐릭터별 자식 행)
```

기존 덱 기록은 JSON 안에 있으므로 그 JSON 키 자체에 SQL FK가 걸리는 구조는 아니다. 동일 BattleUid를 관측 부모 PK로 쓰고, 개인 대미지 행은 그 부모를 실제 SQL FK로 참조한다. 각 개인 행에는 슬롯, 로컬 캐릭터 UUID와 대미지가 함께 저장된다. 5인 편성 결과는 부모 한 건에 개인별 5행으로 연결된다.

크리스탈 체임버 운영 DB 읽기에서 덱 결과 1건, 관측 부모 1건, 개인 대미지 5행, 슬롯·캐릭터 UUID의 5건 완전 일치, 대미지 결손 없음 및 실제 FK 존재를 확인했다. 연결 증거는 Git 제외 `artifacts/raid-damage-capture-20260918/deck-link-check.receipt.jsonl`이다.

솔로는 기존 `ClassicSoloRaidBattleReceipt.BattleUid`에 통계를 붙여 원자적 로컬 DB 파일 교체로 먼저 보존한다. 성공한 파일 교체 뒤 PostgreSQL로 투영한다. DB 실패 시 원본 receipt가 outbox로 남고 controlled marker만 로그에 남긴다. 이후 저장과 종료 capture에서 재시도하며, 종료 capture는 투영 실패 시 원자료 복구 전에 중단한다. 과거 receipt는 원래 버전 독립 영속화에도 포함된다. 같은 키·같은 내용의 재전송은 무효과, 다른 내용은 충돌이다.

클라이언트 피해 계산·결과 응답·기존 점수 집계는 바꾸지 않는다. TAB 대응식은 위 확정 공식을 따른다. 기존에 저장하지 않은 개인별 통계를 과거 기록에 만들어 넣지 않는다.

## 구현 및 검증 위치

공통 projector/store: `tools/Phase3B2/EpinelBattleStatistics/` (외부 Epinel 빌드에 링크).
Epinel 접속부: `patches/epinel-raid-damage-capture.patch`.
설치·검사 증거: Git 제외 `artifacts/raid-damage-capture-20260918/`.

합성 검사는 64-bit, null/0, 로컬 식별자 변환, 승인/Retry 구분, 정확한 전투키, 중복 요청, FK, transaction rollback, DB 재시작, Solo outbox 재시도를 포함한다. 설치 완료와 사용자 실제 여러 보스 결과 수집은 별도로 판정한다.

전체 PostgreSQL 회귀 중 기존 fixture 함수의 선택 인자가 추가된 뒤 세 reflection 호출이 갱신되지 않은 결함을 발견했다. 테스트 호출에 기존 기본 snapshot tag를 명시했다. 계정 생성·전투의 제품 동작은 변경하지 않았다. 계정 가져오기 검사도 기존 공통 migration helper를 사용하도록 맞췄다.

## 설치 결과

2026-09-18 21:38 KST, 운영자 관리도구 종료 확인 후 DB 전체 덤프와 파일 백업을 남기고 V0027 및 파일 10개를 적용했다. 기존 145개 테이블의 행 수와 내용 해시는 모두 일치한다. migration 재실행은 0건, 설치 해시 및 실행 bundle/pipeline 연결 검사를 통과했다. 서버 180개, 전체 PostgreSQL 122개, 필수 gate 8개 및 별도 통계 DB 재시작/중복/rollback 검사 통과. 초기 회귀 실패와 fixture 수정은 artifact에 보존했다.

설치 서버 SHA-256: `105c2f5ce0f0dd04b99733a87accc68b2c56038b227d66e5ceb2e1d9b5ebb166`.
설치 이후 새 전투부터 수집한다. 후속 크리스탈 체임버 모의전에서 실제 보고서 저장, 개인별 5명 TAB 일치, 결과창 총 대미지 및 잔여 HP 일치를 확인했다.

### 후속 배포 결함 수정

첫 설치 후 사용자가 `phase_d_preparation_invalid`를 보고했다. materializer는 원래 framework-dependent 설치인데 publish 기본 `SelfContained=true`의 runtimeconfig/deps만 교체하여 `hostpolicy.dll` 결손으로 실행되지 않았다. 단순 파일 hash 검사는 이 결함을 잡지 못했다.

`--self-contained false`로 다시 publish하고 코드 DLL/EXE가 설치본과 동일함을 확인한 뒤 실행 설정 2개 및 bundle/selection/pipeline 핀을 백업·교체했다. 실제 설치 경로로 S26/S41 준비 `ready`, 관리도구의 Windows PowerShell에서도 S26 `ready` 확인. 통계 코드·DB 변경 없음. 후속 영수증: `artifacts/raid-damage-capture-20260918/framework-repair/receipt.json`. 준비 패키징에 framework-dependent 설정 검사 추가. 이후 크리스탈 체임버 실제 전투 통계 수집을 확인했다.
