# 작업 인계

최종 갱신: 2026-09-12. 이 문서는 짧은 현황 요약이며, 상세 기록을 계속 덧붙이는 로그가 아닙니다.
작업 전 읽기 순서·불변 규칙은 [AGENTS](../AGENTS.md), 문서 위치는 [색인](README.md)을 따릅니다.

## 확인된 현재 상태

- 운영자가 관리도구 → **151 / S26 실게임 검증 완료**를 확인했습니다. 리소스 대응은 종료했습니다.
- 기존 진행도를 유지합니다. 과거 약점 없는 최고 기록은 삭제하지 않고 `unresolved`에 보존하며,
  새 약점별 기록에 추정 병합하지 않습니다.
- 검증된 Epinel DLL·실행 조합을 불필요하게 다시 변경하지 않습니다.
- 활성 OS는 Micron입니다. 저장소·client·bundle·백업의 정확한 위치는 [현재 경로](MICRON_CURRENT_PATHS.md)만 기준으로 합니다.
- 위 완료는 운영자의 실게임 확인이며, 새 자동 관측 receipt나 모든 보스·음성·약점 조합의 검증을 뜻하지 않습니다.

## 지금 할 작업

### 2026-09-12 실행별 FX HTTP 전달 모듈

실행별 독립 FX 사본/봉인 → 정확한 raw 경로 HTTP 전체·range·HEAD 응답 → 사용 중 정리
차단 → 종료 후 private 사본만 정리·재시도를 구현했다. 기존 후보를 소비할 때는 전체
discovery/behavior/5속성/FX를 재검증하며, 같은 bundle의 중복 cache 경로는 거부한다.
신규 staging 합성 9개·.NET 19개와 실제 151 S29 보정 FX 3종 HTTP/정리 검사가 통과했다.
로컬 receipt는 `artifacts/execution-fx-checks/213e97bb4e134b7abd48eb11a9be9ad6/receipt.json`이다.
검사 중 만든 사본 6개만 지웠으며 후보에서 새 실행 폴더로 다시 생성할 수 있다.
설치 v6 96개 pin·registry/profile·운영 DB/게임은 불변이고 S29 차단도 유지한다.
**완료는 전달 모듈/사본 정리이며 설치 Epinel 연결·원본 client 수신/표시 완료가 아니다.**
다음은 새 외부 Epinel 후보의 source-link/startup 연결, coordinator의 전체 process-tree 종료
gate와 정리 결박, 원본 client 캐시/catalog/CRC 조사다. HTTP `no-store`만으로 native cache
우회를 주장하지 않는다. 비정상 종료 후 남은 `.lease`는 PID만 보고 자동 제거하지 않는다.
그 후 v3 admission·원자적 게시/job API·시즌 선택 UI를 진행한다. 아래 절의 ‘다음 작업’은
당시 이력이며 상세한 현재 경계는 [보스 파이프라인](features/BOSS_ONBOARDING_PIPELINE.md)을 따른다.

### 2026-09-12 공통 v3 후보 자동 조립

`invoke-nll-boss-onboarding.ps1 -CandidateOnly`로 새 discovery/원본 행동 트리 → QTE 포함
v3 조립 → 격리 FX 3종 → 5속성 검증 → 최종 후보 봉인을 연결했다. S26의 no-QTE v2
후보도 같은 경로로 통과한다. 합성 12개에는 실제 PowerShell 호출의 중간 실패·QTE/FX
변조·입력 drift·재시도·중복 폴더 거부·등록 불변·private 임시 파일 정리를 포함한다.
실제 151/v6 입력 S29/S26 10개 속성 검사는
`artifacts/boss-onboarding-checks/91e8c23bd7b546d09aeec5877741c756/receipt.json`에 있다.
Windows 임시 파일 핸들 문제를 byte-backed FX reader로 수정했고, 기존 기대 해시 3종 및
복구 2회도 `16cad47968eb456d940758d3d2e30748` 검사에서 재현했다.
로컬 단위 486개, 저장소/Phase 0/완료된 2A1·2A2·2B/역사 3A·3B0·3B1/3B2/약점/Actions
검사와 Python 46개(신규 후보 12·기존 QTE 4·FX 29·Git 1)가 통과했다. 로컬 운영 PG는
시작하지 않았으며 CI의 격리 PG 결과는 해당 source commit의 Actions에서 따로 확인한다.
후보 상태는 `verified_candidate_pending_runtime_delivery`, 실행 admission은 `not_assessed`다.
**다음 작업은 원본 client FX 전달과 실행별 rollback/정리**이며 이후 v3 실행 admission,
원자적 게시/job API, 시즌 선택/팝업 UI가 남는다. S29 등록 pin과 실행 차단, 설치 v6 96개
pin, 운영 DB/게임은 바꾸지 않았다. 아래 QTE/FX 절의 ‘v3 조립 남음’은 과거 단계 이력이다.
상세와 재현 명령은 [보스 파이프라인](features/BOSS_ONBOARDING_PIPELINE.md)을 따른다.

