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
| measured target-projection HEAD | `6473a41fcdbc7cb4cb5919c31f9b2d1f04b4b5b6` |
| local-only HTTP/3 disable hardening | `9d22e68d069ec3d832bc3ece084952906c169d79` |
| local-only asset-cache log hardening | `519c3db51ec24ca19307e93e85acde7885928a72` |
| latest external tree | `b9e8bfb1b1e065427a48d40cb2bcf2f30215436a` |

Latest external branch는 `codex/phase3b2-live-preflight`이고 확인 시 working tree가 clean이었습니다. 이
checkout과 마지막 두 commit은 Local Lab GitHub `main`에 포함되지 않습니다. 다른 기기에서 계속하려면
별도 AGPL checkout/patch queue를 안전하게 이전하거나 exact upstream base 위에 해당 patch를 재구성해야 합니다.
Local Lab의 source-free receipt만으로 external source commit을 복원할 수 있다고 가정하지 않습니다.

Latest preflight patch에서 확인한 코드 상태는 다음과 같습니다.

- HTTP `80`과 HTTPS `443`은 모두 loopback에만 bind합니다.
- `--headless --local-only`에서는 MsQuic IPv6 wildcard UDP socket을 제거하기 위해 HTTP/3를 비활성화하고
  HTTPS TCP HTTP/1.1+2를 유지합니다.
- `--headless --local-only`에서 official asset auto-fetch, locale startup download, Git update와 interactive
  command surface를 비활성화합니다.
- local-only mode에서 `update-server` 등록과 직접 resource update 호출을 차단합니다.
- local-only asset cache 요청은 absolute path 대신 `local_only_asset_cache_request` controlled code로
  기록하며 일반 upstream mode의 기존 요청 로그는 보존합니다.
- 원본 client를 실행하거나 battle/result를 관측한 증거는 아직 없습니다.

### 2026-08-22 local bootstrap 전환 상태

Private-switch/no-gateway Hyper-V assessment에서 합성 launcher 인증 home까지는 성공했지만, 공식 launcher의
`실행` 버튼은 P0가 변경한 game certificate/native shim을 pre-launch integrity 검사에서 거부했습니다.
표시 code는 `1400003`이었고 `nikke.exe`와 launcher child ACE process는 시작되지 않았습니다. 이 실패는
Git 밖 `nll/phase3b2-private-reference-run-failure/v6` receipt로 보존하며 같은 assessment에서 재시도하거나
launcher repair를 실행하지 않습니다.

보호 검사를 우회하거나 ACE를 대체하는 대신, public `EpinelPSLauncher`의 game-owned Sail ABI bootstrap
부분만 source pin에서 별도 빌드하는 좁은 lane을 준비했습니다.

- public upstream HEAD: `3d680453c0a4ca5ab2cdf3eb60e09b4160cb1bb3`
- public upstream tree: `54b85eb6fbaa74feae0c6b441d66a5a703073ba3`
- .NET SDK: `10.0.400`, locked restore
- local source manifest: 4 members, SHA-256
  `422e38d0357f1042e287f7cc90b1078fd9d5d28d16c45584b0ba175f9367044a`
- output manifest: 5 members, SHA-256
  `b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70`
- build receipt: 1,200 bytes, SHA-256
  `5b22169e01d395966baee89e2a74f6a54fa8033786e7de46917709febedf3d11`

이 output에는 직접 만든 managed bootstrap, 그 runtime metadata와 source-built `sail_api_impl64.dll`만
있습니다. `EpinelPSLauncher.exe`, `HelperDll.dll`, `UnityInit.dll`, official repair/downloader surface는 없고
process injection/hook/memory patch API도 사용하지 않습니다. Bootstrap은 합성 credential/token을
process-local로만 유지하고, local TLS endpoint에서 auth data를 받은 뒤 shared memory와 named pipe로
원본 client executable을 시작합니다. 별도 firewall program rule과 no-default-route gate는 계속 적용합니다.

v6 실패는 exact extraction 뒤 checkpoint 9로 복원됐고, P0/P1 v5와 새 assessment
`31afe0ed-c4a8-4825-b467-f5954d760f09`가 source-free ready receipt로 봉인됐습니다. 기준 checkpoint 10은
`NLL-P3B2-W1-P0-Private-LocalBootstrap-v1-*`, identity SHA-256
`2c605c1600a089f0eec6a13c5be561c46b600202cc965536d23b33babb7deb3b`입니다.

