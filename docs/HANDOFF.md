# 작업 인계

최종 갱신: 2026-09-14. 이 문서는 짧은 현황 요약이며, 상세 기록을 계속 덧붙이는 로그가 아닙니다.
작업 전 읽기 순서·불변 규칙은 [AGENTS](../AGENTS.md), 문서 위치는 [색인](README.md)을 따릅니다.

## 확인된 현재 상태

- 운영자가 관리도구 → **151 / S26 실게임 검증 완료**를 확인했습니다. 리소스 대응은 종료했습니다.
- 기존 진행도를 유지합니다. 과거 약점 없는 최고 기록은 삭제하지 않고 `unresolved`에 보존하며,
  새 약점별 기록에 추정 병합하지 않습니다.
- 검증된 Epinel DLL·실행 조합을 불필요하게 다시 변경하지 않습니다.
- 활성 OS는 Micron입니다. 저장소·client·bundle·백업의 정확한 위치는 [현재 경로](MICRON_CURRENT_PATHS.md)만 기준으로 합니다.
- 위 완료는 운영자의 실게임 확인이며, 새 자동 관측 receipt나 모든 보스·음성·약점 조합의 검증을 뜻하지 않습니다.

## 2026-09-14 실행 전 검사 정비 진행

현재 후속 작업은 [공통 실행 경로 통합](operations/COMMON_BOSS_EXECUTION_PLAN.md)이다.
운영자는 전투 입력 외 시즌별 부팅/음성 정책을 없애고 UI 보스 추가의 자동 조립 결과를
공통 실행기로 연결하도록 재확인했다. P0 대조와 P1 공통 입력/호환 계약을 완료했다.
공통 생성기의 v3 구성과 교차 profile FX 거절을 정비했으며 다음은 P2 준비/전달 통합이다.
P2 상세 계획은 원본 속성과 속성별 FX 출처를 함께 사용하도록 갱신했다. S29의 전격·수냉
전용 FX를 반영하고, 속성 제한 body·parts·QTE는 조건과 실드 FX를 함께 처리한다.
'QTE만 조정'의 독립 완료 구분은 철회했다. P2-1 공통 속성/FX 해석을 준비기와 coordinator에
연결했고 PS7/WinPS5의 새 합성 35개 및 S29 다섯 약점별 매핑 검사를 통과했다. 다음은
P2-2 특수 패턴 조건·FX 조립이며 S29 실행 허용이나 설치는 아직 하지 않았다. 저장소 정리·최적화는
운영자 지시대로 P2~P6 완료 후 수행한다.
프로젝트 용량 후보도 조사했지만 파일 삭제·통합 설치는 하지 않았다. 아래는 기존
검사 정비의 구현/설치 이력이며 새 공통 경로의 완료 증거가 아니다.

[조사·정비 계획](operations/VALIDATION_PREFLIGHT_PLAN.md)의 A/B를 구현했다. 두 음성 설정을
한 snapshot에서 의미 비교하고 진단하며, 작은 조건 → 전체 해시 → 변경 직전 재확인으로
순서를 옮겼다. UI는 부모 실행과 실제 게임 실행을 구분하고 bootstrap 검사도 별도 표시한다.
관리자 읽기 진단에서도 신·구 비교가 모두 일치했다. 과거 실패의 직접 원인은 여전히 미확정이다.

같은 exclusive CDB transaction의 중복 Prepare 한 번을 제거했으며 전체 hash와 원복 검사는
유지한다. ACE-BASE는 준비 시 관측한 안정 상태(Stopped/Running)를 그대로 결박하고 모든
단계에서 동일성을 검사한다. 실제 서비스·드라이버 시작/중지는 수행하지 않았다.

새 다섯 assessment는 기존 client 한 개를 재사용해 Inspect와 compiled-plan 검사를 통과했다.
새 delivery SHA는 `04f947017747db1ab166652f167bb8245cd921556241e0433c6f34a9e3b103e8`이다.
앱 설치와 설치 파일 353개, 새 다섯 entry의 실제 설치 API 읽기 검사를 완료했다.
근거는 `artifacts/validation-preflight-20260914/installation.receipt.json`이며 API SHA는
`b79a8deda1493e8a9f779136c60044d33039133ce35b6b6a6e8f9c9248e09b0d`이다.
기존 entry/실패 기록은 보존하며 새 S29 실게임 인수는 아직 하지 않았다.

설정 합성 61개, 진단 69개, 드라이버 104개, UserValidation 단위 252개, 격리 PG 114개가
통과했다. repository/Phase 0/2A1/2A2/2B/3A/3B0/3B1/3B2/Actions 최종 로컬 gate도
통과했으며 같은 artifact의 `final-verify-*.log`가 권위다. 원격 Actions 결과와 구분한다.
C는 NTFS 합성 prototype까지 진행했다. 재부팅·journal 공백 무효화와 동일 크기 변조·시간
복원·교체·하드링크 거절을 검증했지만 프로세스 사이 lease 인계/부분 원복 세대 결박과 전체
시작 성능은 아직 증명하지 않았다. **빠른 경로 및 계획 전체 완료를 주장하지 않는다.**

## 2026-09-13 사용자 실행 초기 오류 기록 보강 — 당시 기록

후속 사용자 실행에서 `resource_native_uv_preferences_before_drift`와 원래 실패 위치를
확인했다. 현재 동일 비교는 20/20 통과하며 당시 관리자 관측 값은 없어 직접 원인은 미확정이다.
테스트 정밀 검사/실사용 빠른 검사 분리와 추가 반복 읽기 병목을 포함한
[조사·정비 계획](operations/VALIDATION_PREFLIGHT_PLAN.md)을 작성했다. 당시에는 미구현이었다.

운영자의 첫 S29/수냉 실행은 상위 PowerShell이 종료되면서
`boss_validation_controller_failed`가 됐다. `execution.started.json` 이전에 실패했고,
당시 숨김 실행의 원본 예외는 보존되지 않아 직접 원인을 확정하지 못했다.
아래 오프라인 마감은 이 실제 사용자 시작 경로의 성공을 보장하지 않는다.

API에 내장한 `UserValidationDiagnostics.ps1`을 새 UI action 폴더에만 기록하고,
기존 봉인 controller를 별도 script scope로 호출한다. 실행기/5속성 entry/전달 manifest,
client 복제본과 기존 실패 증거는 수정하지 않는다. 최초 로그 쓰기에 실패하면
controller를 호출하지 않는다. 첫 marker·제어된 오류 코드·예외/내부 예외 종류·
HResult/Win32 코드·프로젝트 script/행·최근 오류 이력(최대 256개)·프로세스 종료 코드를
남긴다. raw 메시지·source line·인자·target/게임 ID는 기록하지 않고 메시지는 hash만 남긴다.
처리된 오류 이력을 모두 실패 원인으로 단정하지 않는다. 프로세스 강제 종료/파서 시작
이전 실패는 최종 controller 로그가 없을 수 있어 API가 그 결손과 종료 코드를 별도 기록한다.

검증 명령은 `scripts/test-nll-user-validation-diagnostics.ps1`과 Admin API 단위 검사다.
실제 게임은 에이전트가 호출하지 않는다. 2026-09-14 운영자 지시로 UAC 제한은 제거했다.
설치 반영 여부는 새 app-only delivery의
receipt로 확인하며, 이전 배포 receipt를 새 수정의 설치 증거로 사용하지 않는다.
사용자가 다시 실행한 뒤 새 로그로 원인을 식별한다. 이번 변경 자체가 원인 수정이나
S29 실게임 인수 완료를 뜻하지 않는다.

## 2026-09-13 재계획 1~5 마감 현황

아래 과거 준비 기록의 ‘미구현/미설치/남음’보다 이 절이 우선한다. S26은 이미 운영자가
인수했으며 다시 요구하지 않는다. 새 S29 실게임은 에이전트가 실행하지 않았다.

- **1~3 구현/오프라인 검증 완료:** 수냉 한 경로에서 5속성으로 확장했고 모두
  controller Inspect 및 실제 compiled-plan 결박 검사를 통과했다. 동일 trial
  `6d0c2fbd-edb4-4d07-a6dd-5f32218e9a85`의 기존 client 한 개만 사용한다.
  추가 전체 client 복제는 없고 공통 작은 파일 원복본은 약 87.7MB다.
- 상위 실행기는 사용자 `Start/Recover`, 읽기 전용 `Inspect`를 분리한다. 정확한
  Job/프로세스 소유, 승인된 SCM·ADVT 생명주기, CDB/작은 입력 복원, 새 로그 비삭제
  격리 보관, 큰 파일의 미승인 변경 중단을 연결했다. 복구가 불명확하면 격리를 유지한다.
  합성 복구/결박 **148개**가 PS7/WinPS5에서 통과했다. 실제 ACE 조작 성공을 뜻하지 않는다.
- **4 구현 완료:** `UserValidationDelivery/Execution`으로 봉인된 5개 전달 계획만
  `awaiting_game_validation`으로 투영한다. UI는 S29 단일 카드/5속성/사용자 시작·원복
  버튼을 제공한다. 조회/폴링은 실행하지 않고 UAC 취소·중복 operation·HTTP 단절을
  처리한다. 기존 S26/v6와 미검증 S29 operational registry 차단은 유지한다.
- 실제 파일 HTTP 검사: 2회 호스트, 5속성 준비, S26 processed/S29 검증 대기/S19 unresolved,
  39시즌 이미지 78회 hash, 인증/CSRF, 영속 job의 현재 투영과 원본 파일 비변경 확인.
  오류였던 job 투영 위치를 수정하고 별도 회귀를 추가했다. 데스크톱/모바일 브라우저에서
  5개 합성 클릭과 UAC 취소·S26 복귀·미처리 취소를 확인했다. 실제 UAC는 호출하지 않았다.
- **5 자동 검사:** `final-full-gates-2.log`의 Phase 2A1/2A2/2B→3A/3B0/3B1 전체 체인,
  Phase 0/3B2/Actions/repository 검사 통과. Admin API **404개**, 격리 PostgreSQL
  **114개**(폐기 cluster 종료/정리 포함), JS **31개** 통과. 앱 package 적용/원복
  51개·delivery 32개 합성 검사 및 실제 앱 shadow 전체 반복 적용/원복을 통과했다.
- 배포 대상 API는 `app-publish-4`, SHA
  `7482e213607026abde7d8f29d7b1180a990a56436b06701e94f696c21acd30d9`.
  전달 manifest SHA `f260555c11574d13bb74efa9e49f94b5305789655ff909a319e315e9d35b84bd`를
  새 `pipeline-4`에 연결했다(config SHA
  `7c1b57a721b24ae621c1aa0e6c4022a2633fa2eec51c6ea03744aa6f18621ba4`).
  기존 jobsRoot를 유지하며 운영 profile을 publish하지 않는다.
