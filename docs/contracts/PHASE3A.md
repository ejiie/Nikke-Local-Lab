# Phase 3A — original-client compatibility evidence audit (historical)

> 단계별 계약·검증 기준입니다. 이 문서의 과거 실행 판정과 현재 151 운영 상태를 구분합니다. 현행 진척은 [인계 요약](../HANDOFF.md), 작업 우선순위는 [안정화 계획](../STABILIZATION_PLAN.md)을 확인합니다.

## 결과

상태: **감사 완료 / 역사적 `blocked_insufficient_evidence`**

이 판정은 구현 실패가 아니라 당시 approval-first 정책에서 의도한 fail-closed 종료 상태였습니다. 이번 감사에 제출된 source-free evidence와 tracked repository만으로는 승인된 original-client route를 입증할 수 없었으므로 당시에는 Phase 3B transport/handshake를 시작하지 않았습니다.

3A에서는 client를 실행하거나 공식 endpoint에 연결하지 않았고, credential·session·wire capture·원본 asset을 수집하지 않았습니다. 설치된 파일의 존재나 hash만으로 권리자의 승인 또는 지원 route를 추론하지 않습니다.

## 현행 Phase 3과의 관계

이 문서는 삭제하거나 `ready_for_phase3b`로 소급 수정하지 않는 **역사적 감사 기록**입니다. 공개 EpinelPS 구현을 권리자의 명시적 허가로 간주하지도 않습니다.

이후 프로젝트 운영자는 비배포·로컬 전용·격리된 original-client compatibility 실험을 별도 위험 수용 아래 진행하기로 결정했습니다. 따라서 이 문서의 승인 증거 부족은 더 이상 기술 spike의 영구 중단 조건이 아닙니다. 현행 verdict는 `ready_for_local_compatibility_spike`이며, 적용 범위·외부 dependency pin·안전 경계·시즌 26 종료 조건은 [PHASE3AR.md](PHASE3AR.md)가 소유합니다. 실행 단계는 [PHASE3.md](PHASE3.md)를 따릅니다.

checked-in schema, blocked fixture와 `scripts/verify-phase3a.ps1`은 당시 판정의 구조와 재현성을 보존합니다. 현행 lane을 열기 위해 이 fixture에 존재하지 않는 권리자 승인 진술을 추가하지 않습니다.

## evidence matrix

| 증거 항목 | 상태 | 판정 |
|---|---|---|
| Phase 2B source-free backend/harness | `confirmed` | unit/live PostgreSQL gate 완료 |
| rights-holder supported/approved local/test route | `unresolved` | 승인 문서·지원 selector·허용 범위가 없음 |
| stock retail route | `blocked` | 지원 backend selector가 입증되지 않았고 우회는 금지 |
| exact approved client build closure | `unresolved` | 승인 route에 결박된 executable/runtime/content set이 없음 |
| synthetic-session-only client boundary | `unresolved` | backend 계약은 있으나 승인 client에서 미실행 |
| official server/telemetry outbound zero | `unresolved` | Local Lab config는 outbound를 금지하지만 client process-tree 실행 증거가 없음 |
| prohibited-technique boundary | `confirmed` | endpoint/auth 변조, replay, guessed credential, injection/hooking/patch/bypass 모두 금지 |
| repository/data boundary | `confirmed` | 원본·복호물·patch output·wire capture·client-local reference를 Git/CI에 두지 않음 |
| approved lobby presentation variant | `unresolved` | server feature flags는 있으나 고정 prefab/UI variant 승인 증거가 없음 |
| original battle runtime integrity | `not_evaluated` | 당시 계획의 Phase 4 실제 플레이 gate 소유 |

따라서 당시 missing reason은 다음 다섯 controlled code로 고정했습니다.

- `approved_route_evidence_missing`
- `exact_client_build_binding_missing`
- `outbound_isolation_plan_missing`
- `supported_handshake_contract_evidence_missing`
- `synthetic_session_enforcement_plan_missing`

presentation variant는 3A capability matrix에는 남기되 3B transport 진입의 구조적 필드는 아닙니다. 3D 진입 전에는 반드시 별도로 해소해야 합니다.

## 기계 검증 계약

Phase 3A는 다음 source-free artifact를 추가합니다.

- `contracts/original-client-compatibility-gate.schema.json`
- `tests/fixtures/synthetic/original-client-compatibility-gate.blocked.json`
- `scripts/verify-phase3a.ps1`

checked-in fixture는 항상 `blocked_insufficient_evidence`입니다. schema는 `ready_for_phase3b`에 다음을 모두 요구합니다.

- `rights_holder_approved_local_test` route, current scope, supported selector/interface와 own artifact UID·kind·byte-length·SHA-256으로 봉인한 local evidence
- exact own build UID, executable observation, canonical `nll/client-content-set/v1` digest와 `nll/original-client-adapter/v1`
- supported boot/handshake contract ID와 source-free evidence
- synthetic local session only를 강제할 source-free enforcement-plan evidence와 official credential/session material 금지
- client/launcher/child process의 IPv4·IPv6·DNS·TCP·UDP를 모두 포함한 outbound-isolation verification-plan evidence
- 모든 prohibited technique `false`
- raw/original/decrypted/patch/wire/client-local reference의 repository 노출 `false`
- unresolved reason `0`