이 assessment의 one-shot bootstrap은 local account/auth까지 통과하고 `nikke.exe` process를 생성했지만,
원본 client가 Sail named pipe 연결 전에 Hyper-V virtual environment 실행을 자체 거부했습니다. 표시 UI는
controlled code `virtual_environment_execution_not_permitted`, error components `3/1053/4227072`로만
기록하고 raw screenshot은 Git 밖에 둡니다. 이는 bootstrap transport 실패나 season 26 content 실패가 아니라
`runtime_blocked_virtualized_environment` 환경 판정입니다. 보호 검사를 숨기거나 patch/hook/injection으로
우회하지 않으며 같은 VM assessment에서 재시도하지 않습니다. 실패 증거를 Git 밖에 추출한 뒤 checkpoint 10을
정확히 복원하고, 다음 actual-client lane은 snapshot/rollback 가능한 별도 물리 Windows OS로 전환합니다.
Original-client loading/login/lobby/battle/result는 여전히 관측되지 않았습니다.

별도 물리 OS의 현재 host storage 계획은 다음과 같습니다. Host에는 512 GB NVMe system disk가 있지만
`C:` 여유 공간은 약 33.5 GiB라 Windows와 26.7 GB client를 함께 둘 admission 여유가 없습니다. 1 TB
TOSHIBA HDD의 `D:`에는 약 249 GiB가 남아 있지만 실행 disk로 쓰면 로딩·검증 시간이 크게 늘고 기존 DATA
partition 축소도 별도 destructive approval이 필요합니다. 따라서 `D:`는 full-disk rollback image와 Git-external
evidence 보관에만 사용하고, actual-client separate-OS lane은 전용 256 GB 이상 SSD(512 GB 권장)에 physical
Windows를 새로 설치하는 것이 기본안입니다. 그 OS에는 Hyper-V/Windows Sandbox/VBS를 켜지 않고, 주 OS나
`C:\NIKKE`를 mount·변경하지 않습니다. Client/tool/input staging과 before image를 먼저 봉인한 뒤 NIC를
no-default-route private mode로 전환하고, 실패·성공과 관계없이 full-disk image 또는 전용 disk 교체로
rollback합니다.

## 바로 다음 단계 — Phase 3B-2

### 2026-08-24 physical P2 catalog blocker와 승인된 다음 lane

Micron 별도 물리 Windows의 dedicated `nlloperator` profile에서 원본 client는 Sail handoff와 server selection을 통과해 loading `4/7`까지 직접 관측됐습니다. 반복 실패는 local exact content-version/catalog closure 결손으로 분류됐고, Samsung의 read-only 전체 검색에서는 필요한 `core`/`dp`/`fd` signed NKDB pair가 하나도 확인되지 않았습니다. 이 상태에서는 같은 Micron client retry를 더 소비하지 않습니다.

운영자는 Samsung runtime-cold 환경에서 static asset CDN의 exact `catalog.db`/`.nds` 여섯 객체만 인증 없이 수집하는 좁은 예외를 승인했습니다. 다음 순서는 `request manifest 검산 -> Samsung Git-external sealed acquisition -> offline catalog parse/resource closure -> Micron offline staging -> 한 번의 local-only retry`입니다. Client/EpinelPS auto-fetch, official API/login/telemetry, 일반 asset 수집과 실행 중 outbound는 계속 금지됩니다. 범용 수집기는 `scripts/invoke-phase3b2-static-catalog-acquisition-on-samsung.ps1`, 복구 가능한 quarantine rollback은 `scripts/rollback-phase3b2-static-catalog-acquisition-on-samsung.ps1`이 소유합니다.

이 lane의 six-member acquisition과 offline staging은 완료됐습니다. Acquisition assessment는
`3307c851-bd77-4f38-8808-91ddb3b7800d`, source-free receipt SHA-256은
`87d22ab630bea3851ad3af6b8a2b3be009c7f49b9320529186261bb38c24ae92`입니다. 세 NKDB body와 세
96-byte detached signature의 총 길이는 19,520,185 bytes이고, deployment UID는
`bf669c3c-fcc8-4d57-9f18-32fee1288862`, deployment receipt SHA-256은
`27ec27253b56fae39967a5714a315a862908a268a62a7083d45f85df9de592f6`입니다. Micron offline cache의
여섯 target은 모두 exact digest로 재검산됐고 physical client/primary install/official launcher는 수정하지
않았습니다.