### 2026-09-12 S29 격리 FX 후보/복구

공유 캐시와 분리된 새 폴더에 v3 프로필의 FX 3종을 생성·봉인하고 후보 내부만 복구하는
도구를 추가했다. Transform의 위치/회전/크기 외 필드와 매칭되지 않은 객체도 보존한다.
합성 FX 29개, 임시 Git 병합 1개 및 실제 151 입력 FX 3종의 기대 해시 재현·검증·복구
2회·복구 후 후보 검증 거부가 통과했다. 증빙은 `artifacts/shield-fx-checks/`에만 보존한다.
이전 `8427082`의 CI 실패는 Windows/Linux 모두 임시 merge의 Git identity 결손이었다.
두 명령에만 bot identity를 지정하고 원본 없는 Python 검사를 양쪽 CI에 추가했다.
**완료 범위는 FX 후보 생성/복구이며 v3 자동 조립·client 전달·설치 rollback·S29 admission·
UI는 남아 있다.** 현재 v6 96개 pin, 프로필/registry pin, 운영 DB와 게임을 변경하지 않았다.
다음은 공통 v3 후보 조립에 이 FX 검증을 연결하고, 공유 cache junction을 수정하지 않는
실제 전달 경로를 검증하는 것이다. 실행별 정리/복구와 admission을 갖추기 전에는 활성화하지 않는다.

### 2026-09-12 S29/QTE 공통 변환 1차

S29 수정과 공통 파이프라인 개선에 착수했다. QTE의 대상 행만 보스 속성과 함께 바꾸고
원본 패턴·시간·다른 행을 보존하는 v3 변환 및 재패킹 검사를 추가했다. 합성 37개·Python
4개·151 입력의 S26/S29 각 5약점 왕복 검사가 통과했다. 구형 프로필의 QTE 누락과 v2
assembler의 거짓 완료를 차단한다. **v3 자동 조립·격리 FX 전달/복구·실행 admission은 남아
있으며 S29 전체 완료가 아니다.** 설치 v6/registry pin/운영 DB/게임은 변경하지 않았다.
위 다음 단계의 진척은 최신 격리 FX 후보 절을 따른다. client 전달과 v3 자동 조립은 남아 있다.
UI TODO에는 미처리 보스의 예/아니오 확인, 예 즉시 닫기·처리·성공 후 완료 팝업, 아니오
닫기만 하기, 실패/중복 요청 구분을 추가했다. [현행 작업표](STABILIZATION_PLAN.md)와
[재현 검사](features/BOSS_ONBOARDING_PIPELINE.md)를 따른다.

### 2026-09-12 GitHub 복구 및 150 보관

운영자는 영속화 실게임 검증과 병행하여 GitHub 문제 해결과 150의 D: 이동을 요청했다.
GitHub는 Linux S-08의 process identity 대조를 수정한 `46b2d84`로 복구했다.
Windows 전체·Linux S-08·PostgreSQL 114개와 자동 게시가 통과했고 PR #13이
`7e59e06`으로 squash merge됐다. private 및 owner-only 검증/게시 경계는 유지했다.
150은 **D: 보관 및 C: 원본 제거 완료**다. 운영자의 검증 완료·제거 승인 후 cold 상태와
양쪽 39,504개 파일의 전체 manifest 일치를 재검증하여 2026-09-12 12:42 KST에 제거했다.
D: 보관본, 151/v6 선택·파일 pin, 운영 DB와 독립 복구용 큐브 번역 입력 2개는 보존했다.
`retirement.receipt.json`은 `archived_source_removed`다. 정확한 경로·상태·복원 조건은
[150 보관 절차](operations/CLIENT_150_ARCHIVE.md)를 따른다.

### 2026-09-12 실행 간 영속화