- 실제 설치 적용/소스 SHA/Actions/merge의 최종 근거는
  `artifacts/boss-catalog-20260913/release-status.json` 및 해당 원격 run이다.
  로컬 검사만으로 원격 병합이나 실제 게임 성공을 선언하지 않는다.
- 사용자 절차는 [S29 실게임 검증](operations/BOSS_NATIVE_USER_VALIDATION.md)의
  ‘이번 인계의 실행 순서’를 따른다. 수냉 → 작열 → 풍압 → 전격 → 철갑 순서로,
  매번 원복 완료를 기다린다. 첫 실행용 구성은 약점별 1회용이다. 재검증 시 새 작은
  assessment를 발급하며 전체 client 복제를 늘리지 않는다. 무제한 자동 재시도와
  모든 미래 보스의 자동 인수는 이번 완료 범위가 아니다.

주된 접근 변경: privilege/VM/S26 반복 실험을 종료하고 하나의 사용자 실행 경로를
완성했다. 19GB 읽기는 실제 Inspect/Start 시점에만 수행하고 공통 준비 pin을 재사용한다.
UI 조회는 작은 봉인 파일만 읽는다. DB 회귀와 앱 cold 배포는 순서를 분리한다.

## 이전 준비·배포 기록 — 현재 실행 지시가 아님

### 2026-09-13 담당 범위 확정 — 실게임은 운영자

현행 요약(아래 중간 단계의 ‘미설치/남음’보다 우선):

**초기 UI 배포 후 추가 실제 HTTP 검사에서 S26 v1 프로필을 미처리로 분류하는 회귀를
발견했다. 이전 정상본으로 복원한 뒤 v1 호환성을 수정하고 새 봉인 묶음으로 재설치했다.**
복원 receipt의 status는 verified이며 DB·게임·v6/registry는 변경하지 않았다. 아래 PR #25
적용 이력은 이 후속 복원을 포함해 읽는다. v1/v2 기존 승인 프로필을 함께 표시하도록
수정했으며 신규 v2-only publisher/기존 S29 차단은 유지한다. 회귀 3개를 추가했고 새 앱
후보(`app-publish-2`, Admin SHA-256
`62cd182efd35dc9179da24385d9762f1abeb523dc20639c8d9ab110408fe8580`)의 실제 loopback
HTTP 검사도 통과했다: 호스트 2회, S26 processed/S29 drift 차단/S19 unresolved,
39시즌 이미지 78회 hash 대조·인증/CSRF·영속 작업 조회. 이는 DB 없는 API 구성요소
검사이며 앱의 전체 Start/worker/게임은 실행하지 않았다. 근거는
`artifacts/boss-catalog-20260913/http-installed-probe/candidate-4.log`이다.
API 단위 167개·브라우저 39이미지/단일 카드 검사를 통과했다. `app-package-2`의
전체 앱 반복 적용/원복 receipt pin은
`b0fa6898e1a117ca05e3a9e657ded92b2283ae2df18207e6659cd76f0e2e688a`, package pin은
`33062fbc0c40f6f03b9981a4ef9048fc02b88174036f470f10a50659b00c1b8f`다.
현재 설치/복원 기준은 **`control-center-delivery-2`**, plan SHA-256
`72978faf83d5161b7c50d4a73d1c55788c0e239f74757a25dc2ff8a7d3387e11`이며 apply receipt는
`apply-7dba2558220e4f30adec579e405b3f83.receipt.json`이다. 352개 파일·Start/activation·
v6/selection을 독립 재검사하고 설치된 동일 DLL의 실제 HTTP 검사도 다시 통과했다
(`http-installed-probe/installed-5.log`, 이미지 78회). source CI/병합 상태는 이 UI
호환성 수정 커밋의 run에서 별도로 확인한다. 원복은 새 plan의 `restore`를 사용한다.
`158f81b`의 Actions `34745856896`은 PostgreSQL job 성공, Windows 계약 job의
합성 프로세스 검사 3개가 각각 10/15/40초 deadline으로 실패했다. 예외는 모두
`TaskCanceledException`이고 UI catalog assertion 실패가 아니다. 해당 PowerShell
프로세스 fixture를 비병렬 collection으로 분리해 동시 cold-start 경합을 줄인다.
제품 timeout/취소/실패 판정은 변경하지 않으며 후속 CI 성공 전 병합 완료로 표시하지 않는다.
후속 `60fdcec8471922993613038c991cf4243e6f28c2`는 Actions `34746913581`의
3 jobs 성공 후 PR #27로 병합됐다(main `8103e1f42cec27e114756625864d42f53422c081`).

### 사용자 검증 실행 연결 — 진행 중, 아직 실행 안내 단계 아님