Catalog SQLite의 `entry_data.hash`를 전부 remote member로 간주한 초기 집계는 provider metadata와
`RuntimePath` row를 잘못 포함했으므로 폐기했습니다. Epinel native host-token mapping으로 재계산한 권위
closure는 catalog row 40,281개 중 remote materialization member 40,097개와 non-remote row 184개입니다.
Remote set은 exact local 34,618개, missing 5,450개, size mismatch 29개이며 전체 declared length는
38,987,622,630 bytes입니다. Samsung native-cache materialization은 완료됐습니다. Remote 40,097개와 fixed
catalog 6개를 합한 40,103개, 39,007,142,815 bytes를 전부 length/SHA-256으로 검증했고, local exact copy는
34,624개, static CDN GET 완료는 5,479개입니다. Materialization receipt SHA-256은
`89a76b1e5237ea3864d87303418e638d9ad7de0570ad456182568a17c5ead921`, private manifest SHA-256은
`c1223ee05fec7cf3780171ead9a3e5da7f2942f129e0014995f10fabee0782a1`, canonical SHA-256은
`95000d45cb52f4bdd81b6ca9caf7e2e13eeae7bbddfa67e33ed8ef8896f22ffe`입니다. 이 결과는 cache 완성만
증명하며 `4/7` 이후 성공을 미리 주장하지 않습니다. Exact-catalog 전용 실행기 배포 receipt SHA-256은
`6d181c40d7da412de9f7861f6e12814a304e848adcb4ebe7b1ab2b69ec6dec19`이고, 기존 실행기는 별도 backup과
rollback으로 보존됐습니다. Minimal assessment `0f37da44-dc19-4f5e-b7a8-25556a9f52b3`의 실패 실행은
active pointer와 DB/SQLite/hosts 실행 후 상태가 남아 있습니다. 다음 동작은 Micron 재실행이 아니라 Samsung
관리자 PowerShell에서 offline baseline recovery와 40,108-file combined cache의 staging 검산·directory swap을
수행하는 것입니다. 기존 11-file cache는 rollback용 `cache-before`로 보존합니다.

첫 관리자 배포는 39 GB robocopy가 끝난 뒤 Windows PowerShell 5.1의 long-path recursive enumeration에서
swap 전에 중단됐습니다. 활성 cache는 11-file 기준선 그대로이고 배포 receipt는 생성되지 않았습니다. 보존된
`staging-failed-20260824T114137Z`는 .NET 10 verifier로 40,108개, 39,030,629,947 bytes 전부를 private
manifest와 SHA-256 대조했으며 누락·추가·digest mismatch는 0입니다. Combined active canonical SHA-256은
`9c2874cd3c811609b4c8d6c34caf393aaf3e24b09825294a66b063e4fe1b521b`입니다. 수정된 deployment script는
이 staging을 재복사 없이 재사용하므로 다음 동작은 같은 Samsung 관리자 명령을 한 번 다시 실행하는 것입니다.
Long-path verifier source commit은 external EpinelPS `6abf39b8daa1b7ee04da651e14941a2ece1ca29b`, clean build
DLL SHA-256은 `5b3c941374a68fa9090481de0e96d479f6bc40601776c98bfe1d64ac78d9b5fb`입니다.

첫 실행 시 catalog 검증에 들어가기 전 `physical_boundary_profile_and_contract_preflight`가
`phase3b2_physical_p2_v2_runtime_pin_mismatch`로 fail-closed됐습니다. 원인은 이전 실패 복구가 `hosts`와
P2-v2 extension firewall을 원복했지만 오래된 preparation receipt를 보존하여 wrapper가 준비 재적용을
건너뛴 상태 불일치였습니다. Assessment `1797ba14-cdd4-45e7-9002-b77ddbee3227`의 failure receipt SHA-256은
`03a6021e6d84d83ad967b5ce4cb6e74abfc01d28fa902ed45aa4182769fdcc76`이며 server/client는 시작되지 않았고
exact-catalog retry도 소비되지 않았습니다. Samsung에서 offline Micron에 재무장 wrapper를 배포했고 deployment
receipt SHA-256은 `59721268949df5cb2cb553f54f673f2987ec5fb3eb45aa4f83f1df8ec20ed52d`입니다. 새 wrapper는 이 exact
상태에서만 기존 hosts mapping 1개와 bootstrap outbound block 1개를 재적용하고 같은 one-shot으로 이어집니다.
배포 뒤 catalog target은 6/6 exact, `hosts`는 base digest, retry-consumption과 active-run pointer는 모두 absent로
재검증됐습니다.

