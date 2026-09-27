# 실행 간 영속화 P-01~P-09

상태: 2026-09-12 구현·전체 자동 검사·운영 DB/앱/v6 배포 완료.
정상 UAC 승격 후 설치 API smoke까지 완료했고, 같은 날 운영자가 "확인 완료"로 실게임 인수를 보고했다.
이는 운영자 확인이며 agent가 새 actual-play receipt를 수집하거나 모든 조합을 자동 검증했다는 뜻은 아니다.
요구의 권위는 [안정화 계획](../STABILIZATION_PLAN.md)이다.

## 범위와 순서

1. P-01/P-05: 덱별 접수 이력과 선택 약점별 저장·조회·복원.
2. P-04: 전투하지 않은 편성까지 보존.
3. P-02/P-03/P-06~P-09: 승인된 계정 설정만 보존.
4. 합성 행동/폐기 PostgreSQL/외부 서버·materializer 왕복 검사, 배포 준비와 실게임 안내.

## 저장 계약

- 2026-09-17 정정: 기록 범위는 account + 시즌 + 선택 약점이다.
  snapshot/build/executable은 각 저장 revision의 출처이며 기록을 분리하는 키가 아니다.
  실전과 모의전은 그 안에서 분리한다. 최고점은 실전 5덱 완주의 strict improvement만 인정한다.
- 로비 Quit은 0~4덱이면 완주로 인정하지 않지만 참여 기회는 소모한다.
  5덱 완료는 완주 1회와 참여 기회 1회다. Open에서 소모한 횟수를 Quit에서 환급하거나 재차 소모하지 않는다.
- 덱 결과는 정상 접수 transaction에서 run UID/ordinal/시각과 구성 snapshot을 내구성 있게
  기록한다. Quit·하위 완주·일일 초기화는 이력을 삭제하지 않는다. 동일 요청 재전송은 중복 생성하지 않는다.
- 기존 약점 없는 기록은 `unresolved`에 그대로 남긴다. 현재 선택이나 기본 약점을 소급 대입하지 않는다.
  근거 있는 이관만 별도 provenance와 새 revision으로 허용한다. 현재 약점 조회는 unresolved를 숨기지만
  삭제하지 않는다. 클라이언트 버전 전환은 같은 논리 head를 이어 쓰며 약점은 계속 분리한다.
- 편성은 계정+원본 SoloRaid 팀 타입(실전/모의전 공용)이며 보스·약점 사이에서 재사용한다. 명시적 빈 슬롯도 값이다.
  캐릭터는 local UID로 보존하고 materialize 때 현재 Csn으로 해소한다. 진행 run의 사용 제한과 별개다.
- 착용/로비/BGM/프로필/알림은 계정별 별도 설정 revision이다. 게임의 빌드 수정은 회수하지 않는다.
  관리도구 Save는 설정을 덮어쓰지 않는다. Save As는 새 계정이므로 이력·진행 run·알림 확인·
  설정을 암묵 복사하지 않고 새 계정 baseline에서 시작한다.
- 실행 준비 때 설정 head를 pin하고 종료 회수는 CAS로 저장한다. 충돌은 보존·격리하며 최신 head로
  자동 재시도하지 않는다. 이전에 성공한 저장의 exact replay는 같은 결과를 반환한다.
- DB 전체를 복사하지 않고 승인된 필드만 별도 payload에 넣는다. 원본 참조는 Git-external 보호된
  compatibility payload 안에서만 사용하고 public key/API/log에는 노출하지 않는다.
- 종료·orphan recovery는 rollback 전에 pending을 보존하고 PG 재시작 뒤 저장한다.
  실제 게임 실행 중 PG를 켜거나 새 진단 HTTP/게임 DLL 변경을 전제로 삼지 않는다.

## 완료 체크