P-01/P-05, P-04, P-02/P-03/P-06~P-09 구현과 자동 검증·운영 DB/앱/v6 배포를 완료했다.
코드 `debc6e7`, 전체 검사 `b7453b2bb1804f83a656a0bfcf8b554e`: 단위 486개·PG 114개 통과.
운영자가 재요청한 정상 UAC 승격 후 설치 API smoke도 통과했다(2026-09-12 10:41 KST).
계정·workspace 각 3개, editor·로컬 bootstrap 조회와 앱/PG 정상 종료를 확인했다.
agent의 구현·자동 검증·배포 작업은 완료다. 같은 날 운영자가 "확인 완료"로 새 실게임 인수를 보고했다.
이는 운영자 확인이며 새 자동 actual-play receipt나 모든 조합의 자동 검증을 뜻하지 않는다.
범위·호환 정책·검사/배포 절차·실게임 체크는 [영속화 문서](features/RUNTIME_PERSISTENCE.md)에 모았다.
아래 안정화 인수와 schema 18 배포는 이전 작업의 완료 이력이며 새 영속화 인수가 아니다.

### 2026-09-12 안정화 인수 완료 및 소스 게시

운영자 요청은 직접 하는 실 테스트를 제외한 안정화 후속 완료다. revision readiness의
256개 bounded cache, desktop pipe/async 예외·정상 종료 확인, 준비/완료/pg_ctl 자식의
기한·사전 identity reservation·복구 admission, automation reparse 경계를 보강했다.
운영 DB는 cold-copy에서 감사하며 행 삭제·추정 복원·새 migration을 하지 않는다.
**제품 소스 `1cf8784`의 전체 검사·설치 반영·설치 API smoke를 완료**했다.
운영자가 6단계 실 테스트에 대해 "모두 정상 동작을 확인했다"고 보고하여 이번 안정화의
WebView2 조작·저장·재시작·151/S26 Challenge·종료 후 재실행 인수를 완료했다.
이는 운영자 확인이며 agent가 새 actual-play receipt를 수집했다는 뜻이 아니다.

- 최종 검증 `7ed9a463711d42b9aff415860bcf3b9b`: 단위 **486개**, 격리 PostgreSQL **112개**,
  저장소·Phase 0·완료된 Phase 2A1/2A2/2B·역사 Phase 3A·3B0/3B1/3B2·약점·Actions 계약,
  전체 solution 서식과 desktop build를 통과했다. PG receipt는
  `e54a18ea708542fb9eee7e4d4b4669eb`이며 stop/restart checkpoint·최종 정리도 통과했다.
- 배포 `697effd6d6c64f478b4224bf3f53193c`: 앱 31개·desktop 3개·Start 스크립트 1개를
  before/after hash 검증 후 교체했다. 설치 전용 asset·의존 외부 DLL은 보존했다.
  manifest SHA-256은 `ff1beb42110f3239375cff76cbdd61a3accc7d1253052b9e9c23f3fcbee42c80`이다.
  검증한 이전 파일은 아래 cold backup의 `app-release-697effd6d6c64f478b4224bf3f53193c`에 있다.
  이 백업은 해당 앱 파일 복원용이며 별도 저장소 실행 스크립트까지 자동 복원하는 전체 rollback은 아니다.
- 설치 API smoke: **계정 2개·workspace 2개·editor·로컬 bootstrap·정상 종료 통과**.
  목록 3회 wall time은 185.165/5.523/2.380ms였다. Save/import·WebView UI·게임 요청은 하지 않았다.
  앞선 점검 2회는 로그 공유 읽기 충돌로 조회 전에 실패했고 각각 안전 종료했다. 실패 receipt를
  보존했으며 점검기의 `FileShare.ReadWrite`·64KiB 한계와 controlled 진단으로 수정한 뒤 재검증했다.
  공유 상태 65개와 배포/점검기 파일 행동 21개가 통과했다. 후속 변경은 점검기·그 합성 검사·문서뿐이다.
  원본 게임 DLL/클라이언트·선택 설정·DB migration/행은 변경하지 않았다. 앱 smoke의 정상 PG
  시작/종료는 내부 WAL/통계 파일을 바꿀 수 있으므로 DB 물리 byte 불변 주장은 배포 단계까지만 적용한다.

- 반복 읽기 전체 8셀·7,200개 관측 통과: `92a2edc3d6da46bba862ada01b481e77`.
  R50/H10에서 계정 1/10/50/100개의 HTTP 목록 p50은 1.15/1.24/1.55/1.82ms,
  목록+로비는 2.25/3.42/9.80/18.19ms였다. 합성 데이터·warm 반복 측정이며 앱 첫 실행 시간은 아니다.
- headless Edge DOM 6회 통과: `75faa8cefe4f42b89ff0a39d853b33b3`.
  설치 WebView2나 원본 게임을 실행한 증거가 아니다.
