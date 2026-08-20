# Original-client private-server feasibility gates

## 현재 결론

최종 제품은 원본 NIKKE UI·asset·전투 runtime을 사용하는 제한 기능 local private server입니다. 그러나 현재 설치된 stock retail release build에서 공식 server 대신 Local Lab을 선택하는 지원 경로와, 사용자 선언 lobby를 적용할 승인된 UI variant 경로는 아직 확인되지 않았습니다.

따라서 두 경로를 분리합니다.

- `stock_retail_route`: blocked
- `isolated_local_compatibility_route`: not_evaluated/conditional
- `lobby_presentation_variant`: not_evaluated/conditional

Phase 0~2B의 domain, importer, private-server API와 harness 검증은 이 gate와 독립적으로 진행할 수 있습니다. gate가 막힌 상태에서 harness나 별도 UI를 최종 제품으로 선언하지 않습니다.

## Gate A — isolated local compatibility route

원본 UI/runtime을 유지하는 격리된 local/test client 경로는 다음을 모두 충족해야 합니다.

1. 권리자가 제공·지원·승인한 local/test environment selector, 개발·테스트 client 또는 동일 범위의 명시적 허가가 있습니다.
2. 대상 client build와 executable/content hash, 허용 목적과 유효 범위를 로컬 증거로 고정합니다.
3. 공식 account, cookie, token과 session을 사용하거나 복사하지 않고 Local Lab synthetic session만 사용합니다.
4. 공식 endpoint/auth protocol replay, 추측 credential, process injection, hooking, memory patch와 launcher/anti-cheat bypass를 사용하지 않습니다.
5. 공식 server와 telemetry로 향하는 outbound가 0임을 재현 가능하게 검증합니다.
6. 원본·복호물·asset·patch output·wire capture를 Git, CI artifact 또는 제3자 remote에 넣지 않습니다.

한 조건이라도 충족하지 못하면 adapter는 fail closed입니다. 사용자 의도나 제3자 사례만으로 이 gate를 통과했다고 보지 않습니다.

## Gate B — client wire contract

private-server state가 원본 client 화면을 정상 구동하려면 다음이 입증돼야 합니다.

- boot/loading/local-session bootstrap에 필요한 request/response contract
- profile, wallet, roster, squad와 inventory subset projection
- Solo Raid season directory selection과 classic Solo Raid state projection
- Challenge open/enter/regroup/result state machine
- original-client observed damage/result receipt
- unsupported route의 controlled no-op/not-supported 처리

wire adapter는 lab-owned UID와 client-local content reference를 Git 비추적 compatibility binding에서 변환합니다. 이 transient compatibility value를 domain PK/FK, public API, log와 fixture에 노출하지 않습니다.

## Gate C — lobby presentation variant

서버 feature state로 기존 button을 숨기는 것과 고정 prefab을 재배치하는 것은 다른 capability입니다. 사용자 선언 lobby를 충족하려면 다음을 각각 확인합니다.

- 기존 banner/menu/card를 server-driven flag로 숨길 수 있는 항목
- 승인된 client variant가 필요한 고정 widget 제거·재flow
- 좌측 multi-season folder와 boss presentation binding
- permanent season의 countdown 숨김 또는 `상시` 표시
- Quick Battle button 제거/disabled projection
- Recruit click feedback 후 page transition 차단

서버에 빈 payload를 보내 발생한 오류·timeout·빈 화면은 UI 구현으로 인정하지 않습니다. 승인된 presentation path가 없으면 private-server backend가 완성돼도 exact lobby 요구는 blocked입니다.

## Gate D — original battle runtime integrity

- 원본 battle scene, Spot behavior, animation, QTE, parts와 HUD가 로드됩니다.
- client의 damage calculation/display path를 Local Lab이나 sidecar simulator가 대체하지 않습니다.
- runtime execution/control profile의 requested/effective 값과 frame telemetry가 일치합니다.
- result가 exact raid/account/squad/build/client revision을 참조합니다.
- client build/hash가 바뀌면 route, presentation과 runtime compatibility를 모두 재평가합니다.

## 현재 evidence 상태

| 항목 | 상태 | 현재 판정 |
|---|---|---|
| private-server domain/API 설계 | 진행 가능 | Phase 2B에서 harness 검증 |
| Normal clear/Challenge unlock contract | design-ready | `lastClearLevel=7`, Challenge 기본 open |
| permanent season/no Quick Battle/05:00 KST | design-ready | Phase 2B 신규 state 필요 |
| stock retail backend selector | blocked | 지원 switch 미확인 |
| isolated local compatibility client | conditional | 승인된 route/build 증거 필요 |
| multi-season lobby variant | conditional | client presentation capability 필요 |
| battle runtime compatibility | partial | season별 evidence tier 상한이 다름 |
| official outbound zero | blocked for retail | 격리 client에서 별도 입증 필요 |

## 완료 판정

Phase 3은 Gate A~D를 모두 통과해야 합니다. Phase 4 완료는 다시 `(client build, season, raid snapshot)`별 실제 플레이 증거가 필요합니다. gate가 열리지 않으면 Phase 1·2 결과는 보존하지만 최종 제품 상태는 `blocked`입니다.