최신 재계획은 [안정화 계획의 1~5](STABILIZATION_PLAN.md#2026-09-13-재계획--현재-실행-순서)를 따른다.
수냉 단일 경로를 먼저 닫고 나머지 약점/파이프라인/UI를 연결한다. 추가 전체 게임 복제는 없다.
2026-09-13 후속 소스는 아직 미커밋/미게시이며 기존 HEAD `626f01f`도 아직 원격 미게시다.

- 5개 `native-store.private.json` 준비 완료. 실제 client는 읽기만 했다.
  수냉 projected CDB SHA `13a96acaf56e17861ce7dff36c80b27f32aece2dfbe4dab2af8c167fbbe0eb93`,
  작열 `cac861d2a73b47bc0720a2136bd7b9d895573e40a3bc474f8f05440da80b1024`,
  풍압 `308d0875cb491d63a0268fd20f5c79c8f5a9465b253fdc52f009f7b8b4de4173`.
  전격/철갑은 변경 없음으로 원본 CDB hash를 유지한다. `prepare-user-stores-1.log`가 근거다.
- 공통 `client-pins.private.json` SHA
  `5b6843ee4ced90b13fd260ef70a7e4bff3b4b4ad469e60c47d8dea88e14f7ac7`.
  원본 1,154파일 물리 pin을 확인하고 1MB 이하 1,021파일/87,715,518 bytes만
  trial의 `client-rollback`에 보관했다. 첫 집계의 PowerShell dictionary 오류는 출력 생성 전
  실패했으며 PSCustomObject로 수정했다. 성공 근거는 `prepare-user-client-manifest-2.log`다.
- 상위 `invoke-nll-user-validation.ps1`의 Inspect/Start/Recover 경로와 계획 준비기를 추가했다.
  Inspect는 파일/OS 상태 읽기만 한다. Start/Recover는 사용자 관리자 실행으로 한정하며
  실행 간 mutex/이전 미복구 차단, exact Job 소유 기록, SCM/driver cleanup과 원복을 연결한다.
  작은 기존 파일 복원과 새 파일의 비삭제 격리 보관도 포함한다. unknown 대형 파일 변경은
  실패로 유지한다. 실제 게임/서비스/드라이버 조작으로 검증한 것은 아니다.
- 합성 controller binding/부분 registry 원복/각 cleanup 단계 중단 **133개**가 PS7 및
  WinPS5에서 통과했고 관련 .NET **219개**가 통과했다. 새 controller 검사를 로컬 계약과
  두 Actions job에 연결했다. 전체 마감 회귀는 아직 남았다.
- 수냉 assessment `beaf2982-cc40-499e-af47-b802c28aafe9`의 controller/child/부모/bootstrap
  계획을 배치했다. entry SHA
  `45d4c981fe1434af233620e62254856b244df01db04694f3a493a04be4a9998e`.
  `prepare-user-controller-water-1.log` 성공 후 `inspect-user-controller-water-1.log` 검사를
  진행 중이다. 서버/게임/UAC/ACE 변경은 없으며 아래 과거 “상위 controller 미구현” 설명은
  소스 구현 전 상태다. 다른 4개 controller 배치와 파이프라인/UI/배포/CI 마감은 남았다.

- 별도 `NativeFxUserValidationBootstrap`을 추가했다. 기존 v6/151 bootstrap은
  교체하지 않는다. 새 경로는 신규 등록 없이 준비된 합성 계정을 사용하고, 독립
  client/cache·부모 계획·S29 profile/candidate·5약점 및 baseline/candidate/restored
  구분을 pin한다. 원본의 빈 파일·공백/괄호 파일명을 보존하며 alias/reparse/hardlink,
  임의 경로, 결손·중복 JSON, 오래된 격리 증거는 거부한다.
- `--inspect-user-validation-inputs`는 파일 검사만 한다. 실행은 별도 `--user-start`
  분기에서 elevated token, 정확한 Job 소속 및 승인된 service/driver isolation
  증거를 요구한다. 계획 shape나 helper 결과만으로 OS 격리/실게임 성공을 주장하지 않는다.
  이 부트스트랩은 준비기·외부 수명주기 controller 연결 전에는 사용자용 실행기가 아니다.
- 관리 종료 helper를 Job zero → 서비스 정상 중지 → scope zero → 서비스 Manual 원복
  → 소유 입력 원복 → ACE-ADVT 정상 중지/전체 baseline 확인 → 격리 해제 순서로
  조립했다. PowerShell 7/WinPS5 각 **96개** 합성 검사를 통과했으며 실제 OS 서비스/
  드라이버 조작은 없다. 실패 시 뒤 단계, 특히 격리 해제를 수행하지 않는다.
- 첫 API 전체 220개/새 입력 focused 53개 검사와 새 bootstrap 및 기존 NativeFx/
  PhysicalBootstrap151 빌드가 통과했다. 실제 전체 client 목록 대조에서 빈 파일과
  공백/괄호 이름도 필요함을 확인하고 추가 회귀를 넣었다. 변경 후 focused **57개**와
  새 bootstrap 빌드가 다시 통과했다. 승인된 Sail/CA hash도 계획에서 고정한다.
  빌드 경로에서 inspect/이전 옵션/빈 인수는 모두 64로 거부됐고 인증·게임은 시작하지 않았다.
- 새 독립 사본 trial은 `6d0c2fbd-edb4-4d07-a6dd-5f32218e9a85`다. 원본 1,154개/
  20,430,834,145 bytes의 새 manifest는 `1fef12f5d08ef299a1a8ce36aee8a8ad331d532ba4c66c9b3bd11ece02e06c7c`.
  과거와의 차이는 없어진 3,504-byte crash 보고서 한 개뿐이며 나머지 파일 hash는
  전부 일치했다. `user-validation-source-1.private.json`에 읽기 결과를 보존했다.
  복사/사후 전수 검사를 완료했고 원본 불변을 확인했다. 성공 `clone.receipt.json` SHA-256은
  `5f2640137bbe68eb89e0e7e612f0fa082edf9cd648034fce6bf6c7e4441f58e6`이다. 별도 OS 파일
  핸들 메타데이터 검사에서 1,154개 모두 hardlink 0/reparse 0을 확인했다. 런타임은 시작하지 않았다.
  실제 전체 manifest를 새 계획 parser에 넣은 shape 검사도 통과했다(빈 파일 9개 포함).
- 위 부트스트랩/종료 helper 소스 `bdf89a29c4e9e1b8639f10f4d3b2fc399b3a91e0`은 로컬
  전체 검사(API **224개**) 및 Actions `34747933884` 3 jobs 성공 후 PR #28로 병합됐다
  (main `e25bf252fc1340ff9c2641086d34422354db7b14`). 이 병합이 실행기 최종 완성은 아니다.
- 후속 계획은 `runs/<assessment>/validation.private.json`으로 실행별 봉인한다.
  같은 독립 client trial에서 서로 다른 약점·baseline/candidate/restored를 검사하되
  이전 계획을 덮어쓰지 않는다. 부모 계획에 assessment/case도 결박했다. focused **58개**와
  부트스트랩 빌드가 통과했다. `5cb74fa`의 Windows/PG 검증은 성공했고 PR #29는
  main `1eda735a3e90a631e21d22cf45a912979ec870ae`로 병합됐다(동일 tree 확인).
  최초 게시 응답은 GitHub 502였고 실패 게시 재시도는 이미 이동한 main을 감지해 중단됐다.
  따라서 run 전체 표시는 failure지만 소스 병합은 확인됐다. 보호 규칙/수동 merge 우회는 없다.
- 준비된 계정은 마지막 정상 S26 실행 `347cd379-4c8d-48cd-9296-2c21e0a39fe3`의
  materialization receipt와 현재 `runtime/db.json` hash가 일치하는 사본에서 만들었다.
  `--prepare-user-validation-account`는 원본을 읽기 잠금으로 유지하고 5약점별 새 private
  계정/로그인/토큰 키를 생성한다. S29 exact manager/Challenge target 및 이전 active run 부재를
  검사하고 운영 persistence binding을 제거한다. 로그인·토큰·선택·binding 외 모든 JSON 값은
  그대로 보존한다. source/receipt/progression 결손, 중복 키, 이미 있는 출력은 거절한다.
  원본 pack의 독점 읽기 파서와 lease가 충돌한 첫 시도는 실패로 보존하고 private pack 사본으로
  해결했다. 최종 `prepared-user-accounts-3/matrix.receipt.json` SHA-256은
  `0aa835184f6586dc49c793c6374fd33e360bc5f189b12745cf4b6ec5df79771c`다.
  각 사본의 니케 193명·튜토리얼 40그룹·시나리오 611개가 보존됐으며 DB/서버/게임은 열지 않았다.
- v6의 실제 `LoadConfiguredContract`는 S26/v1을 수락하고 S29/v3를
  `classic_solo_raid_target_profile_invalid`로 거절하는 것을 오프라인으로 재현했다.
  v3를 v2로 바꾸거나 운영 registry pin을 완화하지 않는다. 새
  `build-nll-user-validation-server.ps1`은 원본/v6를 보존하고 private 소스 사본에만
  `epinel-user-validation-profile-version.patch`를 적용한다. 버전과 계약의 정확한
  v1/v2/v3 쌍만 수락하는 helper를 별도 서버 빌드에 연결한다.
  재현 빌드 `artifacts/user-validation-server-builds/profile-v3-20260913-1`의 DLL SHA-256은
  `9aaca41cd63ec6f13293038ec03e4402c1ef13f9b1ee7fe74317bcd012ee437e`다.
  이 후보의 실제 S26/v1·S29/v3 파서와 selected-manager **142개**, 새 source-free
  계정/버전 회귀 **34개**가 통과했다. 빌드에는 기존 upstream warning 22개가 있고 오류는 없다.
  설치 v6/선택 hash와 원본 source manifest를 보존했다. 이 소스 `29323d5`는 로컬 전체 검사
  (API **259개**)와 Actions `34749682740` 3 jobs 성공 후 PR #30으로 병합됐다
  (main `eb26bd55ef5a45ca286a39a5b0717abdf3be9632`, source와 동일 tree 확인).
- `prepare-nll-user-validation-runtime.ps1`로 위 trial 아래 서로 다른 assessment의
  서버/계정/부트스트랩 **5세트 배치 완료**. `EpinelPS-151-UserValidation/<assessment>`는
  새 v3 DLL 및 v6의 봉인 dependency/cache 사본만 쓴다. bootstrap은 8파일, 서버는
  파생 pack을 쓰는 4약점 85파일/원본 철갑 84파일이다. 운영 v6를 교체하지 않았다.
  실제 입력 검사 `user-runtime-input-inspection-3.log`에서 5세트의 prepared account,
  약점 pack, 독립 경로와 client 1,154개/20,430,834,145-byte 물리 pin을 확인했다.
  첫 검사는 철갑의 정상 `variantStaticDataSha256:null`을 잘못 거절했고 이를 고쳤다.
  서버/게임/인증 및 launch permission 생성은 하지 않았다.
- 새 `NativeFxUserValidationChild`는 명시적 `--user-start`, 고정 배치 경로, elevated token과
  정확한 Job 소속을 요구한다. 부모·bootstrap·staging·server/child 입력을 검사하고
  독립 서버 → 부모의 loopback/격리 확인 → 준비된 계정 bootstrap 순서로 연결했다.
  서버/부트스트랩은 상속 환경을 비운 후 각각 최소 설정만 넣고, 서버의 SQLite와
  profile/선택 약점을 고정한다. 게임 중 서버 종료·시간 초과는 실패이며 종료 후에도
  외부 controller의 Job/service/driver/입력 원복 증거가 필요하다. 새 child 빌드와
  조기 거절 4조건은 통과했지만 아직 해당 child를 실제 runtime 경로에서 시작하지 않았다.
- native store의 부분 쓰기/원복 엔진은 전체 원본 hash와 선택 chunk를 쓰기 전에 대조한다.
  중단 복구는 선택 구간의 before/after 혼합만 허용하고 나머지 전체 바이트를 원본 hash로
  검증한 뒤 원복한다. 계획은 약점→보스 속성 한 역할만 허용하고 기본 철갑/보정 불필요
  전격 및 baseline/restored는 변경 없음으로 둔다. controller용 파일 wrapper는 독립
  clone의 정확한 CDB, rollback pin, 단일 물리 파일·배타적 handle 및 사전 cold 확인을
  요구하며 최초 쓰기 전 durable marker를 flush한다. caller의 cold boolean 자체가
  OS 관측 증거는 아니므로 외부 controller 연결 전에는 사용하지 않는다.
  합성 부분 쓰기/원복 **67개** 및 실제 오프라인 `selected-fire-store`의 fire 24,153-byte
  구간 적용→원본 hash 복원→반복 원복이 통과했다. 실제 client에는 적용하지 않았다.
  근거는 `store-transaction-probe/evidence-1/`, restore receipt SHA-256
  `c33189517e48313c7e8776df679a6c7acdba2631ca2f1fdcb9e4f7c454e488b2`다.
- 남은 연결은 선택한 단일 보스 속성의 native store 계획/rollback 배치,
  외부 사용자 실행 controller·관측기 및 durable job의 실제 delivery receipt 연결이다.
  S29는 계속 `awaiting_runtime_delivery`; 운영 registry/v6/선택/DB와 공유 cache는 유지한다.
  기존 `ResourceProbeExecution`은 최대 300초, 기존 `db.json`과 모든 `EPINELPS_` 설정을
  거부하므로 준비된 계정/속성 전투에 그대로 재사용하지 않는다. 검증된 normal
  `--headless --local-only` 경로에 별도 bounded controller/고정 SQLite 설정/환경·Job·
  전체 input pin을 적용한다. 계정·서버 staging과 bounded child, native 부분 쓰기 엔진까지
  구현했으며 외부 사용자 controller 및 실제 native 전달/원복 연결은 남았다.
  아직 서버/controller를 시작하지 않았으며 사용자 실행 안내 단계가 아니다.

- enikk.app 승인 이미지 **39시즌/37개 PNG**와 시즌 선택 → 단일 보스/5약점 화면,
  미처리 예/아니오·처리 상태 UI를 설치했다. 로컬 snapshot은 1~40이며 S19와
  최신 공식 시즌 여부는 미해소로 유지한다. 다음 관리도구 실행부터 적용된다.
- UI/app/startup 배포 소스 `bc8e83c353b3342e36342b5ac6dcc299e7369f83`은 Actions
  `34744118009` 3 jobs 성공 후 PR #25로 병합됐다(main
  `2ef3d2d7af013b6246ccaf073da2b7b4321dac96`). 봉인 plan SHA-256은
  `755bbc39c144a4545a35fbaaf874f1fed91ac9e42be3dae3b8a632bd19fd6b51`, 실제 적용 receipt는
  `artifacts/boss-catalog-20260913/control-center-delivery-1/apply-2fb9af3c0b4644f297bb8156b8a667a0.receipt.json`이다.
  앱 전체 352파일·Start/activation·v6/selection 대조를 통과했고 운영 DB/게임은 건드리지 않았다.
  이 첫 plan은 이미 원복했다. 현행 복원에는 위 두 번째 plan을 사용하고 과거 3파일 복원은 쓰지 않는다.
- 설치된 activation은 아래 실제 오프라인 S29 검사를 통과한 `pipeline-3`를 가리킨다.
  앱 파일 적용만 했으며 관리도구/worker나 게임을 시작하지 않았다. S29 상태는 계속
  **awaiting_runtime_delivery**다. 별도 native 실행 구성·전달/원복 연결과 사용자의
  실게임 인수는 남아 있다. S26 재검증이나 S29 운영 pin 변경을 하지 않는다.
- 운영자는 사용자 실행 검증에서 **ACE-ADVT 자동 시작/종료 후 정상 중지**를 추가 승인했다.
  범위는 [보안 경계](SECURITY_BOUNDARY.md)의 새 승인 절을 따른다. 새 helper는 이
  opt-in 정책만 처리하고 기존 무변경 driver guard는 유지한다. PowerShell 7/WinPS5
  각 44개 합성 검사와 기존 서비스 55개를 통과했다. 실제 드라이버 중지·게임 실행은 없다.
  helper를 사용자 실행 계획/전체 종료 controller에 연결하는 작업은 아직 남아 있다.
  실제 현재 driver snapshot의 새 정책 읽기 검사도 통과했다(ADVT Stopped, BASE Running).
  변경 후 Phase 3B-2 전체 baseline/계약 검사도 통과했다
  (`artifacts/boss-catalog-20260913/baseline-driver-1.log`). 승인 소스 `2682bdc`는
  Actions `34745124495` 3 jobs 성공 후 PR #26으로 병합됐다(main
  `77fda7d54cbcaf786e0edf84acb345846e8e0572`). UI v1 호환성 수정은 별도 후속 커밋이다.

