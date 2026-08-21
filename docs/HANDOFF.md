# 작업 인계 — current operational context

## 용도와 권위

이 문서는 새 기기나 새 ChatGPT/Codex 대화에서 현재 작업 위치를 빠르게 복원하기 위한 운영 색인입니다.
설계·보안·데이터·단계별 acceptance의 권위는 `AGENTS.md`가 지정한 앞선 문서에 있으며, 충돌할 때는
그 문서들이 우선합니다. 새 작업자는 이 파일만 읽고 구현을 시작하지 않고 `AGENTS.md`의 전체 읽기 순서를
먼저 따릅니다.

최종 갱신일은 `2026-08-21`입니다.

## Local Lab canonical 상태

- repository: `ejiie/Nikke-Local-Lab`
- canonical branch: `main`
- Phase 2A2부터 Phase 3B-1까지 통합한 PR: `#7`
- PR `#7` squash merge commit: `4d8212fe0b1dd4ba18fc9be764457b246849cda8`
- GitHub Actions 결과: Windows 전체 contract/unit gate와 PostgreSQL Phase 2B live integration 모두 통과
- 현재 제품 verdict: `ready_for_isolated_season26_reference_run`

Git checkout은 항상 원격 `main`을 fetch한 뒤 현재 HEAD를 다시 확인합니다. 위 SHA는 Phase 3B-1 통합
기준점이며, 이 handoff 자체나 후속 작업이 merge되면 최신 `main` SHA가 새 source of truth입니다.

## 완료된 범위

1. Phase 2B source-free private-server backend와 harness를 완료했습니다.
2. Phase 3A의 `blocked_insufficient_evidence`는 당시 approval-first 정책의 역사 기록으로 보존합니다.
3. Phase 3A-R에서 운영자가 승인한 비배포·로컬 compatibility spike를 별도 lane으로 열었습니다.
4. Phase 3B-0에서 client `150.6.9`의 시즌 26 classic Solo Raid static/content closure를 완료했습니다.
5. Phase 3B-1에서 EpinelPS selected-manager, account-scoped run pin, route policy와 dispatch isolation을
   구현하고 source-free receipt를 봉인했습니다.
6. Phase 3B-1 external focused 결과는 selected-manager/lifecycle `58/58`, dispatch isolation `5/5`,
   Release build 오류 `0`입니다.
7. Phase 3B-2 Wave 0 contract scaffold에서 preflight/reference-run source-free schema, blocked/not-executed 합성
   fixture와 전용 verifier를 추가했습니다. Wave 1 준비 branch에서는 18-role local observation-set schema,
   합성 fixture, external candidate sealer와 verifier binding mode를 보강했습니다. 이는 measured ready receipt나
   actual-client 실행 증거가 아닙니다.

아직 완료하지 않은 것은 original-client battle/HUD/result, Local Lab bridge, one-team observation sealing,
1~5팀 runtime parity와 다른 시즌 확장입니다.

## 고정 목표

- 첫 actual-client 대상은 시즌 26 프로비던스의 원본 시즌제/classic Solo Raid Challenge입니다.
- `SoloRaidMuseum`은 공식 별도 콘텐츠이고 결과에 영향을 주는 buff가 있으므로 구현·검증·fallback에서
  제외합니다.
- wire 명칭 `Trial`은 pinned EpinelPS에서 classic Challenge lane을 운반하므로 제외 대상이 아닙니다.
- 시즌 26이 실행되지 않으면 Museum이나 최신 시즌으로 대체하지 않고 `runtime_blocked_season_26`으로
  종료합니다.
- official account/session/token이나 live official traffic replay는 사용하지 않습니다.

## 외부 EpinelPS 상태

EpinelPS source는 AGPL-3.0 별도 checkout이며 Local Lab에 vendor하지 않습니다.

| 역할 | commit |
|---|---|
| reviewed upstream base | `28b2f5413a0a1e3521a11ae162f91851335c8b40` |
| Phase 3B-1 integrated patch | `92a6ca228aeb580988907b96189b2857dff2c62d` |
| Phase 3B-2 local-only preflight seal | `e32e5f900775974d5736e7fb2b50f8c62638a004` |
| latest preflight hardening | `4f7bd5b5eb2b9a6e03af503f1c09adc4c4f7f16f` |
| latest external tree | `ce353eeebee3c76672e483c6f735bb27f0227815` |

Latest external branch는 `codex/phase3b2-live-preflight`이고 확인 시 working tree가 clean이었습니다. 이
checkout과 마지막 두 commit은 Local Lab GitHub `main`에 포함되지 않습니다. 다른 기기에서 계속하려면
별도 AGPL checkout/patch queue를 안전하게 이전하거나 exact upstream base 위에 해당 patch를 재구성해야 합니다.
Local Lab의 source-free receipt만으로 external source commit을 복원할 수 있다고 가정하지 않습니다.

Latest preflight patch에서 확인한 코드 상태는 다음과 같습니다.

- HTTP `80`과 HTTPS `443`은 모두 loopback에만 bind합니다.
- `--headless --local-only`에서 official asset auto-fetch, locale startup download, Git update와 interactive
  command surface를 비활성화합니다.
- local-only mode에서 `update-server` 등록과 직접 resource update 호출을 차단합니다.
- 원본 client를 실행하거나 battle/result를 관측한 증거는 아직 없습니다.

## 바로 다음 단계 — Phase 3B-2

다음 작업은 [PHASE3B2.md](PHASE3B2.md)의 Wave 1 preflight 계약을 disposable VM 또는 별도 disposable
OS의 실측값으로 봉인하는 것입니다. Client를 실제로 시작하는 시즌 26 reference run은 Wave 2입니다.
단순 client 디렉터리 복제본이나 주 Windows 설치본에서는 실행하지 않습니다.