- 1/10계정의 새 프로세스 첫 요청 120회 통과: `203c935721fe45f3b0bf7563f8213bed`.
  오류·timeout 0개다. 프로세스 시작과 요청 시간을 분리했으며 OS cache를 비우지 않았다.
  위 warm/DOM/cold 모두 격리 PostgreSQL의 stop/restart checkpoint와 최종 정리를 확인했다.
- 배포 전 운영 DB cold-copy 감사 `cb9ea3de443649e7ba92fd3153073f7b` 통과:
  schema 18, migration checksum 일치, Save operation 102개, DB/암호화 pending 0개,
  검사한 head·lineage·결과 소유권·provenance·암호화 payload hash 불일치 0개다.
  원본 DB 2,203개 파일 / 90,992,840byte를 전후 hash 대조했고 원본을 시작·수정하지 않았다.
  복제본은 정상 종료했고 `D:\NikkeLocalLab\Backups\stabilization-audit-cb9ea3de443649e7ba92fd3153073f7b`
  아래 검증된 private cold backup은 보존했다.
- 설치 smoke 후 동일 감사 `912d47e8331645abb69eefb14e2cbef1`도 통과했다.
  schema 18·Save operation 102개·pending 0개·검사 불일치 0개를 재확인했다.
  인수 직전 DB backup은 `D:\NikkeLocalLab\Backups\stabilization-audit-912d47e8331645abb69eefb14e2cbef1`이다.
  마지막 대조에서 설치 파일 불일치 0개, runtime selection hash 불변, 관련 프로세스·운영 port 없음이다.
- ANALYZE 전후 sparse/dense 총 24회 통과:
  `b4fc342310a245f7b0bf6f7bfc42ac29`, `7ad006a74da14807b16f2fcdc03c8fff`.
  dense 100계정 cache-miss 목록 평균은 전 1,382.913ms / 후 1,394.918ms다.
  명확한 개선이 없어 운영 통계·인덱스를 변경하지 않았다. PDH disk byte는 호스트 전체 disk-stack
  관측이지 해당 DB/요청 단독 I/O나 NAND byte가 아니다.
- 공개 원격 때문에 게시를 보류했던 상태는 운영자의 "private으로 돌리고 push" 승인으로 해제했다.
  정확한 저장소 ID를 확인하고 visibility만 비공개로 전환한 뒤 API로 재확인했다.
  소스 게시·Actions 검증·PR/merge는 [게시 경계](operations/GITHUB_AUTOMATION.md)를 따른다.
- 운영자가 완료를 확인한 범위는 [6단계 인수 체크리스트](operations/STABILIZATION_ACCEPTANCE.md)다.
  별도 P-01~P-09, S29/신규 보스/실드/150 보관 이동을 이번 완료 범위로 확대하지 않는다.

### 이전 작업과의 연결

[안정화 계획](STABILIZATION_PLAN.md)의 회귀 검사·실행 생명주기·저장 일관성·성능 측정을 진행합니다.
2026-09-12 현재 안정화 소스 후속 정비와 운영 DB cold-copy 감사가 진행됐습니다.
최종 전체 검사·설치 반영 결과는 위 2026-09-12 절을 확인합니다. 과거의 ‘남음’ 목록을
현재 상태로 재사용하지 않습니다. 운영자가 직접 수행할 항목은
[안정화 인수 체크리스트](operations/STABILIZATION_ACCEPTANCE.md)로 분리했습니다.
확인된 현행 흐름은 [아키텍처](ARCHITECTURE.md)에 있습니다.