운영자가 **실게임 테스트를 직접 맡고 그 외 작업을 전부 진행**하도록 명시했다.
따라서 에이전트는 새 게임 실행/UAC 접속 실험을 자동 재개하지 않는다. 구현·오프라인
자산 검사·합성 프로세스/실패 복구 검사·UI/API·폐기 DB 회귀·검증용 배포와 CI/병합을
진행하며, native 화면·전투·보정 FX 수락은 사용자 확인 전까지 미검증으로 남긴다.
**S26 기존 인수 완료는 유지**한다. 아래 중단 실험 기록은 현재 실행 지시가 아니다.

오프라인 고정 길이 FX/전체 store 원복 소스는 PR **#22**, Actions
`34735043785`의 3개 job 성공 후 `80c566b3c6c76fe3fe462753b5120ddb8787a30f`로
병합됐다. 현재 후속 branch는 `agent/boss-onboarding-publication`이며 아래 후속분은
아직 작업 중이다. 이 중간 병합을 계획 1~6 전체 완료로 읽지 않는다.

- 기존 legacy v2 publish를 **불변 profile 파일 + 원자적 registry 교체**로 변경했다.
  registry CAS/프로세스 간 파일 lease/전후 artifact hash 재검사/실패 재시도와 기존
  활성 파일 보존을 42개 합성 검사로 확인했다. v3는 계속 native delivery 없이
  publish할 수 없다. 현재 운영 registry는 수정하지 않았다.
- 새 로컬 시즌 카탈로그 도구가 151 snapshot에서 **1~40 중 39개**의 Challenge
  boss/한국어 이름/기본 약점을 해소했다. **S19 manager 연결은 unresolved**다.
  현재 공식 시즌 여부는 자료에 없으므로 `currentSeasonStatusCode=unresolved`이며
  40을 현재 공식 시즌이라고 단정하지 않는다. 원본 번역 컨테이너 30개는 saus
  catalog의 raw digest/SHA-256을 대조해 별도 artifacts로 복사했다. 원본/공유 cache
  변경이나 게임/서버 실행은 없었다. 출력은 `artifacts/boss-catalog-20260913/`이다.
- `GET /boss-seasons`, image pin 검증, 작업 기록/요청 API 및 영속 queue/중복 요청
  identity/재시작 복구 상태 코드를 추가했다. hash-pinned PowerShell worker와 Program
  composition을 연결했다. 설정되지 않은 import는 503으로 닫으며 운영 앱의 worker는
  아직 켜지 않았다. `prepare-nll-boss-pipeline.ps1`은 새 private 설정만 만들고,
  `NikkeLocalLab.BossPipeline.Checks`는 게임/웹서버/DB 없이 작업을 실행·재검사한다.
  계정 DB 대신 `Users:[{}]` 합성 seed에서 exact unique manager를 해소한다.
- 실제 S29 API 서비스 → 오프라인 실행 Job → 스킬/행동/5속성 → native FX → 고정 길이
  → 청크 경로가 통과했다. `artifacts/boss-catalog-20260913/pipeline-2/`의 작업 UID는
  `5ee290db-ffc2-4611-a2ad-a170f5585eda`, 후보 receipt SHA-256은
  `585f418d9756d4815f5ca3aef9c9a4978bc1430dbd71736b8f8915120b629111`, 청크 receipt는
  `9fbfa48a60ea86526a663de56abb03c548c86ef868bbc5fa43d2818fb8d527dc`다.
  972개 입력 pin을 전후 확인했고 재시작 replay/도구 종료/registry 불변을 확인했다.
  새 결과 reader로 receipt hash chain을 다시 읽어 확인했다. 상태는 여전히
  **awaiting_runtime_delivery**다. native 실행·운영 DB·배포·실게임 수락은 주장하지 않는다.
  초기 pipeline-1의 `boss_pipeline_registry_profile_drifted` 실패 기록은 보존했다.
  S29 기존 v3 draft/pin 불일치는 실행 차단으로 유지하되 NEW candidate 생성을 막지 않게 했다.
- 시즌 선택 화면 → 단일 보스 상세/5약점, 미처리 보스 예/아니오 팝업과 별도 완료/
  보류 팝업을 구현했다. 기본 약점은 실행 약점과 분리한다. Node 24개, 새 catalog/
  job/API/기존 UI 안전성 focused .NET 29개, 새 materializer 합성 16개, locale
  추출 focused 17개 검사가 통과했다. 실제 Edge의 합성 HTTP UI gate도 통과했다
  (40 cards, 상세 1 card, No 0 jobs/Yes 1 job, JS error 0). 원본 보스 이미지
  39개 추출/연결과 운영 UI 설치는 아직 남아 있다. 수정 후 Edge UI gate도 재통과했다.
  추가 결과 receipt 13개/Windows runner 3개, native composition 합성 14개와 리소스
  전체 260개 검사가 통과했다. 공유 Job 도구는 C# 5와 .NET 8 모두 호환하도록
  null native directory를 IntPtr.Zero로 표현했고 WinPS5 Job 44개를 재통과했다.
  합성 UI 화면을 실제 서버/게임
  성공으로 승격하지 않는다.

다음은 선택 약점별 store/검증용 native delivery와 원복, 보스 사진, 검증용 격리 실행 구성,
UI 배포 및 후속 전체 회귀/CI 병합이다. 시즌 onboarding 소스는 `a219f157`의
Actions `34741015549` 3개 job을 모두 통과해 PR #23으로 병합됐다. main은
`1596c0674b1a1f3b36bc6d3f80fd91bbf809f5d6`이며 후속 작업은 이 squash를 기준으로
분기했다. 기존 lifecycle 3-file-only 패키지를 새 UI 배포에 사용하면 안 된다:
새 `boss-seasons.js`와 HTML/CSS 전체 묶음 및 추가 파일의 원복 기준도 필요하다.
후속 로컬 Phase 3B-2 전체 baseline/계약, repository/Phase 0/Actions 계약과
publication 42/native composition 14/common candidate Python 12 검사를 통과했다.
후속 폐기 PostgreSQL 114/114·재시작·정리도 통과했다
(`artifacts/stabilization/lifecycle-postgresql/c84625d7704a4882adaf6cf1f8f0c7dd/receipt.json`).
첫 소스 커밋 `be5d01d`의 Actions `34740637212`는 테스트 전 main merge 준비에서
문서/명령 등록부 충돌로 실패했다. 앞선 squash 이력을 main과 정상 merge로 연결해
재검증을 통과했다. 기능 gate를 우회하거나 S29 실행 pin을 바꾸지 않았다.
`pipeline-2` 설정은 실행 당시 pin의 과거 증거이며, 이후 합성 seed를 표준
`tests/fixtures/synthetic/boss-variant-discovery-seed.json` 위치로 옮겼으므로 재실행/
배포 설정으로 재사용하지 않는다. 후속 배포 전에 최종 소스로 새 설정을 생성해야 한다.

후속 선택-role store는 기본 3종 동시 적용과 별도의
`nll/native-fx-offline-selected-store/v1` 계약으로 한 보스 자체 속성만 적용한다.
합성 14개 검사(3역할 각각 교차역할 불변 포함)를 통과했고 실제 S29 청크를 사용한
fire 단일 role 6,574,364,321 bytes 사본의 전체 hash A→B→A·반복 복원·복원 후보 거절도
통과했다. `artifacts/boss-catalog-20260913/selected-fire-store/` manifest pin은
`323a5bb616af8936462f64918ea0481d248685c20d2258900cbedf3d10f9e508`, 후보 hash는
`13a96acaf56e17861ce7dff36c80b27f32aece2dfbe4dab2af8c167fbbe0eb93`다. 이 사본은
현재 **원본으로 복원됨**이며 설치용 보정 파일로 재사용할 수 없다. 운영 캐시·게임 실행은 없다.

새 `Nll.ControlCenterAppPackage.ps1`은 전체 app/HTML/CSS/JS와 의존성을 봉인하고
기존 presentation/이미지는 보존한다. 추가 파일은 복원 시 삭제하지 않고 패키지에
회수한다. 합성 51 assertions로 반복 적용/복원·중간 파일 상태·drift/동시 실행 거절을
확인했다. 실제 앱 배포에는 별도 cold/startup interlock과 새 pipeline activation이
필요하다. `prepare-nll-control-center-app-package.ps1`의 오프라인 리허설만으로
운영 설치·worker activation을 완료했다고 판단하지 않는다.
선택 약점 이미지 누락 fallback을 보완한 실제 Edge 합성 gate도 다시 통과했다.
로컬 inner catalog에서 39개 정확한 `MonsterImage` basename의 직접 key 후보는 0개다.
`BossImageReferences`의 5개 합성 검사는 통과했으나 atlas/별도 presentation 입력
직접 연결이 미해소였다. 직접 key 없음이 로컬 이미지 전체 부재를 의미하지는 않는다.
후속 운영자 승인으로 enikk.app의 exact 이미지 39개 요청을 수행해 **39시즌 모두**
연결했다(동일 PNG 내용은 SHA-256 기준 37파일로 중복 제거). S19는 원래 manager
미해소 상태로 남긴다. 결과는 `artifacts/boss-catalog-20260913/snapshot-enikk-1/`,
catalog SHA-256은 `3448b0e60dcf96e3cd6c85b4ff3aa2a2ccf831144f9c26962f6fdadf6d1f1bdc`다.
`materialize-nll-boss-catalog-images.py`의 합성 10개 검사를 통과했다. redirect/비 PNG/
CRC/이름/결박/입력 drift를 검사하고 runtime에서는 로컬 image endpoint만 사용한다.
실제 Edge에서도 이 카탈로그의 **39시즌 이미지 decode**, 40개 카드/선택 상세 1개,
No 0건·Yes 1건 및 JS error 0을 확인했다(`ui-preview-enikk-2`). HTTP job/preparation은
여전히 합성이며 게임 검증이 아니다. 첫 브라우저 probe는 S19를 미처리로 잘못
투영해 catalog가 fail-closed됐으며, probe를 실제 API와 같은 unresolved 투영으로
수정해 재통과했다. 원본 시즌 자료나 제품의 결손 처리 규칙을 바꾸지 않았다.
사진을 포함한 새 private 설정 `pipeline-3/configuration.private.json`의 SHA-256은
`0e571a789e0129146b7a50f75bb358230f0162071bb4f1d26d13c1db127fa6de`(972 pins)다.
생성은 worker 활성화나 운영 게시를 하지 않았으며 별도 S29 오프라인 재검사를 진행한다.
새 startup/deploy 공용 lease와 pending 복구 시 시작 차단, hash-pinned activation
reader는 PowerShell 7/Windows PowerShell 5 각각 11 assertions를 통과했다.
실제 설치된 Start script는 아직 교체하지 않았다. 최종 배포 트랜잭션에서 이 source와
activation의 사전 파일/부재 상태를 별도로 봉인해 앱 묶음과 함께 적용·원복해야 한다.

