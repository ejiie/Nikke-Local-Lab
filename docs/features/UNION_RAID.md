# 유니온 레이드 하드

2026-09-17 운영자 요청으로 추가한 범위입니다. 이 확장은 과거 Phase 계약의 "Union Raid 비활성" 인수 범위를
소급해 바꾸지 않습니다. 기준: 2026-09-27 `main`, schema V0028. 작업 원문은 [보관 기록](#보관-기록)에 있습니다.

## 범위

- 관리도구 유니온 탭에서 시즌을 최신순으로 고르고 `시즌 N 보스를 불러오시겠습니까?`에 [예]를 누르면, 그 시즌의
  하드 보스 5개를 원본 행동 트리까지 공통 경로로 조립합니다. [아니오]는 아무것도 바꾸지 않습니다.
- **원본 속성·QTE·FX를 그대로 씁니다.** 솔로의 약점 자유화와 보정 FX 단계를 호출하지 않습니다.
- 로컬 계정은 NLL 유니온(레벨 3 이상) 소속, 노멀 전체 완료 상태로 하드에 접근합니다. 공식 계정·서비스는
  바꾸지 않습니다. 새 노멀 전투와 노멀 연습전은 닫힌 응답을 반환합니다.
- 전투 피해는 원본 클라이언트가 계산한 값을 받아 반영합니다. 별도 전투 시뮬레이터는 없습니다.
- 사격장 전투, 유니온 채팅 전송·운영 기능, 보상 경제는 범위 밖입니다.

## 데이터 경로

```text
UnionRaidManagerTable → MonsterPreset → UnionRaidPresetTable.PresetGroupId → Wave → WaveDataTable
  → target monster → SpotAi 계열 행동 트리
```

- 하드 자료가 있는 시즌은 로컬 152 기준 24~45입니다. 보스 다섯 개라는 이유로 첫 5행을 고르지 않고
  `DifficultyType`, `IsTrial`, `WaveOrder`, `WaveChangeStep`을 구분합니다.
- HP는 선택 manager → Hard preset → wave target → monster stat group → 해당 레벨 HP × 원본 HP 비율로
  계산합니다. 참여 수·편성 수는 `ConfigGameTable`에서 읽고, 하루 경계는 서울 05:00입니다.
- 원본 표와 식별자는 Git 제외 artifacts에만 둡니다. 공개 API·카탈로그에는 원본 ID를 내보내지 않습니다.

## 관리 API 표시 데이터 (2026-10-01 소스)

- 카탈로그의 보스 행은 `weaknessCode`, `imageStatusCode`, `imageSha256`을 가진다. 모든 대상 몬스터의
  원본 속성 → 약점 관계가 같은 한 코드로 해소될 때만 약점을 표시한다. 관계 결손·모호함·불일치는 `null`이며
  표시 정보 때문에 시즌을 실패시키거나 원본 전투 데이터를 바꾸지 않는다.
- hard 프리셋(실전·연습)의 `MonsterImage`가 모두 같은 보스만 `(seasonNumber, order)` 비공개 힌트를 낸다.
  기존 이미지 생성기로 공개 PNG 우선·로컬 bundle 대체를 수행하고, 같은 이름은 한 번만 처리한다.
- `GET /admin-api/v1/union-raid/seasons`의 보스 payload는 `order`, `displayName`, `weaknessCode`, `imageUrl`이다.
  resolved 이미지만 `/admin-api/v1/union-raid/seasons/{season}/bosses/{order}/image?catalog={catalogSha256}`을 반환한다.
  GET은 현재 카탈로그 pin과 이미지 hash·PNG 서명이 맞을 때만 `image/png`를 제공하고, 아니면 404다.
  새 표시 필드가 없는 기존 카탈로그는 약점·URL `null`로 계속 읽는다.
- 설치는 Admin API 앱 배포, materializer 재봉인, 변경 스크립트 배포 및 카탈로그 재동기화가 필요하다.
  카탈로그 hash가 달라지므로 기존 `published/<시즌>-<catalogSha256>` 조립과의 바인딩이 바뀐다.
  기존에 조립한 S45도 다시 불러와야 한다. 화면 변경·설치·실게임 확인은 이 소스 변경에 포함하지 않는다.

## 저장

| migration | 내용 |
|---|---|
| V0024 | `local_union`, `local_union_member`, `local_union_raid_season`. 버전·빌드와 무관한 NLL 소속·선택 시즌·노멀 완료. 신규 계정 자동 가입 trigger |
| V0025 | `local_union_raid_runtime`. HP는 유니온·시즌 공유, 사용 캐릭터·참여·편성·팝업은 계정별. 캐릭터는 논리 UID로 저장 |
| V0026 | 가져온 유니온 등록(외부 ID는 32바이트 지문 `source_fingerprint`로만 대응)과 계정 디렉터리 표시. 가져온 소속을 우선하고 유니온별로 레이드 진행을 분리 |

입장·결과는 유니온 행 잠금과 단일 transaction으로 반영한 뒤 응답합니다. 같은 입장·결과 재전송은 중복 소비·가산하지
않으며, 연습전은 실전 HP·참여·랭킹을 바꾸지 않습니다. 선택 시즌이 바뀐 오래된 실행의 쓰기는 거부합니다.
이 API가 게임 실행 중 관리 DB에 직접 접속하므로 공통 실행기는 DB를 켜 둡니다([실행 수명주기](EXECUTION_LIFECYCLE.md)).

## 코드 위치

| 책임 | 위치 |
|---|---|
| 관리 API | `src/NikkeLocalLab.Admin.Api/UnionRaid.cs` (`/admin-api/v1/union-raid/seasons`, `/jobs`) |
| UI | `wwwroot/editor/union-raid.js` |
| 시즌 목록·조립 | `scripts/sync-nll-union-raid-catalog.ps1`, `scripts/assemble-nll-union-raid.py`, `scripts/invoke-nll-union-raid-job.ps1`, materializer `UnionRaidCatalog.cs`, `LocalUnionProjection.cs` |
| Epinel 서버 | `patches/epinel-local-union-hard.patch`: `/guild/unionraid/*` 21개 경로, `/shootingrange/v2/get`, `/user/getcontentsdata`의 `GuildLevel`, 캐릭터 레벨 상한 1200 |

요청 경로는 152 protobuf 요청 선언의 `Path` 주석과 대조했습니다. 연습 결과 주소의 `pratice` 철자도 원본 그대로입니다.

## 확인 상태

- 2026-09-18 운영자 확인: 싱크로 레벨 상한 1200과 유니온 레이드 개방·진입이 정상입니다.
- 남은 운영자 확인: 하드 보스 선택 → 편성 → 입장 → 완료/중도 종료 → 남은 HP·횟수 → 기록·랭킹 → 재실행 복원 →
  연습전이 실전 상태를 바꾸지 않는지.
- 관리도구 유니온 탭의 보스별 기록 패널은 아직 연결하지 않았습니다(기록 API는 유니온도 지원,
  [레이드 기록](RAID_RECORDS.md)).

## 보관 기록

- [구현·결함 수정·설치 기록](../archive/union/UNION_RAID_HARD_IMPLEMENTATION.md)
- [유니온 중심 계정 UI](../archive/union/UNION_ACCOUNT_WORKSPACE.md)