- [x] 최고점 150 유지, 하위 100 완주와 61 Quit 포함 My Records 16건/역순 — 합성 검사
- [x] 철갑 150/수냉 100의 최고점·이력·open run 격리, legacy unresolved 보존
- [x] 재전송·재기동·Quit·일일 경계·회수 실패/복구·CAS 충돌
- [x] 편성 01~05/빈 슬롯/마지막 팀, 현재 Csn 재매핑과 과거 snapshot 불변
- [x] P-02/P-03/P-06~P-09 승인 필드 왕복, 새 알림/타계정 키 격리
- [x] 전체 자동 검사, 운영 반영의 before/after hash·backup, 실게임 안내
- [x] 설치 후 관리자 호스트 API smoke — UAC 승인 후 성공 및 정상 종료 receipt 확인
- [x] 운영자 원본 게임 인수 — 2026-09-12 운영자 확인

CI의 기존 Linux S-08 self-test 실패는 별도 후속 작업에서 수정하여 PR #13으로 병합했다.
자세한 검증 근거는 [GitHub 운영 문서](../operations/GITHUB_AUTOMATION.md)를 따른다.

## 구현과 검증 근거

- V0023과 버전 독립 저장·로비 Quit 수정의 진행 및 근거는
  [2026-09-17 정비 기록](../operations/VERSION_INDEPENDENT_RUNTIME_PERSISTENCE.md)을 따른다.
  아래 V0019~V0021과 2026-09-12 배포 기록은 당시 이력이다.
- V0019: 선택 약점 5종 + legacy `unresolved`를 저장 키에 추가한다. 기존 암호문/AAD/operation
  replay는 v1 경로로 유지한다. 기존 무약점 기록을 현재 선택에 붙이는 자동 이관은 하지 않는다.
- V0020: 계정+client build/hash별 설정 head/revision/terminal operation. 설정 CAS 충돌은
  암호화 payload와 함께 격리한다. raid/prefs 중 하나만 저장된 경우에도 exact replay로 복구한다.
- V0021: 전체 이력의 기존 1MiB 제한을 64MiB로 늘린다. 무제한 저장을 주장하지 않는다.
  각 revision은 전체 이력 snapshot이며 한도 초과 시 과거 덱을 삭제하지 않고 완료를 거절한다.
  보호된 pending을 남기므로 수동 삭제하지 않는다. 설정 envelope 제한은 16MiB다.
- 외부 변경: `patches/epinel-runtime-persistence.patch` 및 LF 정규화 before/after manifest 21개.
  기존 151/ranking/약점/일일 초기화 변경은 유지하며 이번 변경만 별도 patch로 남긴다.
  서버 DB는 접수 transaction의 write-through/flush/원자 교체 뒤에만 결과를 공개한다.
- 원본 BGM은 LobbyMusic/CommanderMusic 각각 선택한 단일 곡을 대상으로 한다.
  즐겨찾기·playlist 컬렉션의 편집/이관은 범위 밖이다. 프로필 장식은 실제 저장/조회에 쓰이는
  `ProfileCardDecoration`을 보존한다. 소유 목록·재화·진행도는 설정으로 덮어쓰지 않는다.
- 외부 서버 **142개**, materializer 설정 합성 **32개**, 실제 Capture/Persist/Restore 합성 **41개**,
  격리 PG 전체 **114개**가 통과했다. PG `373d9886b2ab4e3e9d181c85765fa3da`는
  schema 21, stop/restart checkpoint와 최종 정리를 포함한다.
- v6 pin 기반 S06 행동 **21개**와 제조사/큐브 두 변이 거절:
  `59c063861b6d4f4a8891cfa68c24a51f`. 원본 게임 실행 증거가 아니다.
- 배포 전 cold backup `4814771603a843f58b59ac7351768b02`: schema 18, Save operation 105개,
  pending/검사 불일치 0개. 원본 2,204파일·91,788,843byte 불변 확인.
  복제 migration `efea2f50dd224db88d881f3cc853478e`: schema 18→21,
  모든 기존 application table의 행 수/내용 지문 불변, legacy unresolved, 새 설정 table 빈 상태 확인.