선택 FX/전체 UI package/사진/startup source `b9df93955b3634e99e9d07fcf2d7065c5e070080`은
Actions `34743072581` 3 jobs 모두 성공 후 PR #24로 병합됐다(main
`e23998d0ba75bfad67d66349d4a98e7a045d609c`). 후속 실제 S29 `pipeline-3`도 성공했다.
job `0f6387ed-ac2e-449d-ada6-04fe1386c66b`, candidate receipt
`01ae9df2d36bd33bdc5595c0b6eff0b6843f716b81c5f75384738f079cb7af37`, native chunk receipt
`6f09dd3cc9a021df654b1a7266f766e61a12bf7b7d36c72aea9fb76538e4417d`이며 재시작 replay/
owned tools 종료를 확인했다. **awaiting_runtime_delivery**이고 운영 registry/DB/게임/
배포는 변경하지 않았다. UI 실제 app 351→352 파일의 독립 복사본 적용·반복 원복도
통과했다(`app-package-1/receipt.json`, SHA-256
`ff4932d8bc78df82447ed8869187103078203e8a63f9e3f59e08ab73ff025664`). sealed package pin은
`22a4a38a0751b1fe18e6c0e0ebc7af146348faa35d708e7bf95d2988e573eedf`다.

후속 `Nll.ControlCenterDelivery.ps1`은 app package와 Start script/activation의 byte
백업·부재 상태를 묶어 적용/원복한다. 공용 lease와 pending marker로 혼합 상태의
시작을 차단하고 새 파일/완료 marker는 삭제하지 않고 회수한다. 합성 32 assertions와
WinPS5/PS7 startup 12 assertions(동명 pending 디렉터리 거절 포함)을 통과했다.
고정 설치 경계 wrapper `invoke-nll-control-center-delivery.ps1`은 prepare/inspect/
apply/restore만 제공하며 게임/DB/서비스/드라이버/hosts/CA/방화벽을 시작·중지·변경하지
않는다. 운영 설치 실행과 이 후속 소스의 CI는 아직 별도 완료 근거가 필요하다.

고정 길이 FX 생성과 청크 패키지 생성은 private 조사 스크립트에서 재사용 가능한
소스로 옮겼다. 실제 151 FX 3종의 전체 객체 대조, 원래 길이/offset 보존, exact
카탈로그 청크 3개와 압축 길이·압축 해제 결과를 검증했다. CIDX trailer도 일치한다.
`artifacts/native-fx-checks/fixed-layout-20260913/receipt.json` SHA-256은
`1344bdb7c934e1cb66f5d7a7cd330544bd819f44dff60db368381c77abe45437`,
청크 package private manifest SHA-256은
`a16c566144a58dd3de0e0cd33e21d4ba5fdb722d973280f19196d44d8afe4649`다.
원본 저장소 6,574,364,321 bytes의 hash는
`0745db76654f7d7059ae6777d0572520e23e825590c8a4fb3207f81bf58bf792`이며
읽기 전후 불변이다. **보정 청크는 원래 digest와 일치하지 않는다.** 패키지는 오프라인
후보일 뿐 native 수락·운영 설치·S29 admission을 주장하지 않는다.
리소스 합성 테스트 249개가 통과했다. 최초 sandbox의 임시 인증서 key 생성 실패
2개는 시스템 인증서 설치 없이 일반 운영자 환경에서 같은 테스트를 다시 실행해 통과했다.
독립 저장소 사본의 **전체 hash A→B→A·반복 원복·원복 후 후보 거절**도 통과했다.
사본 manifest pin은 `4440035314a2c9cdcc1342cbcfa038c5e190d2b27b79923d3085a825fc3ab184`,
보정 사본 hash는 `67777cb5b1134d26de0e0a4b5047624854b6927bfba5928aaddd7366a6200f39`다.
`artifacts/native-fx-checks/store-20260913/`은 현재 원본 hash로 원복된 오프라인 사본이며
보정된 실행 후보로 재사용할 수 없다. 새 합성 검사는 Python layout 15개(Windows
심볼릭 링크 권한에 따른 skip 1개)·store 10개와 C# 청크 23개다. 변경 후 Phase 3B-2
전체 baseline/계약 및 Actions 계약도 통과했다. 공통 publish/job/UI와 검증용 실행
연결·배포 및 소스 CI/병합은 아직 남아 있다. 사용자가 나중에 확인할 항목은
[신규 실게임 검증](operations/BOSS_NATIVE_USER_VALIDATION.md)에 분리했다.
후속 폐기 PostgreSQL **114/114**와 재시작 checkpoint/정리가 통과했다
(`artifacts/stabilization/lifecycle-postgresql/e145c57024b24942a0bac824d76b4e53/receipt.json`).
운영 DB를 사용하지 않았으며 마감 시 게임/서버/PG 프로세스 0개, 기존 v6 96개 파일과
runtime selection hash 불변을 다시 확인했다. 새 UI나 검증용 실행 구성은 아직 설치하지 않았다.

### 2026-09-13 관리자 실행·서비스 별도 관리 — 중단된 실험의 cold 원복 완료

운영자는 비관리자 강제를 중단하고 관리자 실행과 ACE 서비스의 별도 격리 관리를
승인했다. S26 기존 실게임 인수는 완료 상태이며 이번 시험은 이를 다시 검증하는
작업이 아니다. VM은 운영자가 게임 실행 거부 이력을 확인하여 대안에서 제외했다.
정확한 범위는 [보안 경계](SECURITY_BOUNDARY.md)의 2026-09-13 승인을 따른다.

새 실행은 게임/서버의 동일 Job 종료와 ACE의 SCM 신원·종료를 분리하고, ACE 폴더의
실행 파일도 외부 통신 차단에 포함한다. `Nll.NativeFxManagedService.ps1`의 합성
55개 검사와 변경 후 Phase 3B-2 전체 baseline/계약 및 Actions 계약이 통과했다.
PostgreSQL 실제 integration은 이 호출에 포함되지 않았다. 첫 준비
`896aeaec-ca33-4b3d-b7e5-7345149b4ff4`는 OrderedDictionary 정렬 때문에 차단 목록이
축소되어 사전 검사에서 중단됐다. 정확한 경로별 pin 병합/충돌 검사로 수정하고
실패 봉인은 보존했다. 이 준비에서는 게임/시스템 설정을 변경하지 않았다.

실제 실행 `4ee1395c-78ff-4df5-8429-c5d3f6b257bd`의 계획 SHA-256은
`9caf5b9f70a23bef7129ce099cd958c53f8936ce3f22312275fcc9b47706d986`이다.
26개 프로그램 차단 사전 검사 후 UAC로 실행됐다. 관리자 토큰 때문에 중단한 것이
아니라, `ACE-ADVT` 커널 드라이버가 사전 `Stopped/Manual`에서 `Running/Manual`로
바뀌어 `resource_native_fx_managed_driver_state_drift`로 중단했다. 기존 `ACE-BASE`는
사전부터 `Running/Manual`이었다. Job 종료는 확인했고 ACE 사용자 모드 서비스도
Stopped/PID 0이지만, 드라이버 비교가 설정 복구를 먼저 막아 최초 receipt의
scopedRollbackVerified/serviceStartModeRestored는 false다. ACE 서비스 실행 신원
receipt는 기록되기 전 중단됐으므로 서비스 수명주기 실제 검증 완료를 주장하지 않는다.

첫 별도 UAC cold 복구에서 hosts/음성/서비스 `Manual/Stopped` 원복을 확인하고,
드라이버 승인 전에는 임시 방화벽 26개를 유지했다. 해당 부분 복구 receipt는
`cold-managed-recovery-07844f27e7a147459efd4d98b09b6efd.json`으로 보존한다.
운영자의 후속 명시 승인 뒤 `ACE-ADVT` 하나에만 Windows 정상 중지를 요청하여
2026-09-13 11:06 KST에 `Stopped/Manual`로 복원했다. 기존 `ACE-BASE`는 계속
`Running/Manual`이며 드라이버 byte/ACL·시작 유형 및 원본 DLL은 변경하지 않았다.
`cold-managed-recovery-1bcde6a2d85647679e7e4d102f9479c1.json`은
settingsRestored/driverBaselineRestored/firewallRulesRemoved=true, failure=null이다.
독립 읽기 검사에서 사전 드라이버 상태 일치, hosts/음성/서비스 원복, 관련 프로세스
0개·해당 임시 방화벽 0개 및 ACE-ADVT hash 불변을 확인했다. 이미 종료된 Job의
증거를 새로 주장하지 않으며 liveJobZeroObserved/physicalFxRetirementClaimed=false다.
최초 실행 실패를 이 cold 원복 성공으로 덮어쓰지 않는다.

후속 private runner는 드라이버 불일치가 있어도 이미 종료된 사용자 모드 대상의
hosts/음성/서비스 설정 복구는 수행하고, 방화벽 제거 직전에 드라이버 상태를 검사한다.
실제 runner cleanup 본문을 호출한 합성 12개(일치 성공/불일치 시 설정 복구와 차단 유지)가
통과했다. 기존 봉인 실행에는 이 수정을 덧씌우지 않았다. **이번 중단 실행의 cold
원복은 완료했다. 보정 FX 미적용이며 계획 1~6 및 서비스/드라이버를 포함한 새
자동 실행·원복 경로의 인수는 미완료다.** 드라이버 정상 중지 승인은 이번 복구에
한정하며 임의의 후속 드라이버 실행/중지 허가로 확대하지 않는다.

앞선 권한 분리의 마지막 실행 `8301a6c0-f275-4339-9d49-58b2aa43f16f`는 첫 nikke.exe가
medium primary token으로 생성된 뒤 약 9초 후 다른 PID의 관리자 nikke.exe가 나타났음을
관측했다. 후속 실행 요청 주체는 확정하지 않았다. 해당 실행은 Job/서비스/설정 원복을
완료했다. 아래 권한 낮추기 계획은 과거 조사 기록이지 현재 재개 지시가 아니다.

### 2026-09-13 이전 권한 분리·native 승격 조사 기록

