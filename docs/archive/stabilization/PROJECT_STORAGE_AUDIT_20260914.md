# 프로젝트 전체 용량과 정리 후보 — 2026-09-14

> 2026-09-27 보관: 작성 당시의 기록이며 현재 작업 지시가 아닙니다. 현행 문서는 [문서 색인](../../README.md)에서 찾습니다.

운영자 요청: P1과 함께 프로젝트 전반의 불필요한 공간, 특히 S29 추가 과정의 산출물을
조사한다. **2026-09-14 작업은 조사이며 삭제·이동·압축·ACL 변경은 0건이었다.** 아래 과거 후보는
일괄 삭제 승인 목록이 아니다. 이후 승인된 삭제는 다음 완료 절에 따로 기록한다.
과거 [용량 감사](STORAGE_CLEANUP_AUDIT.md)의 수치/경로를
현재 상태로 재사용하지 않고 새로 측정했다.

## 2026-09-15 실험 client 두 폴더 삭제 완료

운영자가 디스크 잔여량을 지적하며 정리를 지시하여, 앞서 조사한 **FxProbe와
UserValidation 두 폴더만 삭제했다.** 아래 참조 재확인 절의 보류 상태는 이 완료 기록으로
대체한다. 기타 저장소/실행 산출물이나 D: 백업까지 삭제 범위를 확대하지 않았다.

- 삭제: `C:\NLL\Clients\NIKKE-151.8.5-FxProbe-b5773fbb-214e-41b8-8c47-79257318fbe7`.
- 삭제: `C:\NLL\Clients\NIKKE-151.8.5-UserValidation-6d0c2fbd-edb4-4d07-a6dd-5f32218e9a85`.
- C: 여유 공간: **20,391,817,216B → 60,649,078,784B**(약 18.99 → 56.48GiB).
- 작업 전후 관측 여유 증가: **40,257,261,568B**, 약 **37.49GiB**. 볼륨 전체 여유의
  시점 차이이므로 다른 프로세스의 작은 동시 변동까지 삭제 회수량이라고 단정하지 않는다.
- 삭제 직전에 정확한 allowlist/해소 절대 경로/부모 `C:\NLL\Clients`와 reparse 없음,
  파일 수·논리 길이 일치, 관련 실행 프로세스 없음을 확인했다. PowerShell의
  `Remove-Item -LiteralPath`만으로 대상별 삭제 후 부재를 확인했다.
- ResourceProbe, v8/v6 bundle, 실행 선택 포인터, 활성 보스 설정과 공통 registry를
  보존했다. 선정한 해당 파일 및 현 client 실행 파일/DLL의 삭제 전후 hash가 일치했다.
  게임 실행·음성 변경·DB 작업·ACL 변경은 하지 않았다.
- `C:\NLL\Staging`과 저장소의 과거 계획/실패/복구 기록은 보존했다. 이것은 과거 실패
  실험의 성공 판정이 아니다. 퇴역한 구형 실험을 재실행하려면 client를 새로 구성해야 한다.

실행 스크립트: `artifacts/common-boss-execution-20260914/retire-unused-clients-20260915.ps1`.
사전 파일 목록·진행·완료 근거:
`artifacts/common-boss-execution-20260914/client-retirement-af664c4c534e46c4a0bf3767fef1aace/`.
`retirement.receipt.json`의 상태는 `retired`, 삭제 폴더 수는 2다.
삭제 후 현재 S26/수냉 및 S29/수냉(작열 보정 FX) 읽기 전용 준비가 모두 `ready`였다.
저장소 정책 검사와 `git diff --check`도 통과했다. 실게임 재검증을 수행한 것은 아니다.

## 2026-09-15 두 실험 client의 참조 재확인

운영자가 `C:\NLL\Clients`의 validation/fxprobe를 참조하는 곳이 없으면 삭제하고 싶다고
요청했다. 아래는 삭제 전 해당 두 폴더만 다시 조사한 당시 결과다.

| 폴더 | 현재 파일 수 / 논리 byte | 현재 실행 참조 | 남은 참조 |
| --- | ---: | --- | --- |
| `NIKKE-151.8.5-FxProbe-b5773fbb-214e-41b8-8c47-79257318fbe7` | 1,167 / 20,430,863,687 | 활성 그래프에서 0 | 과거 NativeFxTrials의 trial/observer/복구 계획. 일부 복구는 settings만 확인하고 physical retirement는 주장하지 않음 |
| `NIKKE-151.8.5-UserValidation-6d0c2fbd-edb4-4d07-a6dd-5f32218e9a85` | 1,154 / 20,430,834,145 | 활성 그래프에서 0 | 이전 앱 설정 백업에 구형 실험 전달 경로가 남음. 현재 실행이나 v6 런타임 복원 자체의 필수 입력은 아님 |

