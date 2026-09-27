# Phase 3A-R — local compatibility rebaseline

> 단계별 계약·검증 기준입니다. 이 문서의 과거 실행 판정과 현재 운영 상태를 구분합니다. 현행 상태는 [인계 요약](../HANDOFF.md), 남은 작업은 [다음 작업](../NEXT_STEPS.md)을 확인합니다.

## 판정

상태: **문서 재기준화 완료 / `ready_for_local_compatibility_spike`**

후속 진행 상태: 3B-0 시즌 26 static/runtime closure와 3B-1 selected-manager patch를 완료했습니다.
현재 verdict는 `ready_for_isolated_season26_reference_run`이며, absolute timing 분석만 client `150.6.9`
native scheduler contract 부재로 남았습니다. 이 후속 결과는 3A-R verdict를 바꾸지 않으며
[PHASE3B0.md](PHASE3B0.md)가 closure 권위, [PHASE3B1.md](PHASE3B1.md)가 selected-manager
integration과 source-free receipt의 권위입니다.

Phase 3A의 `blocked_insufficient_evidence`는 권리자가 지원·승인한 경로만 기술 작업의
진입점으로 인정했던 당시 정책에서 나온 올바른 감사 결과입니다. 그 결과와
`nll/original-client-compatibility-gate/v1` fixture는 삭제하거나 성공으로 바꾸지 않습니다.

프로젝트 소유자는 다음 사실을 구분한 상태에서 정책을 변경했습니다.