S-03의 실행 입력 snapshot에 이어 S-07의 Save 순서 조정기와 단계 adapter를 분리했습니다.
claim만 남은 재시도의 검증 누락과 다른 저장의 끼어들기를 재현·보강했습니다. 완료된 child는
exact replay하고, 실행 중 경합은 즉시 거절하며 pending을 임의로 삭제하지 않습니다.
후속 소스는 UI의 preview 없는 exact 재시도와 V0018의 원래 요청 영속 보존을 추가했습니다.
신규 pending은 창을 다시 열어도 조회 후 명시적으로 이어 저장하고, 원문 없는 구형 pending은
자동 삭제·추정 복원하지 않습니다. 완료 receipt 조회와 Save As source/복제본 구분을 유지합니다.
운영자 승인으로 원문 없는 구형 pending 3행만 정리한 뒤, **준비된 앱 파일 15개와 V0018을 운영에
적용**했습니다. 해당 배포 검증 당시 스키마는 **18**, 정상 Save 75건·pending 0건이었으며 관리도구와 DB는 정상 종료했습니다.
기존 132개 테이블은 migration 이력 외 행/시퀀스가 동일하고, 시험용 Save/복제 계정은 운영 DB에 만들지 않았습니다.
격리 DB의 실제 HTTP/editor 화면에서 Save 응답 유실 exact 재전송, Save As 원본 보존,
서버·창 재시작 후 신규 pending 복구를 검증했습니다. 설치 WebView2에서는 Windows 접근성 API로
계정·콘솔·큐브·니케·레이드 화면 조회와 저장 버튼 활성화를 확인했습니다. 운영 화면의 Save 클릭과
실게임은 제외했습니다. 클라이언트·Epinel DLL·선택 설정·제품 소스는 이번 배포에서 변경하지 않았습니다.
배포 전후 단위 453개·UI 행동 10개·폐기 PostgreSQL 105개와 전체 계약 검사를 통과했습니다.
세부 검증 결과와 정확한 복원 경로는 안정화 계획을 따릅니다. 실게임 인수는 별도로 남아 있습니다.
배포 직전 복원 기준은 **정리 후 스키마 17·pending 0건 백업**이며, 적용 후 스키마 18 cold 백업도 D:에
보존했습니다. 예전 pending 3건 백업을 현재 배포 기준선으로 혼용하지 않습니다.

후속 UI 요청으로 완료 이력만 있는 ‘저장 상태’ 패널을 숨겼습니다. 처리 중·pending·같은 창의
재시도 안내는 유지하며, 설치본 `editor.js` 1개만 반영했습니다. 다음 관리도구 열기부터 적용됩니다.
이 변경은 단위 453개·UI 행동 12개·계약 검사를 통과했고 DB·클라이언트·DLL은 변경하지 않았습니다.
이번 UI 수정에서는 PostgreSQL 통합 검사를 다시 실행하지 않았습니다.

2026-09-07 후속 실기동에서 종료 감시기 인계 전 실패가 발생해 `started`와
`phase_d_emergency_rollback_failed`가 남고 관리 DB도 중지됐습니다. 운영자 요청으로
현재 실행 `5140655a-5b0a-4003-a6e0-5276811fc4ee`만 복구했습니다. 경로·시작 시간이
일치하는 잔류 Epinel 서버를 종료하고, 기존 orphan recovery로 데이터를 capture/replay한 뒤
`completed`, pending 없음, hosts 기준선 복원, PostgreSQL `SELECT 1` 성공을 확인했습니다.
복구 전 cold DB 2,201개 파일과 실행 데이터 백업은
`D:\NikkeLocalLab\Backups\stale-execution-5140655a-20260907-02`에 보존했습니다.
이 복구 시점에는 제품 코드·클라이언트·DLL을 변경하지 않았고 게임도 재실행하지 않았습니다.
당시 최초 예외의 정확한 native 오류는 아직 확정하지 않았습니다.

후속 승인으로 **종료 후 상태 고착 재발 경로를 수정하고 설치에 반영**했습니다.
프로세스 capture/wait는 제한 권한 handle을 쓰고, 서버 신원을 먼저 보존합니다. client와
coordinator/watcher가 없을 때 증명된 단일 잔류 서버만 정리하며, rollback 후 pending 유무와
관계없이 관리 DB를 준비합니다. 최초 실패 원인을 cleanup 오류와 분리 보존하고, active 실패는
‘실행 상태 확인 필요’로 표시합니다. 신원 불명 상태의 새 실행 차단은 유지합니다.
설치 파일 351개 중 Admin DLL/PDB/editor JS **3개만 교체**했고 의존 DLL·asset은 보존했습니다.
실행 스크립트 5개는 저장소의 동일 source hash로 소비합니다. 단위 **459개**(Admin 97 포함),
저장 UI 12개·lifecycle UI, 변경 C# 서식·전체 계약 검사가 통과했습니다. 폐기 PG **105/105**와
실제 stop/start checkpoint 보존·정리를 확인했습니다(최종 receipt `2c20c3d9720c495da5628fe8d6d312d9`).
첫 PG 실행은 테스트 통과 후 종료 30초를 초과했고, 기존 60초 옵션으로 재검증해 통과했습니다.
검증 근거·설치 파일 hash·D: 백업 경로는
`artifacts/stabilization/2026-09-07-lifecycle-recurrence/`에 있습니다. 앱 before backup과
수정 후 스크립트를 혼용해 전체 rollback이라고 부르지 않습니다.
현재 관리도구·PG·게임은 종료 상태입니다. 이번 코드/앱 반영에서 운영 DB·클라이언트·Epinel DLL은
변경하지 않았습니다. 당시 **실게임 종료 후 재실행 인수와 Solo Raid 참가 데이터의 null 예외는
남았습니다.** 이후 JoinData 인수와 종료 복구 보강은 아래 후속 상태를 따릅니다.