논리 크기 합계는 40,861,697,832B(약 38.06GiB)다. 이번에는 압축·hardlink를 반영한
실제 회수량을 재측정하지 않았으므로 이 값을 디스크 여유 증가 예상량으로 쓰지 않는다.
두 폴더 내부의 reparse 항목은 0개였으며, 조사 시 해당 client 실행 프로세스는 없었다.
현재 게임용 ResourceProbe는 별도 폴더이며 계속 보존한다.

현재 runtime-selection(v8), boss-pipeline activation, deployment receipt, 공통 registry를
시작점으로 53개 JSON을 읽었고 그래프 읽기 오류는 0개였다. 두 폴더에 대한 활성 참조는
0개다. 이전 9월 14일의 “UserValidation은 현재 다섯 전달 계획이 참조” 판정은 이제
**현재 실행에는 해당하지 않으며, 이전 실험 기능을 다시 사용할 때만 해당한다.**

UserValidation의 구체적인 원복 참조 경로:

`install/restore-common-installation.ps1` → app-delivery restore →
`install/app-delivery/before/boss-pipeline.active.json` →
`artifacts/validation-preflight-20260914/pipeline-1/configuration.private.json` →
`C:\NLL\Staging\NativeFxUserValidation\6d0c2fbd-edb4-4d07-a6dd-5f32218e9a85\delivery\5beeacc3-5d61-4c56-afb4-bdd911ea5912\delivery.private.json` →
과거 entry/bootstrap/store의 UserValidation client.
위 `install/`은 `artifacts/common-boss-execution-20260914/install/` 기준이다.

운영자 지적 후 실제 복원 코드까지 재확인했다. `Nll.ControlCenterDelivery.ps1`의 restore는
앱 파일과 before 설정을 되돌리며 UserValidation client를 열거나 검증하지 않는다.
v6/v8의 정상 게임 경로는 둘 다 ResourceProbe다. 따라서 위 경로는 **이전 앱 설정을
복원한 뒤 구형 UserValidation 기능을 다시 실행할 때의 조건부 의존성**이다.
이를 “이전 구성으로 돌아가려면 이 20GB 사본을 반드시 보존해야 한다”로 해석한 것은
과도했다. 과거 설정·기록의 문자열 참조 자체를 현재 보존 요구로 삼지 않는다.

FxProbe의 과거 driver/catalog 실패에는 별도 성공 복구 기록이 있으나,
`710a2a5e-920a-4c84-a25e-f93585ab10da`와 `c67161fb-5d1f-47d6-8b5e-19b1773b3930`의
`settings-recovery.receipt.json`은 `physicalFxRetirementClaimed=false`다.
이는 현재 시스템에 문제가 남았다는 증거가 아니라, 전체 실험 퇴역을 완료했다고
판정할 자료가 아니라는 뜻이다. 복구 성공 범위를 확대 해석하지 않는다.

결론: 두 폴더 모두 현재 게임 실행 입력에서 빠진 과거 실험용 정리 대상이다.
UserValidation을 정상 실행/런타임 원복을 위한 필수 보존 대상으로 분류하지 않는다.
정리 시 실제 실행·복구 작업의 잔류와 링크를 확인하되, 작은 과거 설정/기록을 남기는 것과
20GB client 사본을 계속 유지하는 것은 구분한다. 이번 재확인에서는 파일을 삭제하지 않았다.
최신 활성 참조 근거는 `artifacts/common-boss-execution-20260914/client-retirement-references-20260915.private.json`이다.

아래 표와 보존 목록은 2026-09-14 조사 당시 상태다.

## 측정 범위와 한계

저장소, `C:\NLL`, `D:\NikkeLocalLab\Backups`를 파일 메타데이터로 조사했다.
공식 `C:\NIKKE`, 별도 OS의 `E:\NIKKE`, 다른 개인 폴더는 조사하지 않았다.
160개 reparse/junction은 따라가지 않았고 volume/file ID로 확인 가능한 hardlink 중복을
제외했다. 표의 저장량은 GetCompressedFileSizeW 기반으로 압축을 반영한 조회값이다.
볼륨 전체 여유 공간 변화나 삭제 시 회수량을 보장하는 수치는 아니다. 상하위 표는 중복된다.