### 최종 운영 반영 — 2026-09-12

- 제품 코드 `debc6e7336950cc8a0bd9abfa8b31914277a5f21`을 agent branch에 commit했다.
  이번 작업에서 새 push/PR/merge 및 보류된 Linux CI 수정을 하지 않았다.
- 전체 verification `b7453b2bb1804f83a656a0bfcf8b554e`: 모든 gate exit 0.
  단위 486개, PG 114개(기존 1MiB를 넘는 payload/replay 포함), 실제 왕복 41개, 설정 합성 32개.
  PG `8134fb55de044c7d8a888b7478e36e6a`의 stop/restart checkpoint와 최종 종료도 통과했다.
- 실제 계정 백업 복제본의 S26 철갑/수냉 v6 `ValidateOnly` 및 설정 Capture가 통과했다.
  진행도를 유지했으며 원본 게임·운영 DB를 사용하지 않았다. private 검사 위치는
  `C:\NLL\Staging\PersistencePreparation-77c368ee5fe4498993a04351ed5078fa`다.
- 최종 commit rehearsal `55232d2d395a444980faeef819e9c352`와 동일한 CLI 파일 pin으로
  운영 migration `61f4dae2c7ee428bb973b3b7496784cf`를 완료했다. schema 18→21,
  모든 기존 application table의 행 수/내용 지문 불변, legacy unresolved, 새 설정 0행, PG 정상 종료.
  앞선 병렬 rehearsal 한 번은 다른 검사 프로세스로 인해 최종 cold 게이트가 거절되어 승인 근거로 사용하지 않았다.
- 전환 후 cold 감사/backup `dd0476aa1095480ead51281bb86f8854`: schema 21,
  Save operation 105개, pending/기존 및 새 설정의 head·lineage·payload 검사 불일치 0개.
- 앱 배포 `833a8d579da24861bfceff222dbb898f`: 34개 파일을 backup·before/after hash 검증 후 교체.
  manifest SHA-256 `3d2eb509a5f5b7a9a4d6bf16a97446658b851c26767ef3d4c32c46c2741c4150`.
  같은 package의 `runtime-activation.receipt.json`은 v6 포인터 원자 교체 완료를 기록한다.
  v5·원본 client·기존 native/인증서/방화벽은 보존했다.
- 설치 API smoke 첫 시도는 `control_center_start_boundary_invalid`로 bootstrap 전에 종료했다.
  이 시도는 정상 시작/종료 검증 성공이 아니며 앱/PG/게임 시작 전의 관리자 권한 거절이다.
  `installed-smoke.non-elevated.receipt.json`에 보존했다. 이후 첫 UAC 요청은 취소됐으며,
  운영자가 재요청을 승인한 뒤 기존 UAC `RunAs` 경로로 점검을 완료했다.
- 설치 smoke 완료 시각은 `2026-09-12T01:41:39.5350733Z`(10:41 KST)다.
  같은 package의 `installed-smoke.receipt.json`에서 `passed=true` 및
  `safeHostStopVerified=true`를 확인했다. 계정·workspace 각 3개, editor·로컬 bootstrap 조회가
  통과했고 목록 3회는 232.4065/5.2528/2.5565ms였다. 원본 게임·WebView UI·Save/import는
  요청하지 않았으며 앱/PG는 정상 종료했다. 관리자 권한 게이트는 완화하거나 우회하지 않았다.

## 운영 배포 절차

1. `prepare-nll-runtime-persistence-bundle.ps1`로 v5의 파일 pin을 검증하고 새 v6만 준비한다.
   현재 준비된 v6 manifest SHA-256은
   `148ea9ae3e6a5759fd5075c7e25a2860331affc5644043a20a2869afcff8c9db`다.
   client/native/인증서/firewall은 바꾸지 않는다. v5와 암호화 원본 DB를 복사한 runtime을 만들지 않는다.