JSON이 schema를 통과했다는 사실은 진술의 진실성을 증명하지 않습니다. ready assessment의 근거와 assessment 파일은 저장소 밖의 고정 local evidence vault에서 사람이 검토하고 보존해야 합니다. `NIKKE_LAB_PHASE3A_EVIDENCE_ROOT`를 그 local-drive vault로 설정하고 verifier에 그 아래의 `-LocalAssessmentPath`를 주면 구조만 검사하며 path·hash·내용은 출력하지 않습니다. UNC/device/alternate-data-stream/reparse 경로는 probe 전에 거절합니다. 3A ready는 실행 계획의 준비를 뜻하며 실제 synthetic-session enforcement와 official outbound zero는 3B 격리 실행에서 별도 증거로 다시 봉인해야 합니다.

`nll/client-content-set/v1`은 approved route가 요구하는 member closure가 exact임을 local review로 먼저 확인합니다. 각 local-only observation을 `roleCode + TAB + 10진 byteLength(leading zero 없음) + TAB + lowercase sha256 + LF`로 직렬화하고, record를 `roleCode` ordinal, `sha256` ordinal, byte length 숫자 순으로 정렬한 UTF-8 BOM 없는 manifest의 byte length와 SHA-256을 봉인합니다. 원본 filename/path나 member 목록은 저장소 artifact에 넣지 않습니다. 현재 3A 구현은 이 구조와 blocked verdict를 검증할 뿐 local artifact를 재측정하는 attestation runner가 아니므로, schema 통과만으로 adapter를 활성화할 수 없습니다.

빠른 반복에는 다음 contract-only gate를 사용합니다.

```powershell
pwsh -NoProfile -File scripts/verify-phase3a.ps1 -ContractOnly
```

branch 완료 전에는 `-ContractOnly` 없이 실행해 Phase 2B baseline도 함께 재검증합니다.

## 당시 정책의 3B 재개 조건 — superseded

당시 정책에서는 다음 네 묶음이 저장소 밖에서 준비되기 전에는 3B를 시작하지 않는 계약이었습니다.

1. 권리자가 지원·승인한 local/test route, 허용 목적·범위·유효성 근거
2. 그 route에 해당하는 exact executable/runtime/content closure와 재측정 절차
3. client/launcher/child process 전체의 IPv4·IPv6·DNS·TCP·UDP egress 차단 및 official server/telemetry zero 검증 계획
4. 지원되는 boot/handshake contract. official wire interception/replay로 새 contract를 추출하는 방식은 허용하지 않음

당시 3D를 시작하려면 위 조건과 별도로 approved presentation variant도 필요했습니다. 이 조건은 역사 기록이며 현행 local compatibility spike의 진입 계약이 아닙니다.

## 당시 조건부 견적 — historical

당시 상태:

- 3A 문서·계약 감사: `0.5~1.5시간`
- 3B~3E: `N/A (authorization not evidenced / prerequisites absent)`

승인은 있으나 supported wire/presentation 자료가 없다면 구현 시간을 약속하지 않고 discovery를 각각 time-box합니다.

- wire capability spike: `2~4시간`
- presentation capability spike: `2~4시간`
- isolation/outbound evidence spike: `1~3시간`

승인, stable exact build, supported wire contract, approved UI variant와 준비된 격리 환경이 모두 제공된 경우에만 다음 조건부 post-entry engineering 견적을 사용합니다. 승인·provider 대기, discovery spike, local evidence/build-closure 준비, 격리 환경 구축과 사용자/client 가용 시간은 포함하지 않습니다.

| 단계 | 조건부 시간 |
|---|---:|
| 3B transport/handshake | 2~4시간 |
| 3C boot/session | 3~5시간 |
| 3D lobby/season/presentation | 4~8시간 |
| 3E Challenge ready/enter handoff | 3~6시간 |
| 안정화·전체 gate | 2~4시간 |
| 합계 | 14~27시간 |

provider가 generated SDK, reference adapter와 source-free fixture를 함께 제공하면 각 단계의 입력이 달라지므로 그 시점에 재견적하여 하향할 수 있습니다. 당시 계획의 Phase 4 actual battle/HUD/damage/result 검증은 위 범위에 포함되지 않았습니다.

## 당시 approval-first 계획의 시간 단축 방법

1. 코딩 전에 승인 packet을 완성합니다. 승인 범위, selector 문서, exact build closure, egress 검증 계획, UI variant capability가 없으면 30분 안에 stop합니다.
2. client build와 adapter contract를 먼저 freeze합니다. 중간 build drift는 모든 transport/presentation 증거를 무효화하므로 즉시 3A로 되돌립니다.
3. 한 번에 한 화면 전이만 구현합니다. handshake, loading, lobby, season selection, Challenge ready/enter를 각각 독립 batch로 닫습니다.
4. `-ContractOnly` focused gate를 반복 중 사용하고 전체 Phase 2B chain은 3C·3E와 최종 commit에서만 실행합니다.
5. 실제 client environment는 한 담당자가 직렬 소유합니다. 병렬 agent는 wire fixture, presentation matrix, egress harness와 read-only audit처럼 파일·상태가 겹치지 않는 lane만 담당합니다.
6. shared contract 파일에는 한 명의 writer만 둡니다. 여러 agent가 같은 migration/service/test를 동시에 편집해 발생하는 compile churn을 피합니다.
7. 첫 검증 season은 사용자가 명시적으로 선택한 하나만 사용하고, 경로가 고정된 뒤 여섯 시즌을 data-driven matrix로 확장합니다.

이 구조는 당시 승인 불가 경로에 수 시간을 쓰는 일과 대형 shared-tree 재작업을 줄이기 위한 계획이었습니다. 현행 작업 단위, 시즌 26 classic Solo Raid 우선순위와 견적은 [PHASE3.md](PHASE3.md) 및 [PHASE3AR.md](PHASE3AR.md)를 따릅니다.
