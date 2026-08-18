# Original client feasibility gates

## 현재 결론

현재 설치된 리테일 release build로 원본 UI와 전투 runtime을 그대로 사용하면서 안전하게 로컬 backend를 선택하는 지원 경로는 확인되지 않았습니다. 따라서 원본 클라이언트 연결 상태는 `blocked`입니다.

Phase 0의 계약, 합성 fixture, importer 설계, lab-owned test harness는 이 gate와 무관하게 진행할 수 있습니다.

## 여섯 가지 확인 결과

| # | 확인 항목 | 상태 | Phase 0 판정 |
|---|---|---|---|
| 1 | 지원되는 backend/environment 선택 기능 | blocked | release build에서 지원 switch를 확인하지 못함 |
| 2 | 공식 자격증명 없는 합성 local session | conditional | lab-owned synthetic session 계약은 가능하나 1번 gate 때문에 원본 client의 안전한 부팅 경로에 도달하지 못함 |
| 3 | Challenge 진입용 normalized contract | design-ready | Challenge 전용 계약과 normal-stage unlock stub을 lab harness에 모델링 가능 |
| 4 | 전투 authority 분리 | partially confirmed | client에 battle runtime이 존재함은 정적으로 확인; local backend의 검증·서명·결과 역할은 미확정 |
| 5 | 시즌별 패턴 보존 | partial | static/behavior/asset/runtime 증거 수준을 tier로 분리해야 함 |
| 6 | 공식 outbound zero | blocked for retail | 현재 release 부팅에서 완전 차단과 정상 진행을 동시에 보장하지 못함 |

## Gate 해제 조건

다음 조건을 모두 충족해야 원본 클라이언트 adapter를 활성화할 수 있습니다.

1. 권리자가 해당 사용자와 해당 실험 목적에 적법하게 제공·승인한 로컬 backend 선택 기능 또는 개발/테스트 client가 있거나, 권리자의 서면 허가가 있다.
2. 실행 파일, endpoint, route, auth 흐름을 변조하지 않는다.
3. 공식 계정, 쿠키, token, session을 사용하거나 복사하지 않는다.
4. 주입, 후킹, 메모리 조작, launcher/안티치트 우회를 사용하지 않는다.
5. 공식 서버와 telemetry로 향하는 outbound가 0임을 재현 가능한 방식으로 검증한다.
6. 원본 및 파생 데이터를 Git에 넣거나 제3자에게 제공하지 않는다.

한 조건이라도 충족하지 못하면 fail closed로 유지하고 lab-owned harness를 사용합니다.

서면 허가는 발급 주체, 허용 목적, 대상 client build/hash, 유효 기간을 로컬 증거로 고정합니다. 기술 gate 통과는 법적 적법성을 자동 보장하지 않습니다.

client build/hash가 바뀌면 기존 gate 판정과 runtime compatibility를 각각 `blocked`, `not_evaluated`로 되돌리고 처음부터 재검증합니다.

## 비집행 정황의 취급

제3자 판매·유통 사례에 대해 공개 제재가 확인되지 않았다는 관찰은 권리자의 허가, 권리 포기, 합법성 또는 향후 미집행을 의미하지 않습니다. 이 정황을 gate 해제의 근거로 사용하지 않습니다.