2. 소스를 agent branch에 commit한 뒤 `verify-nll-stabilization.ps1 -RuntimeMaterializerPath ...`
   로 전체 gate와 실 Capture/Persist/Restore를 검증한다.
3. `prepare-nll-workspace-cold-backup.ps1 -AuditCurrent`로 cold backup을 만든다.
   `update-nll-runtime-persistence-database.ps1 -AuditUid ...`로 복제 rehearsal 후,
   같은 commit·CLI 파일 pin·backup·최종 verification에 묶인 `-Apply`만 허용한다.
4. schema 21 cold 감사 후 `publish-nll-stabilization-release.ps1`의 Prepare/Apply로 앱을 교체한다.
   이 앱 배포기는 migration 자체를 실행하지 않는다.
5. `activate-nll-runtime-persistence.ps1`로 cold 상태의 선택 포인터만 원자 교체한다.
   새 앱·DB·parent pin이 모두 맞아야 한다. `test-nll-stabilization-installed.ps1`로 로컬 API smoke 후 종료한다.

백업은 `D:\NikkeLocalLab\Backups`의 전용 private directory에 보존한다. schema 21에서
옛 앱은 migration history를 거절하므로 포인터만 v5로 되돌리는 것은 전체 rollback이 아니다.
장애 시 모든 runtime을 종료하고 해당 시점 DB·앱·실행 스크립트·포인터의 세트를 검토한다.
자동 DB 파일 복원이나 기존 pending 삭제는 하지 않는다.

## 운영자가 실게임에서 확인할 것

이번 변경 이후 생성한 기록으로 확인한다. 이전 무약점 기록은 삭제되지 않았지만 어느 약점의
기록인지 증명할 수 없어 새 약점별 화면에는 합치지 않는다. 숫자는 예시이며 정확히 맞출 필요는 없다.

1. **이력과 최고점:** 한 약점에서 실전 5덱 완주 → 더 높은 5덱 완주 → 더 낮은 5덱 완주 →
   1~4덱 후 메인 화면 Quit. 최고점은 높은 완주만 유지되고 My Records에는 낮은 완주와
   Quit 전 덱까지 최근순으로 남아야 한다. 게임 종료 후 관리도구의 회수 완료를 기다렸다가 재실행한다.
2. **약점/모의전:** 다른 약점에서 기록을 만든 후 원래 약점으로 돌아온다. 최고점·진행 run·이력이
   섞이지 않아야 한다. 모의전 결과가 실전 최고점을 바꾸면 안 된다.
3. **편성:** 01~05 모두 다르게 편성하고 빈 칸도 만든다. 한 팀만 전투하거나 전투 없이 종료한 후
   재실행해 순서·빈 칸·마지막 팀을 확인한다. 같은 계정의 다른 약점에서도 편성은 공유한다.
4. **설정:** 잠금 해제 연출을 확인하고 코스튬·로비 배경·로비/지휘관실의 서로 다른 단일 BGM·
   아이콘/프리즘/프레임/칭호/프로필 카드 배치를 바꾼다. 알림 일부만 확인하고 재실행한다.
   선택값과 확인한 알림은 유지되며 다른 미확인/새 알림은 남아야 한다.
5. **계정/프로필 저장:** 관리도구에서 같은 계정 빌드를 Save한 뒤 재실행한다. 위 설정과 과거 이력은
   유지돼야 한다. Save As의 새 계정에는 원 계정의 설정/기록/진행 run이 암묵 복사되지 않아야 한다.
   빌드가 바뀌어 진행 run이 닫혀도 이미 접수한 덱 이력은 남아야 한다.

OS 강제 종료·파일 삭제·pending 변조로 테스트하지 않는다. 자동 검사는 실패·재전송·CAS·05:00
일일 경계와 counter 0인 open run의 profile 변경을 포함한다. 실제 UI/전투 표현의 인수는 위 확인과 구분한다.