첫 측정의 권한/긴 경로 누락을 발견해 관리자 읽기와 긴 경로 지원으로 다시 측정했다.
최종 파일 열거 누락 디렉터리는 0개다. 단, 이관 staging의 96,413개 파일은 저장량
조회가 여전히 실패했다. 해당 저장량 및 이를 포함한 합계는 **확인된 하한**이다.
이를 숨기거나 ACL/소유권을 변경해 읽지는 않았다.

| 범위 | 파일 수 | 논리 크기 GiB | 조회된 저장량 GiB |
| --- | ---: | ---: | ---: |
| 저장소 | 106,983 | 39.013 | 39.013 |
| C:\NLL | 343,373 | 238.204 | 161.782 이상 |
| D:\NikkeLocalLab\Backups | 253,174 | 309.863 | 309.863 |

빌드 검사와 동시에 조사했으므로 재생성되는 bin/obj의 수치는 시점 값이다. 소스와 데이터
내용을 전체 해시한 감사는 아니다. 디렉터리 이름만 보고 복제/쓰레기라고 판정하지 않는다.

## 우선 정리 검토할 후보

아래 상대 경로는 저장소 루트 기준이다. 첫 두 파일은 서로 겹치지 않아 합계 약
**12.246GiB**다. 나머지 항목은 복구/참조 조건이 다르므로 무조건 합산하지 않는다.

| 후보 | 저장량 GiB | 확인한 근거 | 삭제 전에 남은 확인 |
| --- | ---: | --- | --- |
| `artifacts/native-fx-checks/store-20260913/store.cdb` | 6.123 | 오프라인 왕복 시험 사본. verify/restore/repeated restore 성공 receipt, 게임/설치 변경 false. 활성 참조 그래프에서 미발견 | 현재 hash와 보존한 원본/재생성 입력 확인; 작은 manifest·시험 receipt 보존 |
| `artifacts/boss-catalog-20260913/selected-fire-store/store.cdb` | 6.123 | 단일 FX 역할의 오프라인 왕복 시험 사본. 동일한 복원 시험 근거. 활성 그래프에서 미발견 | 위와 동일. 해당 폴더 전체나 pipeline 원본을 삭제 대상으로 확대하지 않음 |
| `C:\NLL\Clients\NIKKE-151.8.5-FxProbe-b5773fbb-214e-41b8-8c47-79257318fbe7` | 18.745 | 과거 FX 실험용 별도 client. 현재 S26/새 전달 구성에서 참조 미발견 | 과거 실행별 복구 필요 여부·최종 복구 receipt 대조 후 퇴역. 일부 settings 복구만으로 전체 복구를 가정하지 않음 |
| `artifacts/boss-catalog-20260913/app-package-1` ~ `app-package-4` | 합계 1.275 | 현재 활성 그래프에서 해당 패키지 직접 참조 미발견 | 설치/rollback receipt별로 마지막 복구 패키지와 source-free 증거를 보존하고 중간 빌드만 선별 |
| 저장소 `src`/`tests`/`tools` 아래 bin/obj 134개 | 합계 1.365 | 재생성 가능한 일반 build output 후보 | 실행 중인 검사 종료, 외부 DLL 입력/봉인 tool 참조 제외 후 정확한 경로 목록 확정 |

두 store 사본의 각 논리 byte length는 6,574,364,321이다. 시험 receipt의 원본 hash는
동일하지만 후보 hash는 서로 달랐다. 현재 내용이 같은지 새로 해시하지 않았으므로
동일 파일 두 개라고 단정하지 않는다. 후보 선정 이유는 완료된 오프라인 시험 사본이라는 점이다.

## 용량은 크지만 별도 퇴역/보존 판단이 필요한 항목