후속 `JoinData` 수정 요청으로 날짜 초기화와 기존 run 재개 조건을 분리했습니다. 오늘의
`TrialCount=0`이어도 구조가 유효한 기존 Trial은 새 생성·횟수 차감 없이 재개하고, 직접
Trial 진입도 일일 초기화를 적용합니다. 이미 저장된 상태는 별도 DB 보정 없이 읽습니다.
진행 중 run·사용 덱·딜·기존 최고 기록의 보존과 재시작/protobuf 응답을 검증했습니다.
회귀 16개 포함 selected-manager **134/134**, Local Lab 단위 418개·저장 UI 12개·전체
계약 검사가 통과했습니다. 별도 handler 검사에는 수정 전부터 있던 실패 2건이 그대로
남아 있습니다(리소스 버전 key, classic handler 개수). PostgreSQL 통합 검사는 다시
실행하지 않았습니다. 서버 DLL 정적 대조에서는 메서드 113,438개 중 관련 4개 본문만
변경됐습니다. 재적용 가능한 소스·합성 검사 패치는 `patches/epinel-classic-solo-raid-rollover.patch`입니다.
관리도구의 선택은 **PhaseD151-v5**로 반영했고 v4 96개 파일 중 DLL·source manifest
2개만 달라졌습니다. v4와 선택 파일 백업은 `D:\NikkeLocalLab\Backups\join-data-rollover-20260907-v4`,
검사·배포 receipt는 `artifacts/stabilization/2026-09-07-join-data-fix/`에 있습니다.
운영 DB·게임 클라이언트 DLL·리소스·rollback 코드는 변경하지 않았으며 게임도 실행하지
않았습니다. 이후 운영자가 **실게임 덱 완주를 확인**했습니다. 이를 5덱 전체·모든 조합의
인수로 확대하지 않으며, 검증된 v5 서버와 게임 DLL은 유지합니다.

후속 종료 복구 수정은 진단 app log/marker가 모두 없을 때 `not_observed`를 남기고 정상
cleanup을 계속하도록 합니다. 전투 관측 성공을 만들지 않고, 기존 잘못된 marker와 명시적
전투 검증 실패는 계속 거절합니다. 동일 시작 시각의 이미 종료된 kernel handle은 경로를
다시 요구하지 않고 정리하며, live 신원 검사와 PID 재사용 차단은 유지합니다. cleanup의
rollback/hosts/DB 실패는 최초 원인과 별도 파일에 남깁니다. 적용 범위는 저장소 실행 스크립트
3개와 새 순수 완료-template helper뿐이며 설치 앱·DB·v5 bundle·원본 완료 도구는 바꾸지 않습니다.
검증·복원 근거는 `artifacts/stabilization/2026-09-07-completion-recovery/`와 안정화 계획을
따릅니다. 이후 운영자가 **“문제 없다”로 확인하고 S-04/S-05 착수를 승인**했습니다.
이를 모든 보스·속성·종료 시점의 인수로 확대하지 않습니다.

2026-09-08 S-04/S-05 1차 전환에서는 보스·속성·bundle 구성 판정을 UI 준비 명령,
Start와 coordinator가 공유하고, 실행문 생성부는 명시적 versioned 입력을 받는 순수 adapter로
분리했습니다. S26/151 구성은 통과하고 S29 기존 불일치는 차단합니다. 부모 템플릿과의
출력 동등성은 합성 및 실제 고정 템플릿의 4조합에서 확인했습니다. 상세·남은 검증은
[안정화 계획 S-04/S-05](STABILIZATION_PLAN.md)를 따릅니다. 2026-09-08 운영자 “1번 진행” 승인으로
**설치 앱 4개 파일을 반영**했고 나머지 347개 파일을 보존했습니다. 백업·hash는 로컬
`artifacts/stabilization/2026-09-08-preparation-contract/installed.json`을 따릅니다.
저장소 coordinator도 새 helper를 읽으므로 앱/스크립트 복원 세트를 혼용하지 않습니다.
이 1차 변경의 실검증은 이후 운영자가 문제없다고 확인했습니다. 공통 parameterized runner의
새 실게임 인수는 별개이며 아래 2026-09-09 마감에 기록했습니다.
운영자 화면에서 계정 선택 후 S26/철갑 준비 완료와 S29 기존 불일치 차단을 확인했습니다.
계정 미선택 시 ‘확인 중’이 남는 UI 문구는 동작 테스트로 재현·수정했으며 editor JS만 추가
반영했습니다(`account-prompt-installed.json`). 열린 창의 계정 선택은 유지하며 다음 관리도구
실행부터 ‘계정을 선택하세요’로 안내합니다. 전체 UIA 자동 행렬 통과나 새 실게임 성공은 주장하지 않습니다.
후속으로 계정 선택 후 최근 실행 이력이 있는 경우의 ‘확인 중’ 고착도 재현·수정했습니다.
현재 준비 상태를 제목으로, 과거 완료/실패 결과를 보조 설명으로 표시하고 live 실행/복구 경고는
우선합니다. 새 동작 검사 6개를 Phase 2A2 gate에 추가했으며, editor JS 단독 배포 근거는
`artifacts/stabilization/2026-09-08-raid-status-summary/`에 둡니다. 실게임 로직·DB 변경은 없습니다.

