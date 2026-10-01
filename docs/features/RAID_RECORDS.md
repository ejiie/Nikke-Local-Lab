# 레이드 기록·딜표·BattleLog 분석

기준: 2026-09-27 `main`, schema V0028. BattleLog 필드 해설은 [BattleLog 참고 자료](../reference/battlelog/BATTLE_LOG_GUIDE.md),
작업 원문은 [보관 기록](#보관-기록)에 있습니다.

## 수집 범위

| mode | 원본 경로 | 비고 |
|---|---|---|
| `solo_challenge` | 솔로 Challenge 실전 결과 | 덱 결과 접수 receipt를 먼저 영속화하고 PostgreSQL로 재시도 투영 |
| `solo_challenge_practice` | `/soloraid/practice/setdamage` | 2026-09-20 운영자 요청으로 추가. 결과 계산·일일 참여 규칙은 바꾸지 않음 |
| `union_hard`, `union_hard_practice` | 유니온 하드 실전·연습 결과 | 유니온 진행 자료와 같은 DB transaction |

숫자 통계와 BattleLog 저장이 실패해도 전투 결과 처리와 응답은 중단하지 않습니다. Normal/Museum 전투나
공식 서버 연결을 추가하는 범위가 아닙니다.

## 확정 공식

2026-09-18 운영자가 확정했으며 추가 실게임 재검증을 요구하지 않습니다.

```text
캐릭터별 TAB 딜표        = Characters[i].Attack.TotalDamage
결과창 총 대미지          = Σ TAB 딜표 + Σ Monsters[j].Hp.TotalPartsDestroyDamageReceived
                                        − Σ Monsters[j].Hp.TotalProjectileDamageReceived
개인 투사체 제외 피해     = 캐릭터 TAB 딜표 − 그 캐릭터가 적 투사체에 가한 피해
```

- `Skill.TotalDamage`·`StatFunctionAttack.TotalDamage`를 TAB 값에 더하지 않습니다. 비교용으로 따로 보존합니다.
- 결과창 값은 `request_damage`, 서버 승인 값은 `accepted_damage`로 각각 저장합니다.
- 파츠 파괴 추가 피해를 캐릭터에게 배분하지 않습니다. 귀속하지 못한 투사체 피해를 비례 배분하거나 0으로 채우지 않습니다.

## 저장

| 위치 | 내용 |
|---|---|
| V0027 `raid_battle_observation` / `raid_character_damage` / `raid_monster_damage` | 전투 UUID 부모와 캐릭터·몬스터 원값. 편성 ordinal과 로컬 캐릭터 UUID로 연결 |
| V0028 `raid_projectile_analysis` / `raid_character_projectile_damage` | 규칙 `projectile-damage/v1`의 개인별 차감값. 기존 `(battle_uid, ordinal)` 딜표를 FK로 참조 |
| `C:\ProgramData\NikkeLocalLab\BattleLogs\<accountUid>\<battleUid>.private.bin` + private JSON | BattleLog 원문과 hash·전투 문맥. 건당 8MiB, 해제 32MiB·200만 레코드 제한. 자동 삭제 없음 |
| `C:\ProgramData\NikkeLocalLab\BattleAnalysis\damage-composition-v3\...` | 피해 구성 분석 캐시. 원문·카탈로그 hash가 같으면 재사용 |

원본 게임 ID는 decoder의 비공개 입력에만 있고 DB·API에는 관측 ordinal과 로컬 UID만 씁니다. 분석 규칙이 바뀌면
새 버전으로 따로 저장하며 기존 행·캐시를 덮어쓰지 않습니다. 원문·실계정 통계·분석 파일은 커밋하지 않습니다.

## 조회와 화면

- `GET /admin-api/v1/accounts/{accountUid}/raid-records`: 계정·시즌·레이드 종류·보스 순번·실전/모의전·약점으로
  SQL에서 제한하고, 시각+전투 UID cursor로 100건씩 조회합니다. 피해량은 JSON 문자열입니다.
- `kind=union&mode=all`은 하드 실전·연습을 함께 최신순으로 조회한다(2026-10-01 소스).
  각 행의 `mode`는 실제 `live`/`practice`를 유지하고 두 모드에 같은 시각+전투 UID cursor를 적용한다.
  계정·시즌·보스·약점 필터는 유지하며, 약점 구분 없는 조회는 `weakness=all`이다. `kind=solo&mode=all`은 400이다.
- `GET /admin-api/v1/accounts/{accountUid}/raid-records/{battleUid}/composition`: 캐릭터별 피해 구성(`damage-composition/v3`).
  다른 계정의 전투는 404입니다. 최초 열람 때 분석하며 동시 분석 1개, 대기 30초 제한입니다.
- UI: 솔로 보스 오른쪽 기록 패널(`wwwroot/editor/raid-records.js`), 상세 분석 페이지(`raid-analysis.js`).
  개인딜 기본값은 투사체 제외 피해이고 분석값이 없으면 "분석값 없음"으로 표시합니다.
- 피해 구성 분류: 평타, 교체 무기, 자동 무기, 스킬 직접 피해, 스킬 효과 피해, 미분류. `효과별로 보기`로 개별 효과를
  나눕니다. 피해가 정확히 0인 효과는 숨기지만 합계는 바꾸지 않습니다.

코드: `RaidRecordEndpoints.cs`, Persistence `RaidRecordStore.cs`·`RaidCompositionStore.cs`, decoder
`tools/Phase3B2/BattleLogAnalysis/`, 서버 수집 `tools/Phase3B2/EpinelBattleStatistics/`,
`patches/epinel-raid-damage-capture.patch`, `patches/epinel-solo-practice-analytics.patch`.

## 남은 작업

1. 타임라인 화면은 준비 중 표시만 있습니다. 행동 시간표(사격·교체·스킬·버프·재장전·피격)를 연결해야 합니다.
2. 크리·코어·사거리 판정별 집계, 다단히트/샷건 묶음, 본인 참여·미참여 풀버스트 구간 분석.
3. 결과 수신 시 동기 분석 대신 복구 가능한 작업 큐, 원문 보존 용량·정리 정책.
4. 같은 보스의 시즌 간 통합 조회, 계정 간 비교(초기 범위에서 분리한 후속 항목).

지표 의미와 단계별 완료 조건의 원문은 [통계 구현 계획](../archive/raid-records/RAID_ANALYTICS_IMPLEMENTATION_PLAN.md)
3~5절입니다. 기존 로그 4건·20명은 분류 합계가 투사체 제외 피해와 일치했지만, 미래 로그의 미분류 0을 보장하지 않습니다.

## 남은 확인

- 새 서버에서 솔로 모의전을 완주했을 때 새 덱·5명 통계·원문 저장이 되는지(운영자 확인 전).
- 피해 구성 v3 화면(효과별 보기·비중 막대)의 운영자 화면 확인.

## 보관 기록

- [원자료 수집·공식 확정](../archive/raid-records/RAID_DAMAGE_CAPTURE.md),
  [실제 기록 연결·초상화](../archive/raid-records/RAID_RECORDS_LIVE.md),
  [캐릭터별 피해 구성 v1~v3](../archive/raid-records/RAID_DAMAGE_COMPOSITION.md)
- [통계 구현 계획](../archive/raid-records/RAID_ANALYTICS_IMPLEMENTATION_PLAN.md),
  [UI 초안](../archive/raid-records/RAID_RECORDS_UI_PROTOTYPE.md),
  [솔로 레이드 영속화·분석 초기 설계](../archive/raid-records/SOLO_RAID_PERSISTENCE_AND_ANALYTICS.md)