- 공개·활성 [EpinelPS](https://github.com/EpinelPS/EpinelPS) 구현은 원본 NIKKE client와
  local backend를 연결하는 경로가 기술적으로 실재한다는 선행 근거입니다.
- 공개 저장소의 존재는 Shift Up 또는 배급사의 승인, 허가, 묵인이나 비집행 약속을
  뜻하지 않습니다. 이 프로젝트는 그런 승인을 주장하지 않으며 법적 상태도 판정하지
  않습니다.
- 사용자는 비배포·개인 로컬 환경의 호환성 연구를 진행하도록 승인했습니다. 따라서
  권리자 승인 문서는 더 이상 기술 spike의 진입조건이 아닙니다.

새 판정은 제품 adapter가 완료됐거나 원본 client 실행이 이미 검증됐다는 뜻이 아닙니다.
문서 변경 시점의 application/config/schema는 기존 fail-closed 상태이고, 실제 활성화는
아래의 작은 실행 gate를 순서대로 통과하면서 별도 구현합니다.

## 고정 목표

첫 original-client 목표는 **시즌 26 프로비던스의 원본 시즌제 Solo Raid Challenge**입니다.

- 원본 `SoloRaid` main/ready/Challenge/battle/result 흐름만 사용합니다.
- `SoloRaidMuseum`은 실제 NIKKE의 별도 콘텐츠이고 전투 결과에 영향을 주는 별도 buff가
  존재하므로 구현·대체·fallback 후보에서 제외합니다.
- 시즌 26이 현재 client runtime에서 실행 불가능하더라도 Museum이나 다른 시즌으로
  자동 대체하지 않습니다. 시즌 26을 `runtime_blocked_season_26`으로 기록하고 사용자와 다음 대상을
  다시 결정합니다.
- Normal I~VII 전투와 Quick Battle은 계속 범위 밖이며, `lastClearLevel=7`과
  `challengeUnlocked=true`의 합성 local unlock projection만 유지합니다.

Phase 1C의 read-only StaticData 결과는 시즌 26의 manager와 Challenge 정적 chain을
`static_exact`로 게시했습니다. 이는 실행 가능성 증명이 아니므로 첫 live 작업 전에 다음
closure를 다시 확인합니다.

```text
season 26 manager
  -> Challenge preset (difficultyType=2, waveOrder=8)
  -> wave group / wave
  -> spawned boss / stat enhancement / parts
  -> current client-local behavior and asset availability
```

하나라도 모호하거나 누락되면 raw ID나 이름으로 추측하지 않습니다.

## 고정 upstream 기준

초기 reference는 다음 공개 상태에 고정합니다.

- repository: [`EpinelPS/EpinelPS`](https://github.com/EpinelPS/EpinelPS)
- reviewed commit: [`28b2f5413a0a1e3521a11ae162f91851335c8b40`](https://github.com/EpinelPS/EpinelPS/tree/28b2f5413a0a1e3521a11ae162f91851335c8b40)
- target client declared by upstream: `150.6.9` ([`gameconfig.json`](https://github.com/EpinelPS/EpinelPS/blob/28b2f5413a0a1e3521a11ae162f91851335c8b40/EpinelPS/gameconfig.json))
- license: [AGPL-3.0](https://github.com/EpinelPS/EpinelPS/blob/28b2f5413a0a1e3521a11ae162f91851335c8b40/LICENSE)

EpinelPS는 Local Lab source tree에 복사하는 library가 아니라 별도 checkout·별도 process의
wire/transport facade로 먼저 평가합니다. generated protocol source, game data, certificate,
patched native binary와 decoded cache를 이 저장소에 vendor하지 않습니다. EpinelPS 수정이
필요하면 별도 AGPL worktree/fork에 명확히 격리하고 Local Lab과는 versioned loopback bridge로
연결합니다.

현재 classic Solo Raid 구현은 client가 보낸 `raidId`를
[`/soloraid/open`](https://github.com/EpinelPS/EpinelPS/blob/28b2f5413a0a1e3521a11ae162f91851335c8b40/EpinelPS/LobbyServer/Soloraid/Open.cs)에서
수락하지만, 여러 info/trial/damage 경로는
[`GetRaidId()`가 manager key의 최댓값을 선택](https://github.com/EpinelPS/EpinelPS/blob/28b2f5413a0a1e3521a11ae162f91851335c8b40/EpinelPS/LobbyServer/Soloraid/SoloRaidHelper.cs)합니다.
따라서 시즌 26 검증은 한 endpoint의 상수 교체가 아니라 account-authoritative selected manager를
첫 classic request 전에 명시적으로 bootstrap하고 모든 classic Solo Raid read/write 경로에 동일하게
적용하는 작은 upstream extension을 필요로 합니다. 후속 3B-0 route audit은 classic handler `19`개를
request manager `6`, latest-manager fallback `9`, manager 미사용 `4`로 분류했습니다. 목적 상태에서는
Pre-characterization policy는 `6 selected Challenge / 1 GetLogs gate / 10 controlled unsupported / 2 manager-independent`입니다.
Stable upstream context ID가 없어 v1은 session override 없이 account당 하나의 active classic run으로 제한하며,
상세는 [PHASE3B1.md](PHASE3B1.md)를 따릅니다.

## 허용되는 실험 경계

Micron의 `C:\NIKKE`는 공식 launcher 소유의 mutable official-current source이며 공식 update와
fresh capture에만 사용합니다. modified-local client target은 별도 version/hash로 봉인한 frozen
lane입니다. system hosts·root CA를 바꾸는 실험은 snapshot 가능한 disposable VM 또는 별도
disposable OS 안에서만 수행하고 official-current tree를 EpinelPS에 연결하지 않습니다.

- 더미 local account만 사용하고 공식 account, cookie, session, token과 credential을 사용하지 않음
- system hosts와 root CA trust 변경은 disposable VM/OS에만 적용 가능
- 단순 client 디렉터리 복제본에는 client-local certificate bundle과 reviewed native compatibility
  shim만 적용 가능하며 host OS의 hosts/root trust는 바꾸지 않음
- 변경 전후 exact length/SHA-256, backup 위치와 rollback 결과를 로컬 evidence에 기록
- modified client 실행 중 client, launcher, EpinelPS/server와 관련 child process 전체의 non-loopback
  통신을 차단·관측
- 모든 local service는 `127.0.0.1`에만 bind하고 wildcard/LAN/public bind, port forwarding과 제3자
  접속을 허용하지 않음
- 원본·복호물·client asset·patched output·certificate private key·runtime DB를 Git/CI/release에 넣지 않음
- 자동 updater와 unpinned upstream drift를 허용하지 않으며 commit/client build가 바뀌면 재감사

hosts와 root CA는 disposable VM/OS에서만, client-local bundle과 native shim은 위 경계 안에서
허용되는 compatibility 수단입니다. 이것이 process
injection, arbitrary memory hooking 또는 범위가 확인되지 않은 anti-cheat 변경을 포괄 허용한다는
뜻은 아닙니다. 현재 고정한 EpinelPS 경로 밖의 새 기법이 필요해지면 그 기법만 별도 결정합니다.

## 단계와 exit gate

각 단계는 결과를 보고 다음 단계를 계속할지 판단합니다. 뒤 단계 코드를 미리 대량 구현하지
않습니다.

| 단계 | 산출물 | 종료 조건 | 예상 |
|---|---|---|---:|
| 3A-R | 정책·upstream·target·실험 경계 재기준화 | 문서 모순 0, historical 3A와 새 판정 분리 | 1.5~2.5h |
| 3B-0 | 시즌 26 local compatibility closure | **완료** — static/content exact, timing analysis blocker 분리 | 완료 |
| 3B-1 | classic selected-manager extension과 focused test | **완료** — account selection/run pin, final `7/10/2`, focused test `63/63` | 완료 |
| 3B-2 | disposable 환경 reference run | local loading/login/lobby→원본 Solo Raid 시즌 26 Challenge→battle/result | 2~4h |
| 3C | Local Lab shadow bridge와 최소 one-team observation adapter | 한 팀 open/enter/client damage/close가 별도 provenance로 Phase 2B에 idempotent하게 기록 | 3~6h |
| 3D | 한 시즌 authority 결박 | client result와 Local Lab run/snapshot/profile/squad revision exact correlation | 4~7h |
| 3E | 후속 지원 시즌 확장 | 사용자가 승인한 시즌별 동일 classic contract smoke | 별도 재견적 |
| Phase 4 | one-team observation 계약의 1~5팀 확장 | regroup/next-team/result/recovery, ESC/frame telemetry와 runtime parity | 별도 재견적 |

3A-R을 시작할 때 잡은 시즌 26 첫 기술 go/no-go까지의 조건부 총견적은 `6.5~12.5시간`입니다.
3B-1 완료 뒤 현재 남은 3B-2 engineering estimate는 `2~4시간`입니다. VM 준비,
다운로드와 사용자 상호작용 대기는 두 수치에 포함하지 않습니다. 각 implementation batch는 최대
`2~4시간`, 하나의 observable transition과 focused commit만 소유합니다.

## 시즌 26 성공 조건

첫 live spike는 다음을 모두 만족해야 성공입니다.

1. pinned client와 EpinelPS build가 preflight hash와 일치합니다.
2. synthetic local account로 loading, local registration과 lobby에 도달합니다.
3. client가 `SoloRaidMuseum` route나 Museum stage/mode/buff를 사용하지 않습니다.
4. 원본 시즌제 Solo Raid main/ready 화면이 시즌 26 프로비던스와 Challenge를 표시합니다.
5. Challenge open과 첫 5인 squad enter가 같은 시즌 26 manager/preset/wave를 참조합니다.
6. 원본 battle runtime이 시작되고 client가 산출한 damage/result가 돌아옵니다.
7. server/bridge는 damage를 재계산하거나 Museum 보정을 적용하지 않습니다.
8. 종료·오류 뒤 active run과 hosts/CA/native shim 변경을 정해진 절차로 복구합니다.

3번은 명시적 negative gate입니다. Museum 화면이 열리거나 Museum buff가 적용되면 전투가
기술적으로 성공해도 이 프로젝트의 성공으로 판정하지 않습니다.

## 현재 구현 상태와 후속 변경

이 문서는 정책과 실행 계획의 권위입니다. 문서 완료만으로 다음 기존 artifact의 의미를
소급 변경하지 않습니다.

- `contracts/original-client-compatibility-gate.schema.json`
- `tests/fixtures/synthetic/original-client-compatibility-gate.blocked.json`
- `scripts/verify-phase3a.ps1`
- `originalClientCompatibility.enabled=false`, `status=blocked`를 강제하는 현재 configuration/runtime

위 항목은 historical Phase 3A contract를 계속 검증합니다. 완료된 3B-0은 별도의 source-free
local-experiment closure verdict를 사용하고 기존 blocked fixture를 성공 fixture로 변조하지
않습니다. production composition은 계속 fail closed이며, 3B-0 통과만으로 original-client route를
자동 시작하지 않습니다.