관리자 owner의 자체 연결 토큰으로 CreateProcessAsUserW를 호출하는 대안은 거절됐다.
진단 실행 `e573753b-8981-44e1-99e4-58e5d7a11d14`는 반환 토큰이 medium/비승격이어도
TokenType=2, ImpersonationLevel=1(식별용)이며, 실패 API가 CreateProcessAsUserW,
Win32 오류가 1346임을 확인했다. 자식 생성 전 실패했고 Job 잔류는 0이다.
이를 일반 사용자 게임 실행 실패나 서비스 변경 주체의 증거로 해석하지 않는다.
추가 권한 부여나 다른 프로세스 토큰 취득 대신 **처음부터 일반 사용자 실행기가
Job 생성·원자적 자식 편입을 맡고, 관리자 감시자가 같은 Job을 열어 종료하는 구조**를
합성 프로그램으로 검사했다. 관리자 토큰 변환 API는 이 성공 경로에서 호출하지 않는다.

`artifacts/native-fx-runtime-20260912/medium-tests/ffb20926-6189-4c07-b4a1-1f9a20f95437/`
의 broker.receipt.json은 11개, watcher.receipt.json은 18개 검사를 통과했다.
동일 운영자·세션의 일반 사용자 primary token으로 자식/손자가 실행되고, 각각의
콘솔 호스트까지 총 4개 프로세스가 같은 Job에 소속됨을 확인했다. 네 구성원 모두
medium/비승격이며, 관리자 감시자의 TerminateAndWait 후 동일 Job 잔류는 0이다.
반복 Start 거절과 없는 exe의 오류 2/잔류 0도 포함한다. 앞선 두 테스트 실패는
콘솔 호스트를 제외한 예상 개수 2 때문이며 실패 receipt를 보존한다.
이 성공의 script SHA-256은 `c451ef181dd1f5c5f52fe8f7f12720c233f50f35654aa7ccad7933d48ec84342`,
기존 Job 소스 SHA-256은 `d5067d04a85a965d6bbfa875451f1448c3dc75a8fe0af3f26ed67b628bba9639`다.
게임·서비스·시스템 설정은 이 합성 테스트에서 변경하지 않았다.

이후 별도 hash pin과 permit 대기 120초/실행 280초 한계를 가진 일반 사용자 실행기를
private trial runner에 연결했다. 관리자 격리 완료 전에는 자식을 만들지 않으며, 종료 시
같은 Job 잔류 0 및 실행기 종료를 확인한 뒤 설정을 복원한다. 읽기 전용 토큰 helper는
자체 primary token 반복 조회·오류 API/PID/Win32 코드·합성 권한 필드 거절 64개 검사를 통과했다.
실행 `c186b137-dd21-4dfb-8523-2e5b271df389`는 4개 실제 scoped process의 medium
primary token을 확인한 뒤 다른 프로세스의 권한 검증에서 중단됐다. 당시 정확한 예외
정보가 없어 원인을 추정하지 않는다. Job 잔류 0·실행기 종료·서비스 Manual 원복 및
hosts/음성/임시 방화벽 복원이 통과했다. 후속 계획은 실패 프로세스/토큰 snapshot 또는
조회 API/Win32 오류를 보존한다. 이 단계는 아직 서비스 drift 해소나 native FX 수락
증거가 아니며, 기준 접속과 원복 확인 뒤 보정 FX/전투/원복 및 계획 2~6으로 이어진다.
후속 실행 `1e77f88b-11ff-4fb1-964a-fd3dd10e7975`의 token-failure.private.json은
격리 사본 **nikke.exe의 실제 토큰이 ElevationType=2/Elevated=1/IntegrityRid=12288**임을
확인했다. 이때 실패는 조회 API/Windows 오류가 아니라 RequireMedium의 판정이다.
앞선 4개 scoped process는 medium primary token 검증을 통과했으며 bootstrap PID도
그 안에 있다. 어떤 지점에서 관리자 권한이 선택됐는지, 자체 재실행인지는 아직 미확인이다.
실행 계획 SHA-256은 `11f4667c0945e474f35fbccb5bc63797c496edb6a8b08880653052fe281d8691`,
runner SHA-256은 `7043a8126d402f062bf28f93813e679375a496ad27cbce0a9926e2e5aed8bf4e`다.
treeZeroVerified/scopedRollbackVerified/serviceStartModeRestored 및 brokerExited가 모두 true다.
HKCU/HKLM AppCompatFlags/Layers의 정확한 사본 exe 항목은 없었고, 관측 shell의
Process/User/Machine __COMPAT_LAYER도 비어 있었다. 이는 native bootstrap 실행 중
환경이나 thread/process token 변화까지 배제하는 증거는 아니다. 봉인 exe·GameAssembly·승인 sodium의
직접 runas/ShellExecuteW 등 제한된 문자열 검사에서도 일치가 없었지만 호출 부재 증거는
아니다. 다음 조사는 원본 프로그램 수정 없이 bootstrap의 Process.Start 직전/직후
권한·환경·반환 PID/생성 시각을 private receipt로 결박하여 승격 지점을 좁히는 것이다.
권한 검사를 해제하거나 관리자 게임을 이 기준 실행의 성공으로 처리하지 않는다.
NATIVE_FX_PROBE 전용 관측 코드를 추가하고 빌드/합성 61개 검사를 통과했다.
게임 시작 호출 전후 부트스트랩의 process/thread token, 허용된 호환성 플래그만의
존재 여부, 반환된 자식 PID/생성 시각/권한을 private receipt로 남긴다. Windows token,
원본 게임, 승인 DLL은 변경하지 않는다. source-only 관측 helper는
`tools/Phase3B2/NativeFxBootstrap/ExecutionTokenObservation.cs`이며 일반 실행 모드에
이 관측을 켜지 않는다. 시험 `f1b4cabf-431b-429b-af53-2f7f9efbd013`은 UAC 응답 대기 중
실행기의 120초 permit 제한이 만료됐다. broker.exit.json의 failureCode는
fx_broker_permit_timeout, jobZero=true, systemSettingsChanged=false다.
이후 관리자 실행 요청도 취소 오류로 종료됐고 owner PID는 null이다. 게임 시작/새 관측은
수행되지 않았으며 서비스는 계속 Manual/Stopped다. 이 실행 계획을 재사용하지 말고,
운영자가 UAC 승인 가능한 시점에 새 assessment를 준비한다. 앞선 native 승격 원인은
이번 대기 만료로 해소되거나 더 특정된 것이 아니다.
후속 오프라인 보완에서 전후 관측 기록을 동기 쓰기로 변경하여 관측과 Process.Start
사이에 await로 스레드가 바뀌지 않게 했다. 같은 OS thread ID/권한 상태, 기록된 반환
자식 신원, 기존 receipt 덮어쓰기 거절·원본 byte 보존을 추가해 합성 검사는 68개다.
새 부트스트랩 빌드도 통과했으며 UAC나 게임은 다시 실행하지 않았다. 종료된 시험
f1b4cabf의 봉인 파일은 변경하지 않았고, 이 보완은 다음 새 assessment에만 들어간다.
이번 Phase 3B-2 전체 baseline/계약 검사는 통과했으며 실제 PostgreSQL integration은
이 호출에 포함되지 않았다. 운영 v6·원본 DLL·서비스 ACL은 변경하지 않았다.

### 2026-09-12 원본 길이 보존 FX 청크 — 오프라인 전달 후보

원본 151의 세 FX를 전체 재직렬화하지 않고, 검증된 기존 보정 산출물의 변경 Transform
객체 byte만 원래 위치에 대입한 메모리 내 후보를 검사했다. 화염/풍압/철갑의 변경
Transform은 4/6/4개이며 모든 객체 payload가 기존 보정 산출물과 일치한다. UnityFS의
메타데이터·객체 위치·전체 길이는 그대로다. 풍압의 기존 산출물에서 늘어난 16 bytes도
이 방법에서는 발생하지 않는다. 이미지/다른 객체/클라이언트 파일을 수정하지 않았다.

정확한 outer catalog/인덱스/원본 청크에 결박한 검사에서 각 FX의 변경은 0-based 5번
청크 하나에만 있으며, 각 청크를 참조하는 catalog file은 하나뿐이다. Zstd level 19로
보정 청크를 압축하고 skippable frame으로 원래 압축 길이 24,153/23,563/26,393 bytes를
맞춘 뒤, 메모리 내 압축 해제 결과가 각각 보정 내용과 완전히 일치함을 확인했다.
**원래 청크 digest는 수정 byte와 일치하지 않는다.** 길이가 같다는 이유로 원래 digest나
카탈로그 서명의 유효성을 주장하지 않는다. 클라이언트/공유 CDB/인덱스에는 적용하지 않았다.

봉인된 DLL의 디스크 명령 경계 35개는 lookup → 저장소 읽기 → 압축 길이 비교 →
ZSTD_decompress/출력 길이 확인의 후보 경로와 별도의 저장소 본문 digest 비교 경로를
구분한다. CBLB 헤더에도 앞 12 bytes의 Hash128 검사가 있다. 상위 FX asset-provider
전체 호출 경로·시작 시 전체 무결성 검사 실행 여부·수정 byte 수락은 아직 미검증이다.
소스 없는 결과는 `artifacts/native-delivery-static-20260912/fixed-layout-13ab6671de4844539b02715a5847095e.receipt.json`
(SHA-256 `0a840ffeddaf663a1010f77ae4159c83470842d55d120967d24b16e40300da0f`)이다.
이 증거는 다음 격리 실험의 후보를 구체화한 것이며 native FX 로딩이나 계획 1~6 완료가 아니다.

후속 기준 실행 `651c723a-9673-4c9d-952f-cfa6248b78bf`는 카탈로그/FX 무변경으로
시작했으나 `resource_native_fx_blocked_program_started`로 중단됐다. 정확한 신원
기록은 `C:\Program Files\AntiCheatExpert\ACE-Service64.exe`, Job 소속 false,
서비스 관리자의 자식임을 보여준다. 어느 프로세스가 서비스 시작을 요청했는지는
확인하지 않았다. 이전의 조회 예외와 같은 원인이라고 추정하지 않는다.
이번 자동 cleanup은 treeZeroVerified/scopedRollbackVerified=true다. 후속 읽기 검사로
hosts/음성 설정 원복·임시 방화벽 0·scoped process 0을 확인했다. 관련 서비스
`AntiCheatExpert Protection`은 Stopped/Manual이며 시작 유형을 변경하지 않았다.
조회 예외가 재현된 실행은 아니므로 새 진단 helper가 그 원인을 해결했다고 보지 않는다.
이 기준 실행에서는 guard 완화·서비스 설정 변경을 하지 않았다. 뒤이어 운영자가
해당 서비스 하나의 실험 중 `Manual`→`Disabled` 및 전체 종료 후 `Manual` 복원을
승인했다. [보안 경계](SECURITY_BOUNDARY.md)의 2026-09-12 승인으로 기록했으며,
이 승인 전 실행 receipt를 바꾸지 않는다. 정확한 서비스 신원·중지 상태·허용 전환과
종료 증거 없는 복원 거부·적용 후 예외 복구를 검사하는 합성 27개가 통과했다.
이는 새 서비스 변경을 포함한 native 재실행 성공 증거가 아니다.
후속 `913d1729-4c65-4de4-b1bb-6aa9d3034147`은 Disabled 적용 후 서비스 신원/정지
상태 변화로, `e1cf436b-a4b2-4ad3-bb0b-9792e63e84fb`는 서비스 시작 유형 변화로
중단됐다. 두 실행 모두 treeZeroVerified/scopedRollbackVerified/serviceStartModeRestored=true다.
후자의 `service-boundary.private.json`은 2026-09-12T14:58:12Z의 Disabled/Stopped
적용 이후 14:58:26Z에 **Manual/Stopped/PID 0**으로 바뀐 실제 snapshot을 보존한다.
누가 변경했는지는 특정하지 않았다. 서비스 시작 유형만 일시 변경하는 방법으로는
현재 격리가 유지되지 않으며, 다시 Disabled를 강제하는 루프나 guard 완화는 하지 않는다.
현재 서비스는 Manual/Stopped이고 FX/카탈로그는 미적용이다.