| 범위 | 용량 | 판단 |
| --- | --- | --- |
| `C:\NLL\Migrations\SamsungToMicron\v1\265861b9-9ff0-4e01-b409-7ce97c53aad1` | 논리 120.922GiB, 조회 저장량 53.297GiB 이상 | 가장 큰 추가 조사 대상. S29 전용 산출물이 아니다. 이관 완료 기록과 별개로 payload·복구 원본·현재 경로 의존·백업 대응을 확인해야 함 |
| `C:\NLL\ControlCenter\staging\application-repairs` | 저장량 10.112GiB | 76개 중 matching receipt 52개, receipt 미발견 24개, exporter 존재 72개. exporter와 before 복구 이미지가 섞여 있어 전체 삭제 금지. receipt 존재 자체가 성공 증명도 아님 |
| `artifacts/automation/phase-d-executions` | 저장량 7.793GiB | 57개 실행 폴더 중 completion.output.json 존재 30개. 계정/진행도 파생 입력, 완료·실패·복구 근거가 섞임. 종료/보존 정책으로 실행별 선별 필요 |
| `.dotnet-cli-home/.nuget`, `.nuget-packages`, `.tmp-dotnet-cli-home/.nuget`, `.tmp-dotnet-home/.nuget` | 약 1.484 / 1.341 / 0.391 / 0.297GiB | 여러 package cache 후보. 현재 환경변수·복원 설정·오프라인 재빌드 요구를 대조해 통합할 대상이며 폴더 이름만으로 삭제하지 않음 |
| `.tmp-dotnet-sdk-10.0.400`, `.tooling` | 약 0.752 / 0.399GiB | 현재 빌드/UnityPy 도구 참조 가능. SDK/도구 재사용 지점을 확인한 뒤 정리 |
| D: 프로젝트 백업 전체 | 약 309.863GiB | 복구 권위. 이번 정리 후보로 지정하지 않음. 이관 staging과 같다는 사실도 아직 입증되지 않음 |

## 현재 보존할 항목

- `C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe`: S26의 선택된 정상 client, 저장량 18.745GiB.
- `C:\NLL\Clients\NIKKE-151.8.5-UserValidation-6d0c2fbd-edb4-4d07-a6dd-5f32218e9a85`:
  저장량 18.745GiB. 현재 다섯 전달 계획이 참조한다. P2~P5 통합·퇴역 전 삭제하지 않는다.
- `C:\NLL\Runtime\EpinelPS-151-UserValidation`: 전체 약 0.638GiB. 구/신 assessment가
  혼재하므로 통째로 정리하지 않는다. 현재 참조 집합과 과거 복구 필요성을 각각 확인한다.
- 활성 `PhaseD151-v6`, fallback/rollback 구성, ControlCenter DB/state/secrets 및 현재
  pipeline configuration과 그 도구/입력. `artifacts/boss-catalog-20260913` 전체는 활성
  materializer 등의 참조를 포함하므로 통삭제 대상이 아니다.
- `C:\NLL\EpinelPS\EpinelPS\bin`: 약 36.362GiB 저장량에는 공유 native cache가 포함된다.
  일반 bin/obj cleanup에 넣지 않는다. junction 여러 개를 별도 사본처럼 합산하지 않는다.
- 작은 manifest, source-free receipt, 실패/복구 기록은 대용량 사본 퇴역 후에도 보존한다.

## 활성 참조 대조와 신뢰 범위

runtime-selection, boss-pipeline activation, deployment receipt를 시작점으로 138개 JSON을
읽었다. delivery의 trial/assessment에서 파생되는 entry 경로도 실제 reader 규칙으로
포함했다. 이 보완 전 단순 경로 문자열 조사에서는 현재 UserValidation client를 놓쳤다.
보완 후 해당 client가 다섯 parent/bootstrap/store 계획에 결박돼 있음을 확인했다.

위 그래프에서 미발견은 전역적으로 미사용이라는 증명이 아니다. 코드의 파생 경로,
과거 복구, 활성 프로세스의 열린 파일, 외부 도구 의존은 별도다. 이 때문에 후보와
즉시 삭제 가능 목록을 구분한다. 실제 삭제 시에는 현재 pin/프로세스/복구를 재확인한
정확한 파일 목록, 예상 회수량, 보존 근거를 제시하고 승인된 대상만 처리한다.

## 재발 방지 작업

- 오프라인 대용량 왕복 시험은 성공 후 작은 receipt와 재생성 입력을 보존하고 임시 전체
  사본을 퇴역할 수 있는 명시적 정책을 둔다. 실패 사본은 성공 정책으로 지우지 않는다.
- 보스마다 전체 client를 복제하지 않는다. 기존 실행별 변경/복구 기능을 공통화한다.
- 중간 app build, exporter, 종료된 실행 runtime의 보존 수와 복구 기준을 정의한다.
- cleanup은 공통 참조·수명주기 검사에 연결한다. 날짜/파일명/용량만으로 자동 삭제하지 않는다.

원시 조사 자료와 읽기 전용 재현 스크립트는 Git 제외
`artifacts/common-boss-execution-20260914/`에 있다: `storage-scan.ps1`,
`storage-scan-final.private.json`, `storage-references.ps1`, `storage-references.private.json`.
앞선 부분 측정도 보존했다. 이번 측정에서 새 전체 게임/저장소 사본은 만들지 않았다.