재무장 뒤 assessment `29083a6a-3f4e-4eec-a57a-4d28b1459524`는 six-member catalog를 exact로 읽었지만
동일한 `4/7` UI에서 종료됐습니다. 이번에는 client `Player.log`와 비민감 server request-stage를 오프라인으로
교차 검산해 실제 첫 결손 요청을 `prdenv/.../pck/latest-651.txt`의 local HTTP 404로 확정했습니다. Six-member
catalog 가설만으로 충분하다는 판정은 폐기합니다. 설치된 `.lcv.dat`와 pinned `gameconfig.json`에서 이미
결정적으로 투영한 139-byte header의 SHA-256은
`5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a`입니다.

Samsung offline repair `nll/phase3b2-exact-catalog-header-followup/v1`은 실패 실행의 DB/SQLite를 기준 상태로
복원하고 active pointer와 retry consumption을 원본 digest로 해당 run root에 보존한 뒤 이 header를 Micron
local cache에 배치했습니다. Receipt SHA-256은
`38f757559f5e70f9f185bc54b4917aab5c538ad9a0500e7d05fddff1e55f7c4d`입니다. Exact catalog 6/6,
header 139 bytes, baseline DB, SQLite 0개와 Windows PowerShell 5.1 tool parse를 독립 재검산했습니다. 과거
`latest-completion.pointer.json`이 존재하면 새 active run의 completion을 무조건 거부하던 도구 결함도 수정해,
과거 pointer를 새 run evidence에 보존한 뒤 최신 pointer를 갱신합니다. 다음 동작은 Micron `nlloperator`에서
catalog+header follow-up을 한 번 실행하는 것입니다. 이 repair는 전체 14.6 GB resource closure나 `5/7`
이후 성공을 주장하지 않습니다.

다음 작업은 [PHASE3B2.md](PHASE3B2.md)의 Wave 1 preflight 계약을 disposable VM 또는 별도 disposable
OS의 실측값으로 봉인하는 것입니다. Client를 실제로 시작하는 시즌 26 reference run은 Wave 2입니다.
단순 client 디렉터리 복제본이나 주 Windows 설치본에서는 실행하지 않습니다.

현재 실행 환경은 snapshot 가능한 Hyper-V VM `NLL-Phase3B2-Client150.6.9`입니다. VM NIC는 Hyper-V
switch에서 분리되어 있고 Guest Service는 필요한 파일 전달 직후 다시 비활성화합니다. P0 mutation과
rollback은 검증됐습니다. P1 diagnostic은 HTTP/3 UDP `[::]:443`, 측정기 `conhost.exe` 분류, local cache
absolute-path log를 차례로 실패-폐쇄하고 매번 server/DB/audit를 자동 복원했습니다. 최신 v4 build manifest
SHA-256은 `ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37`이며, 이 pin으로
P0 v3를 재결박한 뒤 P1을 새 assessment로 다시 봉인해야 합니다.

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
9. P0 trusted observation set을 server 시작 전에 봉인하고, server만 시작해 HTTP 80과 HTTPS 443이
   IPv4 `127.0.0.1`에만 존재하고 local-only HTTP/3/UDP 443 listener가 `0`이며 process-tree
   non-loopback 시도·성공이 0인지 P1에서 측정합니다. Client는 계속 cold 상태여야 합니다.
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

## 2026-08-24 physical lane 현재 계획

Hyper-V reference run은 original client의 virtualized-environment 거부로 종료했고, 현재 actual-client lane은
별도 Micron Windows에서 수행합니다. Samsung Windows가 대화·개발·빌드·Micron 오프라인 수정 환경입니다.

반복된 Physical P2 catalogue projection 실험은 중단했습니다. 현재 authoritative 실행 계획, exact pin,
포함/제외 변경, rollback 및 stop rule은
[`PHASE3B2_EPINEL_MINIMAL_PLAN.md`](PHASE3B2_EPINEL_MINIMAL_PLAN.md)에 기록합니다. 새 작업은 그 문서의
`519c3db…` clean EpinelPS base, Micron `150.6.b15 / 651`, 봉인된 raw NKDB 3개와 `.nds` 3개를 기준으로
재개합니다. SQLite projection, Samsung b22 cache 및 기존 증상별 repair chain은 새 baseline에 포함하지
않습니다.

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