다음 안전한 조사 대상은 실행 권한의 분리다. 현행 관리자 owner의 CreateProcess →
trial-child → bootstrap → 원본 client 경로는 별도 일반 사용자 권한 전환이 없다.
격리 준비/복구만 관리자로 두고 동일 운영자의 일반 사용자 권한으로 자식을 생성하면서
생성 시점 Job 편입을 유지하는 방법을 검토한다. Microsoft의
[CreateProcessAsUserW](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessasuserw)
및 [TOKEN_LINKED_TOKEN](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-token_linked_token)
계약을 확인했지만 이 변경은 아직 구현·실험하지 않았다. 공식 credential 사용,
서비스 ACL/바이너리 변경 또는 별도 native patch는 이 대안에 포함하지 않는다.
추가 읽기 전용 점검에서 봉인된 원본 exe의 requestedExecutionLevel은
`asInvoker`/uiAccess=false이고, 현재 비관리자 운영자에서 OpenService의
SERVICE_CHANGE_CONFIG(0x2) 접근 요청은 Win32 5(access denied)였다.
서비스 DACL에는 관리자 그룹만 change-config 허용이 있지만 Everyone의 start/stop 등
다른 권한은 별도로 있으므로, Disabled 유지 및 실행 중 guard는 계속 필요하다.
이 점검은 서비스 설정·ACL을 바꾸지 않았고 일반 사용자 게임 실행 성공도 주장하지 않는다.
실행되지 않은 준비 실패 `d7ab6c9d-43b0-454f-a3d2-b0386f64781a`도 보존한다.
이 준비는 별칭 경로의 reparse 검사로 멈췄고, 새 실행은 Micron 실제 경로로 준비했다.

### 2026-09-12 카탈로그 형식 실험 — native 거절 및 cold 복구

**계획 1~6은 계속 미완료다.** 기존 NKDB의 복호 내용을 한 바이트도 바꾸지 않은
SQLite 형식 사본(무결성 검사 ok)을 만들어, 진단 복제본의 정확한 inner 카탈로그
한 파일에만 적용하는 실험을 수행했다. 새 DLL/패치/다운로드나 v6/운영 DB 변경은 없다.
원본/적용/백업 hash를 결박한 같은 디렉터리 원자적 교체 helper의 합성 21개가 통과했다.
사전 검사만 수행한 `7223418b-1758-4ed2-9aa2-f31005eefcaf` 봉인은 보존한다.
`4cdf6c97-cf0c-4c21-a436-dfa0a9cb1fb7` 실행은 차단 프로그램 시작 감지로 조기
종료됐고 자동 카탈로그·설정 복구까지 통과했다. 당시 신원 기록은 없어 원인을
특정하지 못했으며, 뒤의 실험 runner는 차단 신원 기록을 먼저 쓰도록 보강했다.

실행 `7b6d16b1-5ab1-4849-9df4-1f28d1f7815c`에서 변환 대상 파일의 OS 요청
5건/read 1건과 정확한 대상 경로를 지칭하는 `database disk image is malformed`
로그 4건을 결박했다. 로비 응답 Success도 있지만 **변환 카탈로그 수락 증거가 아니다.**
따라서 이 위치에 복호 SQLite만 바꿔 끼우는 전달 경로는 거절된 것으로 기록한다.
요약은 `artifacts/native-fx-runtime-20260912/format-trial-70ce2b78998641d489294a1a52e29210.receipt.json`
(SHA-256 `dc60af07a79642ede154c678db4b2105a8f179144e0a9fb919980cb0a50ecbc3`)이다.

이 실행의 자동 종료/복구는 OS process 신원 조회 예외로 중단됐다. 원래 실패 receipt를
보존하며, 아래의 앞선 성공 실행을 이유로 이 실패를 성공으로 바꾸지 않는다. 관측자
종료로 기존 Job도 소멸한 뒤 별도 UAC로 모든 scoped process/service/port cold를
확인하고 **선언된 카탈로그 한 파일과 임시 설정만** 원본으로 복구했다.
`cold-format-recovery.receipt.json`은 catalogOriginalRestored/scopedSettingsRestored=true,
liveJobProofClaimed/physicalFxRetirementClaimed=false다. 후속 읽기 검사에서도 원본
카탈로그·hosts hash, 음성 설정, 해당 임시 방화벽 0개를 확인했다.

재실행 전에 신원 조회 예외를 해소해야 한다. 기존 로그에는 내부 Win32 코드가 없어
원인을 추정하지 않으며, 실험 runner에 정확한 PID/생성 시각/단계별 신원 및 최하위
Win32 오류 기록을 추가했다. 아직 그 보강 이후 native 재실행은 하지 않았다.
추가로 조회 helper가 실패 API 이름과 PID를 보존하도록 분리하고, 사전 검사·관측·복구의
오류 기록을 각각 남기도록 했다. 합성 165개(빠른 종료 자식 50개 및 없는 Job의
OpenJobObject/Win32 오류 2 식별 포함)가 통과했으며, native 오류 원인 해소를 뜻하지 않는다.
실험 후 Phase 3B-2 전체 baseline·Actions contract·diff 검사와 설치 v6 96개 파일
hash/길이·선택 manifest·보스 등록 무변경 확인이 통과했다. 실제 PostgreSQL integration이나
보정 FX 수락 검증을 이번 후속 검사로 실행한 것은 아니다.
다음 전달 대안은 카탈로그를 바꾸지 않는 청크 경로의 실제 검증 규칙 조사다.
원래 chunk hash/서명을 변경 byte의 유효성 증거로 재사용하지 않고, 수정 가능성이나
native 수락을 검사 전에 확정하지 않는다.

### 2026-09-12 native FX 계획 1~6 — 기준 접속·자동 복구 확인

**계획 1~6은 미완료다.** 독립 151 진단 사본을 새로 만들고 원본과 사본의
1,155개 파일/20,430,837,649 bytes manifest 일치를 확인했다. 설치 v6와 공유 캐시를
바꾸지 않았으며 승인 sodium DLL도 그대로 사용했다. 준비 소스와 NativeFxBootstrap은
`agent/native-fx-load-rollback`의 작업 중 변경이며 아직 commit/배포/병합하지 않았다.

실험 자료는 `artifacts/native-fx-runtime-20260912/`, private 실행 증거는
`C:\NLL\Staging\NativeFxTrials\b5773fbb-214e-41b8-8c47-79257318fbe7\runs`에 있다.
실행 `914e2c80-554d-4b23-8e4b-1f530c098e93`에서 게임의 Job 소속은 true인데
CIM의 ExecutablePath가 null인 오판을 확인했다. 조회 전용
QueryFullProcessImageName/GetProcessTimes로 신원을 확인하는 실험용 경로를 추가했다.
게임 메모리 접근이나 새 native 패치는 하지 않았다.

후속 실행 `710a2a5e-920a-4c84-a25e-f93585ab10da`에서 원본 프로세스의 OS 파일
요청 11,840건(손실/overflow 0), catalog.ndb 7개와 동반 서명 7개의 접근을 관측했다.
**보정 카탈로그/FX 수락이나 렌더링 증거는 아니다.** 운영자 화면은 4/7에서 약 2GB의
추가 리소스를 요구했고 취소 후 필수 파일 안내가 나타났다. 로그는 VoiceDownloadProgress,
사전 음성 설정은 en/Minimal이다. 후속 읽기 전용 검사에서 EN payload는 없고
KO Minimal의 28,416개 압축 청크 hash·해제 길이 및 필수 파일 1,266개는 완전함을
확인했다. EN 필수 총량 2,100,284,494 bytes는 화면의 2,002.98 MiB와 일치한다.
다운로드를 승인하거나 외부 통신을 해제하지 않았다.

해당 실행의 자동 cleanup receipt는 실패 상태로 보존한다. 제한 시간 종료 뒤 별도 UAC
복구로 대상 process/port cold, hosts 백업 복원과 임시 방화벽 25개 제거를 확인했다.
`settings-recovery.receipt.json`은 **설정 복구** 증거이며, 이미 소멸한 Job의 실시간
잔류 0이나 FX 물리 정리 성공을 주장하지 않는다. 후속 실험 helper는 같은 OS process
handle에서 경로·생성 시각·Job 소속을 확인하고, 실제 signaled 종료만 무시하도록
snapshot/exit 경합을 수정했다. 빠른 종료 자식 50개를 포함한 합성 161개 검사가
5회 연속 통과했다. 이 helper는 아직 private 실험 소스다.

실행 `dc985e43-6903-4436-a056-34756f30b185`는 KO/Minimal을 임시 선택하여 로컬
로비 응답 Success에 도달했고 운영자가 접속과 튜토리얼 표시를 확인했다. 신규 합성
계정/별도 임시 DB이므로 튜토리얼은 예상된 상태이며 기존 운영 계정 초기화가 아니다.
OS 파일 요청 16,724건(130개 파일, read 요청 14,685건, 이벤트 손실/overflow 0)을
관측했다. 알려진 원본 프로세스/같은 Job에 결박한 **요청** 증거이지 성공 byte 전달이나
렌더링 증거는 아니다. 보정 FX는 적용하지 않았다.

동일 실행은 제한 시간 종료 후 자동 cleanup까지 성공했다. `execution.receipt.json`의
failureCode는 null, treeZeroVerified/scopedRollbackVerified는 true이며,
`tree-exit.json`은 2026-09-12T13:20:30Z 같은 Job의 activeProcesses=0을 기록한다.
후속 읽기 전용 검사에서도 임시 방화벽 0개, hosts 원본 hash 및 en/Minimal 사전
설정 복원을 확인했다. 설치 v6·운영 DB 변경은 없으며 nativeFxDelivery는 여전히
`not_assessed`다. 자동 설정 복구 성공을 보정 FX의 A→B→A 검증으로 승격하지 않는다.
추가 대조에서 export의 정확한 inner 본문/서명은 690/5건, outer 본문/서명은
1,440/5건 요청됐고, allowlist에 포함된 embedded 본문/서명은 이번 실행에서 0건이다.
이는 이 기준 실행의 관측이지 모든 캐시 우선순위나 미관측 파일의 영구 미사용 증거가 아니다.
요약은 `artifacts/native-fx-runtime-20260912/`의
`baseline-catalogs-e3f91aed62d44f2688ba9669f2f2519f.receipt.json`에 봉인했다.