현재 host에서는 Windows Sandbox 기능 활성화가 예약됐고 적용을 위한 재부팅이 필요합니다. 재부팅 뒤
networking disabled Sandbox를 `separate_disposable_os`로 검산하고, 같은 Sandbox session 안에서 P0와 P1을
완료합니다. Sandbox 종료·server 재시작·pin 또는 manifest 변경 뒤에는 기존 ready candidate를 재사용하지
않고 새 assessment를 봉인합니다.

실행 전 필수 gate는 다음과 같습니다.

1. snapshot 가능한 Windows VM/별도 OS와 충분한 여유 공간을 준비합니다.
2. VM 안의 client build `150.6.9`, EpinelPS commit/tree와 build artifact hash를 고정합니다.
3. client, launcher, EpinelPS/server와 child process 전체의 non-loopback egress를 방화벽에서 차단합니다.
4. EpinelPS가 exact `127.0.0.1`에만 bind하고 wildcard/LAN listener가 없음을 재검산합니다.
5. selector의 `GameRoot`가 VM 안의 disposable client를 가리키고 주 설치본 `C:\NIKKE`가 before/after hash상
   불변인지 확인합니다.
6. hosts, root CA, client certificate bundle과 native shim 변경의 backup·rollback manifest를 준비합니다.
7. server-cold `--local-only` 시작에 필요한 reviewed `StaticData.pack`을 별도 필수 input으로 준비하고 exact
   byte length와 SHA-256을 Git 비추적 trusted manifest에 기록합니다. 공식 endpoint에서 자동 취득하지 않습니다.
8. reviewed locale input 네 파일의 exact byte length와 SHA-256을 별도 4-role로 기록하고 VM copy에서
   재계산합니다. 현재 validator의 `NKDB` magic 확인만으로는 충분하지 않습니다.
9. P0 trusted observation set을 server 시작 전에 봉인하고, server만 시작해 HTTP 80, HTTPS 443과 HTTP/3
   UDP 443이 모두 IPv4 `127.0.0.1`에만 존재하며 process-tree non-loopback 시도·성공이 0인지 P1에서
   측정합니다. Client는 계속 cold 상태여야 합니다.
10. P0/P1 18-role observation set과 source-free ready candidate의 canonical digest binding이 검증된 뒤에만
    Wave 2 client 시작을 허용합니다.

Reference run의 목표 전이는 다음과 같습니다.

```text
local loading/login
  -> lobby
  -> original classic Solo Raid main/ready
  -> season 26 Challenge open
  -> first five-member squad enter
  -> original battle runtime
  -> client damage/result return
```

Museum route/stage/buff 관측, 최신 manager fallback, non-loopback 성공 연결, primary install 변경 또는 target
hash drift가 하나라도 있으면 즉시 중단합니다.

## 기기 이전 시 유의사항

- Local Lab source/docs/contracts/migrations는 private GitHub `main`에서 복원합니다.
- PostgreSQL runtime/test DB, original client, decoded/static cache, certificates, private keys와 patched binary는
  Git에 없으며 필요한 경우 별도 안전한 경로로 이전하거나 migrations에서 새로 만듭니다.
- Phase 3B-2 actual-client 상태는 아직 생성되지 않았으므로 현재 Git DB만 옮긴다고 live proof가 복원되는
  것은 아닙니다.
- 외부 EpinelPS patch checkout은 위 commit 표를 기준으로 별도 이전 여부를 반드시 확인합니다.
- 새 기기에서는 .NET `8.0.407`로 Local Lab gate를, .NET `10.0.400`으로 pinned EpinelPS build/test를
  실행합니다. 불완전했던 repo-local `10.0.302` SDK는 사용하지 않습니다.

Local Lab 재검증:

```powershell
pwsh -NoProfile -File scripts/verify-phase3b1.ps1 -ContractOnly
pwsh -NoProfile -File scripts/verify-phase3b2.ps1 -ContractOnly
pwsh -NoProfile -File scripts/verify-repository.ps1 -Mode working -AllowRemote
pwsh -NoProfile -File scripts/verify-actions-contract.ps1
```

Branch 완료 전에는 `verify-phase3b2.ps1`을 `-ContractOnly` 없이 실행하고, PostgreSQL live integration은
Actions 또는 명시적으로 보호된 disposable test DB에서 실행합니다.

## 새 ChatGPT/Codex 대화 시작 문구

다음 문구로 시작하면 됩니다.

```text
ejiie/Nikke-Local-Lab의 최신 main을 source of truth로 사용한다.
AGENTS.md의 문서를 지정된 순서대로 전부 읽고 docs/HANDOFF.md에서 현재 운영 위치를 확인한다.
Phase 3B-2 Wave 0 contract scaffold까지 완료됐으며 checked-in fixture는 blocked/not-executed뿐이다.
다음 작업은 client를 시작하지 않는 Wave 1 measured preflight이고, 그 exact receipt에 결박된 original-client
reference run은 Wave 2이다.
다음 단계는 disposable VM/별도 OS에서 source-free measured preflight를 먼저 봉인한 뒤 시즌 26 classic
Solo Raid 3B-2 reference run을 실행하는 것이다. Museum은 금지되고 fallback도 허용하지 않는다.
구현 또는 실행 전에 최신 main, 외부 EpinelPS patch commit, toolchain과 preflight gate를 재검증하라.
```

## 갱신 규칙

각 phase 또는 외부 integration milestone을 merge할 때 이 문서를 함께 갱신합니다. 완료되지 않은 작업은
`ready`, `verified` 또는 `runtime_exact`로 표현하지 않습니다. External checkout 상태는 Local Lab에 포함된
것처럼 쓰지 않고 public upstream pin, local patch pin과 source-free evidence를 구분합니다.