S-05 본격 전환 **1~6을 완료**했습니다. 2026-09-09 새 `parameterized/v1` 실행기의
조기 종료·S26 1덱 완주/결과창·저장/재실행을 운영자가 인수한 뒤 활성 coordinator의
부모 템플릿 읽기/치환과 legacy 선택 분기를 제거했습니다. 자동 로그는 `startup_only`이므로
완주는 운영자 인수로만 기록합니다. 실검증한 봉인 코드 12개는 그대로이며 과거 복구 자료도 보존합니다.
제거 후 실제 S26/151 기본 경로의 read-only `ValidateOnly`도 통과했습니다.
현재 `legacy/v1` 옵션은 거절하며 rollback은 cold 상태에서 검증된 소스를 복원한 다음 실행에만
적용합니다. 운영 DB rollback/자동 fallback은 없습니다. 단계별 증거·복원 조건은
[S-05](STABILIZATION_PLAN.md#s-05--높음--실행-코드의-문자열을-다른-코드의-인터페이스로-사용함)를 따릅니다.

S-06 장비·큐브 회귀 검사는 실제 컴파일된 materializer 함수에 합성 입력을 주는 로컬 gate로
보강했습니다. 21개 출력/거절 검사와 오류를 심은 복사본 2개 검출, materializer/151 bootstrap/
desktop 별도 빌드를 통과했습니다. CI는 외부 참조 없는 검사기 소스 build/format만 수행합니다.
변경 후 전체 단위 475개·폐기 PostgreSQL 105개, 재시작 checkpoint/cleanup, 실행기·UI·
계약 검사까지 통과하여 이번 S-06 범위를 마감했습니다.
제품 코드·운영 DB·설치본·실게임 실행은 변경하지 않았습니다. 상세와 남은 검사 경계는
[S-06](STABILIZATION_PLAN.md#s-06--높음--회귀-검사의-일부가-동작-대신-구현-문자열에-결박됨)을 따릅니다.

S-08은 캐릭터별 overload 최소 batch 이후, 운영자 승인으로 slot receipt·equipment·overload를
각각 **exact profile revision 전체의 1회 batch**로 변경했습니다. 같은 connection/transaction,
immutable membership과 기존 hash·shape 검증을 유지합니다. 새 회귀 3개는 기존 reader에서도
통과했고 변경 후 폐기 PostgreSQL **110개**가 통과했습니다. 공유 build revision, roster·squad
변경/빈 roster, 동시 Save의 고정 snapshot, 과거 Create/Save/GetByOperation replay와 타계정
분리를 검증했습니다. 기존 sparse/exact OL·결손 참조 검사도 유지합니다.
동일한 pool 상한 32·합성 계정 1/10개(roster 50, history 10)에서 전후 각각 1,800표본을
비교했습니다. 이번 service 목록 명령은 **161→14 / 1,601→131회**, p50은
**52.27~52.53→11.61~13.20 / 543.98~548.71→110.77~111.72ms**입니다.
변경 대상 5경로의 세 묶음 모두 p50/p95가 개선됐고 응답 크기·객체 수·HTTP 요청 수가 같습니다.
변경 후 50/100계정 및 roster/history **8조건 warm 행렬, 총 7,200표본**도 완료했습니다.
오류 0, 모든 표본의 예상 명령 수 일치와 DB 재시작/정리를 확인했습니다. 100계정 목록은
1,301명령·p50 1.17~1.19초이며, 큰 규모의 변경 전 개선율은 추정하지 않습니다. p95 변동과
fixture 한계, 원시 표본·마감 검사 근거는 안정화 계획 S-08을 따릅니다. 캐시·인덱스·migration은
추가하지 않았고 **설치본에는 미배포**입니다. 후속 승인으로 service 목록·HTTP 목록·목록+로비의
**1/10계정 process-cold 60표본**을 별도 새 프로세스에서 측정했습니다. 오류·timeout 0,
ready 전 DB 명령 0, exact 프로세스/fixture binding과 원시 표본·통계 재계산을 확인했습니다.
service 목록 첫 조회 p50은 283.75/432.51ms이며, 시작 시간 p50 175.33/174.29ms와 분리합니다.
이는 합성 측정기 경계이고 설치 앱 startup이나 DOM 표시 시간이 아닙니다. OS/DB cache를
초기화하지 않았고 운영 DB·게임·Epinel DLL도 변경하지 않았습니다. 당시 다른 규모·경로의 cold,
물리 I/O·DOM·query plan 분석은 남았으며, 아래 후속 결과와 구분합니다.
이번 측정기 변경도 단위 475개·폐기 PostgreSQL 110개·계측기 DB-free 프로세스 12개·UI/전체 계약을
통과했고, cold/warm smoke와 모든 폐기 DB의 재시작 checkpoint·정리를 확인했습니다. 수치·경계·
재실행 명령과 receipt는 [S-08 process-cold](STABILIZATION_PLAN.md#s-08-process-cold-계측--2026-09-11)에 있습니다.

2026-09-11 “1~2 진행” 후속에서는 S-08 진단 8조건 **144표본·2,997개 EXPLAIN 재실행**과
실제 편집기 headless Edge DOM **6/6회**, 확장 process-cold **480/480표본**을 완료했습니다.
오류·timeout 0, 원시 표본 및 p50/p95 192개 재계산과 DB restart/cleanup을 확인했습니다.
summary query 자체보다 매 계정의
프로필 전체 복원 비용이 큽니다. plan·구간 CPU/할당량·합성 DB 크기를 기록했으며, 물리 디스크
I/O와 설치 WebView2 성능으로 일반화하지 않습니다. 확장 cold/마감 검사 상태와 receipt는
[후속 진단](STABILIZATION_PLAN.md#s-08-후속-진단dom확장-cold--2026-09-11)을 따릅니다.
S-09의 JSON 교체·pg_ctl exact-child 대기·watcher/recovery 영속화 증빙 검증을 공통화했고,
대문자 result code 및 잘못된 `no_state` head 수락을 차단하는 **53개 합성 행동 검사**를 통과했습니다.
과거 PID-only watcher 지적은 현행 미구현 목록에서 제외했습니다. 설치 앱 파일·운영 DB·게임·DLL은
변경하지 않았지만 **저장소 실행 스크립트는 다음 새 실행에서 소비될 수 있습니다.** 기존 봉인
bundle의 코드/복구 경로는 유지합니다. 운영 pending/provenance 대조, 단계별 timeout 정책의
추가 통합, importer/domain 전체 리뷰와 설치/실게임 인수는 여전히 남아 있습니다. P-01~P-09는
이번 범위에 포함하지 않았습니다.
변경 후 **단위 475개·PostgreSQL 110개·warm smoke 12표본·UI/전체 계약**을 통과했습니다.
폐기 DB의 restart checkpoint/cleanup을 확인했고 운영 DB·설치 앱 배포·원격 push는 하지 않았습니다.
이번 소스 범위는 마감하지만 S-08/S-09 전체 종료 판정은 아닙니다.

## 별도 보류

- 시즌 선택 창(시즌 1~현재, 보스 사진·기본 약점) → 선택 시즌 카드 하나와 5속성 설정 화면:
  [UI-RAID-01 TODO](STABILIZATION_PLAN.md#ui-raid-01--시즌-목록과-선택-보스-설정-화면-분리)에 요구사항만 등록, 미구현.
- S29 profile v3와 registry v2 불일치, 미완료 속성 실드 확장
- 신규 보스와 전투 분석 UI 등 기능 추가

## 상세 근거

- [151 대응·배포·검증 이력](archive/RESOURCE_COMPATIBILITY_151_PROGRESS.md)
- [백엔드 결함 이력](features/CONTROL_CENTER_BACKEND_DEFECTS.md)
- [솔로레이드 영속화·분석 필드](features/SOLO_RAID_PERSISTENCE_AND_ANALYTICS.md)
- [이전 인계 전체 기록](archive/HANDOFF_2026-09-06.md)

과거 문서의 ‘다음 실행’, 오래된 OS 경로, 당시 blocked 판정을 현재 작업 지시로 재사용하지 않습니다.