### 2026-09-12 전체 트리 정리와 native 전달 잔여

**후속 CIDX 진척:** 정확한 디스크 명령 경계 22개로 헤더 12바이트 → 레코드별
28바이트 누적 Hash128 호출을 확인했다. 이전 결과를 다음 SpookyHash128의 두 seed로
쓰는 규칙이 core/dp/fd/saus/ko의 설치 인덱스 5개·454,494개 항목 모두 일치한다.
`ChunkIndexDigest`와 읽기 도구에 반영했으며 신규 합성 23개를 포함한 226개 검사가
통과했다. 증거는 `artifacts/native-delivery-static-20260912/`의
`index-rule-6efbc882c822441ea75e8c6846455440.receipt.json`이다. 아래 당시 기록의
‘CIDX trailer 미해소’는 이 결과로 대체하지만, 수정 카탈로그 수락·native FX 전달·
렌더링·A→B→A는 여전히 미완료다. 인덱스/카탈로그/DLL을 수정하거나 새 게임을
시작하지 않았다. 과거 후보/차단 receipt는 덮어쓰지 않는다.
변경 후 `verify-phase3b2.ps1`의 전체 baseline 체인과 Actions contract가 통과했다.
운영 PG integration은 실행하지 않았으며 단위/합성 검사를 실게임 판정으로 승격하지 않는다.
설치 v6의 96개 pin·선택과 보스 등록도 다시 일치했다. 이 변경은 아직 작업 트리에 있으며
commit/CI/병합 완료를 주장하지 않는다.

요청은 **1번 나머지(native 전달/rollback)와 2번 전체(트리 종료/정리)**다.
2번의 새 소스 경로는 원자적 Job 소속 → watcher 인계 → 같은 Job 잔류 0 검증 →
completion/rollback 및 선택적 FX 정리로 연결했다. runner input v3/bundle v2를 사용하고
구 v1 봉인은 보존한다. FX 복구는 receipt JSON만 믿지 않고 실제 Job을 query-only로
열어 확인하며, 비정상 빈 lease의 독점 접근과 proof hash 결박 후 private 사본만 정리한다.
Automation 83개(신규 9개), 실제 Windows Job 44개, capture/실패·복구 순서 38개,
FX 정리의 실제 Windows Job 합성 9개와 같은 9개 실제 materializer CLI 호출,
Python 63개가 통과했다. 설치 v6 96개 pin·선택·등록 보존도 재검증했다.
설치 v6/운영 DB/게임 실행에는 반영하지 않았다.

**1번 실제 native 전달은 아직 완료하지 못했다.** 정확한 디스크 호출 범위 검사에서
서명 실패/오류 분기를 확인했으나, 151 local provider 경로와 승인된 unchanged sodium의
수정 카탈로그 수락 경로를 입증하지 못했다. CIDX trailer도 미해소다. 원래 서명을 수정
내용의 검증 증거로 재사용하거나 새 native 패치를 추가하지 않았다. 입력 pin/명령 변조
대조 2개와 source-free blocker receipt는 `artifacts/native-delivery-static-20260912/`에 있다.

설치 선택 v6와 S29 차단은 유지한다. 신규 coordinator의 `executionFx`는 null이며
이전 HTTP 경로를 native 151 전달로 승격하지 않는다. 모든 Job 소유자 crash로 live
Job 증거를 잃은 미정리 실행은 fail closed한다. 물리 정리를 완료·봉인한 실행은 별도
checkpoint로 DB replay만 재시도하며, 과거 receipt로 물리 정리를 다시 허용하지 않는다.
배포/실게임 수신·화면·복구 인수도 미완료다.
다음에 남은 것은 위 native 전달 gate 해소와 격리 전달/rollback 검증이다. 그 뒤 v3
admission·게시/job API·UI를 진행한다. 상세는
[보스 파이프라인](features/BOSS_ONBOARDING_PIPELINE.md#native-delivery-blockers-and-whole-tree-retirement--2026-09-12)을 따른다.

### 2026-09-12 정확한 151 FX 오프라인 재결박

기존 후보의 내부 자산 키 → 내장/core 카탈로그 동일 의존 관계 → 설치 청크의 정확한
번들 → 실제 내부 키 왕복 검증을 구현했다. 전기 원본 포함 4개 모두 기존 후보와 byte가
다르며, 151 보정 3종의 Transform 변경 4/6/4개와 나머지 객체 보존을 확인했다.
신규 `stage-nll-native-fx.py`는 구 HTTP 파일명을 재사용하지 않고 새 private 후보만 봉인한다.
로컬 카탈로그/청크 합성 203개(신규 26개), Python 63개(신규 8개)를 통과했다.
최종 실입력 후보/설치 pin 검사는
`artifacts/native-fx-checks/eaca08be4a964de5b6d41125666d029f/`에 있다.
설치 v6 96개 pin·선택·보스 등록을 전후 보존했고 운영 DB/게임은 시작하지 않았다.

**1번 전체 완료는 아니다.** 이번에 닫은 것은 정확한 오프라인 자산 연결과 151 보정 후보다.
원본 클라이언트가 이 보정본을 읽는 실행별 청크/캐시 전달은 아직 미구현이다.
색인 trailer 의미도 미해소로 보존하며, 각 압축 청크 hash 검증과 이를 혼동하지 않는다.
다음은 해당 전달 방식과 검증/rollback이며, 이어 전체 process tree 종료·v3 admission·
게시/job API·UI 순서다. S29 차단과 설치 v6는 유지한다. 상세는
[보스 파이프라인](features/BOSS_ONBOARDING_PIPELINE.md#exact-151-native-fx-binding--2026-09-12)을 따른다.

### 2026-09-12 외부 Epinel FX 연결과 151 카탈로그 불일치

설치 v6와 기존 외부 소스를 보존하고 `.external/EpinelPS-fx-candidate`를 따로 빌드했다.
재적용 패치는 `patches/epinel-execution-fx-mount.patch`다. 시작 환경 6개/실행 binding을
검증하고 기존 자산 처리보다 먼저 FX를 전달하며, 거절 시 원본 cache로 fallback하지 않는다.
신규 startup 합성 12개(Automation 74개)와 실제 후보 DLL의 FX 3종 전체/range/HEAD·
실패 응답·기존 static-pack handler 및 검사 사본 정리를 통과했다. 설치 v6 96개 pin,
registry/profile·운영 DB·게임은 불변이다. Epinel Main이나 원본 게임은 실행하지 않았다.
최종 로컬 receipt: `artifacts/epinel-fx-checks/e1e2d66538cc423c8264b5503786129f/receipt.json`.

**후속 핵심:** 151 내장/core patch 카탈로그 양쪽에서 현재 FX 파일명의 exact 일치가
3종 모두 0이다. hash suffix를 제외한 이름은 각각 1개지만 이것으로 자산을 대체하지 않는다.
151 카탈로그에는 구 150 hash/CRC 필드 대신 `type_rowid,is_local`이 있다.
먼저 정확한 151 catalog→provider→bundle/캐시 경로를 재결박하고, 그 다음 전체 실행
process tree 종료와 비정상 lease 복구에 production 정리를 결박한다. 현재 3개 named
PID의 종료는 임의 descendant 종료 증거가 아니다. **S29 활성화·v3 admission·자동 게시·UI는
아직 보류**이며 HTTP 검사 성공을 원본 client 수신/화면 증거로 올리지 않는다.
상세와 재현 조건은 [보스 파이프라인](features/BOSS_ONBOARDING_PIPELINE.md)을 따른다.

### 2026-09-12 실행별 FX HTTP 전달 모듈

실행별 독립 FX 사본/봉인 → 정확한 raw 경로 HTTP 전체·range·HEAD 응답 → 사용 중 정리
차단 → 종료 후 private 사본만 정리·재시도를 구현했다. 기존 후보를 소비할 때는 전체
discovery/behavior/5속성/FX를 재검증하며, 같은 bundle의 중복 cache 경로는 거부한다.
신규 staging 합성 9개·.NET 19개와 실제 151 S29 보정 FX 3종 HTTP/정리 검사가 통과했다.
로컬 receipt는 `artifacts/execution-fx-checks/213e97bb4e134b7abd48eb11a9be9ad6/receipt.json`이다.
검사 중 만든 사본 6개만 지웠으며 후보에서 새 실행 폴더로 다시 생성할 수 있다.
설치 v6 96개 pin·registry/profile·운영 DB/게임은 불변이고 S29 차단도 유지한다.
**완료는 전달 모듈/사본 정리이며 설치 Epinel 연결·원본 client 수신/표시 완료가 아니다.**
당시 다음은 새 외부 Epinel 후보의 source-link/startup 연결, coordinator의 전체 process-tree 종료
gate와 정리 결박, 원본 client 캐시/catalog/CRC 조사다. HTTP `no-store`만으로 native cache
우회를 주장하지 않는다. 비정상 종료 후 남은 `.lease`는 PID만 보고 자동 제거하지 않는다.
연결/조사의 후속 결과는 위 절을 따른다. 그 후 v3 admission·원자적 게시/job API·시즌 선택 UI를 진행한다. 아래 절의 ‘다음 작업’은
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
  [UI-RAID-01](STABILIZATION_PLAN.md#ui-raid-01--시즌-목록과-선택-보스-설정-화면-분리)의 화면/이미지는 구현·설치 완료.
  최신 시즌 확인 및 사용자 화면 인수, native 전달을 포함한 최종 import 완료 조건은 남음.
- S29 profile v3와 registry v2 불일치, 미완료 속성 실드 확장
- 신규 보스와 전투 분석 UI 등 기능 추가

## 상세 근거

- [151 대응·배포·검증 이력](archive/RESOURCE_COMPATIBILITY_151_PROGRESS.md)
- [백엔드 결함 이력](features/CONTROL_CENTER_BACKEND_DEFECTS.md)
- [솔로레이드 영속화·분석 필드](features/SOLO_RAID_PERSISTENCE_AND_ANALYTICS.md)
- [이전 인계 전체 기록](archive/HANDOFF_2026-09-06.md)

과거 문서의 ‘다음 실행’, 오래된 OS 경로, 당시 blocked 판정을 현재 작업 지시로 재사용하지 않습니다.
