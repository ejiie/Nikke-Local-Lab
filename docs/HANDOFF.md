# 작업 인계 — current operational context

## 용도와 권위

이 문서는 새 기기나 새 ChatGPT/Codex 대화에서 현재 작업 위치를 빠르게 복원하기 위한 운영 색인입니다.
설계·보안·데이터·단계별 acceptance의 권위는 `AGENTS.md`가 지정한 앞선 문서에 있으며, 충돌할 때는
그 문서들이 우선합니다. 새 작업자는 이 파일만 읽고 구현을 시작하지 않고 `AGENTS.md`의 전체 읽기 순서를
먼저 따릅니다.

최종 갱신일은 `2026-08-27`입니다.

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
Long-path verifier source commit은 external EpinelPS `6abf39b8daa1b7ee04da651e14941a2ece1ca29b`입니다. 첫
재실행은 이전 clean build DLL digest를 고정한 사전검사에서 중단됐고 cache/staging 이동은 없었습니다. DLL
digest는 source checkout의 line-ending normalization에도 달라질 수 있으므로 수정된 배포기는 .NET SDK
`10.0.400`과 Program/csproj/global.json/연결 소스/참조 SQLite binary 11개의 compile-input canonical SHA-256
`eaf339d04519010b8379ad2c30ef4321d5e6e2623a5d90116f350f0eac32bba3`을 fail-closed로 고정합니다. 실제 build DLL
digest는 receipt에 관측값으로 남고 cache 권위는 private manifest에 대한 member별 SHA-256 검증입니다.

Native cache offline deployment `bc753164-afa2-41f2-9df1-09ea13a2d2a1`은 prior staging 재복사 없이
성공했습니다. Deployment receipt SHA-256은 `14bf845aec4cded1d80e8efb57a3eb4f4639ef68bd1fdf7a8d9de462689aae7d`,
active cache는 40,108개, 39,030,629,947 bytes, canonical SHA-256
`9c2874cd3c811609b4c8d6c34caf393aaf3e24b09825294a66b063e4fe1b521b`입니다. 이전 11-file cache는 rollback으로
보존됐고 DB/SQLite/hosts는 cold baseline입니다. 배치 후 audit에서 start wrapper에도 PowerShell 5.1
`Get-ChildItem -Recurse` 검사가 남아 있음을 발견했습니다. 다음 Samsung 작업은 cache를 재복사·변경하지 않고
8-member .NET 10 verifier bundle과 long-path-safe wrapper를 offline 배치하는 것입니다. 현재 active cache의
read-only long-path inspection은 1.3초, 40,108개/39,030,629,947 bytes/partial 0으로 통과했습니다.

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

이후 Epinel native-cache materialization 40,108개/39,030,629,947 bytes를 Micron에 배치해 재시도했지만,
assessment `cbce0850-d821-4f0a-99cc-fb3603c4722d`는 동일한 `4/7`에서 종료됐습니다. Offline Micron
`Player.log`의 exact 실패는 `prdenv/150-b059c3f36c/StandaloneWindows64/pck/latest-651.txt` local HTTP
404이며, active cache에는 이 member가 없었습니다. 현재 다음 작업은 Samsung 관리자 PowerShell에서
`scripts/repair-phase3b2-epinel-native-cache-header-closure-offline.ps1`을 실행하는 것입니다. 이 도구는 failed
run을 cold baseline으로 복구하고, 이미 봉인된 exact 139-byte/SHA-256
`5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a` header 하나만 추가합니다. 새 Micron
start는 Epinel listener 이후·bootstrap 이전에 해당 local HTTPS GET의 loopback DNS, status 200, length와 digest를
확인하지 못하면 원본 client를 시작하지 않습니다. 기대 cache shape는 40,109개/39,030,630,086 bytes입니다.

Header closure repair는 완료됐습니다. Repair receipt SHA-256은
`bc5e9e0f8f45f17c4db0408cee3d8a88389e11d1578670e9733a2563535444ce`, tool-binding receipt SHA-256은
`06967b54d83af2985c4908b3bc8a83cb246b9a17d43d699482ba542d6f523a18`입니다. Samsung 교차 검산에서
header 139 bytes/exact SHA-256, cache 40,109개/39,030,630,086 bytes, cold DB/SQLite/hosts와 preflight-enabled
binding을 확인했습니다. 다음 허용 동작은 Micron `nlloperator` 관리자 세션에서
`C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1`을 한 번 실행하는 것입니다.

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
재개합니다. Samsung b22 cache 및 기존 증상별 repair chain은 새 baseline에 포함하지 않습니다. 이후 header
closure 실행 `33edfa6a-9b3c-408d-898a-88c9cf34baee`에서 오류 팝업은 사라졌지만 4/7 43%에 머물렀고,
offline `Player.log`는 세 `catalog.db`에 대해 `database disk image is malformed`와 catalog retry를 반복했습니다.
따라서 raw cache 저장은 유지하되 local-only `catalog.db` 세 body에만 Epinel `NkdbDecryptor`를 적용해 SQLite
응답을 만드는 좁은 transport 예외를 승인합니다. `.nds`는 raw이고 복호화 body는 disk/evidence/Git에 저장하지
않습니다. Client 시작 전 loopback HTTPS에서 세 SQLite body와 세 raw signature를 exact digest로 모두 확인해야
하며 하나라도 다르면 client를 시작하지 않습니다.

2026-08-25 Samsung offline 단계에서 SAUS pair staging도 완료했습니다. Mapping receipt SHA-256
`b9f2d7dbb2c266d983c3ff5088c2ca9749d2f13370172bf0dcdd9c80efbd8589`에 결박해 Epinel local-only cache의
`saus/19e939d/asset-catalog.cat`과 `.nds`에 exact encrypted body/sidecar 두 member만 추가했습니다. Staging
receipt SHA-256은 `2350aae3ba7320da21bb80a1eb26c118275b39b0678b3d844990742240f019e2`, HTTP pair contract
SHA-256은 `0a29dc7d5bfbfd53cba8735029f9fbcc708834d678c7e51ea5a84b234fc3a65d`, tool-binding receipt
SHA-256은 `604ae318c4fefda2371e1e74eb648e008359758e8231ef95fbbbf3ff357c03a5`입니다. Active cache는
40,111개/39,030,643,658 bytes이고 client/server는 실행하지 않았습니다. 다음 동작은 Micron `nlloperator`에서
기존 start wrapper를 한 번만 실행하는 것입니다. Wrapper는 bootstrap 전에 새 SAUS body/sidecar의 loopback
HTTPS status/length/SHA-256/body CRC32와 기존 header/catalog preflight를 모두 통과해야 client를 시작합니다.
상세 pin과 rollback은 `docs/PHASE3B2_EPINEL_MINIMAL_PLAN.md`의 SAUS staging 절을 따릅니다.

2026-08-25 Micron 단일 retry `e3f33bd6-49bb-4f5f-a0b4-a7646f59108c`에서 original client가 마침내
`4/7`을 통과해 원본 로비와 NIKKE roster UI에 진입했습니다. Run-start receipt SHA-256은
`b6f53d34daafd53e133fbd803834ae8d3b043f8b1da268bafb3515f761ef899b`, completion receipt SHA-256은
`da485e2e0acb72ac6772473b5e7a151be476177071ab8145c4ff1e371c838350`입니다. Completion은 DB, SQLite,
hosts와 firewall을 복구했고 runtime-cold입니다. Native cache/catalogue transport 병목은 종료합니다.

다음 병목은 account progression입니다. 복구된 local DB에는 character 193명이 있지만 tutorial group,
contents-open unlock, stage history, campaign last-stage, scenario/quest/field state가 모두 비어 있습니다. 다음
작업은 (1) Epinel native tutorial completion을 exact table에 맞춰 offline materialize하고 (2) official identity나
credential을 복사하지 않는 비민감 campaign-progress projection으로 Solo Raid의 exact unlock 조건을 충족하는
것입니다. Epinel `complete-all-stages`는 reward/currency/level/quest까지 광범위하게 변경하므로 사용하지 않습니다.
구현 전에 exact build `ContentsOpenTable`의 Solo Raid 조건과 필요한 coherent state 집합을 먼저 봉인합니다.

2026-08-25 tutorial-only 단계도 Samsung offline에서 완료했습니다. 로비 성공 상태는 golden seal
`15089f3e-92f2-4833-ab1b-348d1463f9fc`, receipt SHA-256
`ebf5c2f7692e7de7ec9b8bcf3acba112cdb8efbfbb888967acde7e429e877f9c`로 보존했습니다. Exact
`StaticData.pack`의 tutorial 448 row/40 group을 Epinel native `finish-all-tutorials` 의미로 materialize한 revision은
`8ba2fb71-913c-4eaf-a56e-55c10c79d5c1`, receipt SHA-256은
`5685274460cd64bee2391a962ec0988b5938dbb0f3ee98ac64e16c8204e31f00`입니다. DB는 `c103b44b…`에서
`e8c6c7d2…`로 바뀌었지만 character 193과 campaign/contents-open/stage/scenario/quest/field state는 모두
그대로이며 private tutorial projection은 남기지 않았습니다. 기존 성공 DB·도구·runtime·소스 bundle과 tutorial
before/after DB는 Micron 및 Samsung 보호 경로에 이중 보존했습니다.

Inner Start 도구는 새 DB와 tutorial receipt를 fail-closed 검증하도록 bound됐습니다. 새 SHA-256은
`00270a38140f4ace8e77192e285731909a172e4e587c80394bac7bb55650e7ae`, binding receipt SHA-256은
`6706cae31a8c3e08426c0470142ad20b3b02726ae39fe655ef911ca5ce591ede`입니다. Cache shape는 여전히
40,111개/39,030,643,658 bytes이고 partial member는 0입니다. 다음 허용 동작은 Micron `nlloperator`에서
`C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1`을 한 번만 실행해 tutorial 유도 제거와 lobby 진입을
검증하는 것입니다. 이 run에서 campaign 진행이나 Solo Raid 해금을 기대하지 않으며, 완료 후 client를 직접 닫고
completion을 실제 lobby outcome으로 한 번 실행합니다.

2026-08-26 첫 tutorial validation은 outer wrapper의 과거 inner-start digest pin 때문에 client 시작 전에
`phase3b2_epinel_catalog_transport_start_input_missing_or_drifted`로 중단됐습니다. 단일 pin 수정 뒤 발생할 수 있는
두 번째 SAUS binding 실패도 사전 감사에서 확인했습니다. 과거 SAUS binding과 lobby 성공 wrapper는 수정하지 않고,
새 tutorial wrapper rebind receipt가 과거 inner/wrapper에서 현재 tutorial inner와 새 wrapper까지의 전이를 증명하도록
수정했습니다. Read-only audit는 golden/tutorial/SAUS/DB/도구 전체와 cache `40,111개 / 39,030,643,658 bytes /
partial 0`을 통과했고 candidate wrapper는 `21,624` bytes/SHA-256 `4711bf99…`입니다.

다음 허용 동작은 Samsung 관리자 PowerShell에서 아래 offline repair를 한 번 실행하는 것입니다. Receipt를 검토하기
전에는 Micron을 부팅하지 않습니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\repair-phase3b2-epinel-tutorial-native-cache-rebind-offline.ps1'
```

이 repair는 outer wrapper 하나만 교체합니다. DB/cache/server binary/inner start는 변경하지 않으며, 실패 시 기존
wrapper를 자동 복구합니다. 배포 후 문제가 생겨 Samsung offline에서 명시적으로 원복해야 할 때만
`rollback-phase3b2-epinel-tutorial-native-cache-rebind-offline.ps1`을 사용합니다. Repair receipt가
`historicalSausEvidencePreserved=true`, `goldenBaselinePreserved=true`, 세 mutation flag가 모두 `false`,
`clientExecutionStarted=false`를 출력해야만 Micron tutorial validation 한 번을 허용합니다.

위 v1 repair 뒤 Micron start는 client 시작 전 같은 aggregate error로 중단됐습니다. 원인은 v1 wrapper에 잘못
결박한 catalog transport repair SHA-256 `fcd14693…`와 catalog contract SHA-256 `4e7903b5…`이며, 실제 값은
각각 `fcd1469e6c348a91f2a9ef5bef02ad52d6a95099b20a3ff354c73fb36d40f430`과
`4e7903d912b3859691864b22a75a53e80881c744bd0fbee9e375036142d65654`입니다. v1 audit에서 이 두 precursor를
직접 검사하지 않은 것이 누락이므로 v1 repair는 재사용 금지입니다.

새 v2 audit는 wrapper의 required input 20개를 실제 offline Micron 파일과 길이/SHA-256으로 전수 비교했고
`20/20` match, runtime cold, active pointer 없음, SQLite runtime 0개, cache `40,111 / 39,030,643,658 /
partial 0`을 확인했습니다. Corrected wrapper는 `23,779` bytes/SHA-256 `26dccd12…`입니다. 다음 허용 명령은
Samsung 관리자 Windows PowerShell에서 아래 한 번뿐입니다. Receipt 검토 전에는 Micron을 부팅하지 않습니다.

```powershell
& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\repair-phase3b2-epinel-tutorial-native-cache-wrapper-correction-v2-offline.ps1'
```

v2 tutorial validation assessment `de00aafb-bab3-48ca-8caf-49261a49a654`도 `catalogue_path`에서 System Error가
발생했습니다. 운영자는 이 lane의 추가 증상 patch를 중단하고 실제 lobby 성공 golden seal
`15089f3e-92f2-4833-ab1b-348d1463f9fc`로 복귀하기로 결정했습니다. Samsung offline 비교에서 golden manifest의
427개 active 대상 중 drift는 DB, outer wrapper, inner start의 세 개뿐이고 server DLL과 나머지 424개는
일치합니다. Cache도 `40,111 / 39,030,643,658 / partial 0`입니다.

현재 run은 Micron completion 없이 종료되어 active pointer, applied hosts와 SQLite runtime 3개가 남아 있습니다.
성공 completion receipt를 만들지 말고 다음 Samsung 관리자 Windows PowerShell 5.1 도구로 offline recovery를
실행합니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\restore-phase3b2-epinel-lobby-golden-baseline-offline.ps1'
```

이 도구는 실패 run을 backup/archive하고 base hosts 및 golden 세 파일만 복구합니다. Cache/server binary는
변경하지 않습니다. Receipt 검토 뒤 Micron `nlloperator` 관리자 PowerShell에서 배포된
`C:\NLL\Tools\Finalize-Phase3B2-Epinel-Lobby-Golden-Restore.ps1`을 한 번 실행해 남은 extension firewall rule을
제거합니다. 새 Start 또는 validation은 실행하지 않고 다시 Samsung으로 돌아와 golden baseline 위의 progression
구현을 시작합니다.

Golden restore finalization은 receipt SHA-256 `6d4c9fadd0c500cca3a95f3c2eeae7a141eacacc073167874c1eff2989d4a4e3`로
완료됐습니다. 현재 Micron DB는 lobby 성공 golden `c103b44b…`이고 기존 start/completion 네 파일도 golden
digest입니다. Tutorial revision은 active가 아니고 runtime은 cold입니다.

운영자가 제공한 `nikke_full_scroll_result.json`은 원문을 복사·커밋하지 않고 캠페인 진행도 세 필드만 읽었습니다.
Exact Micron static data 해석 결과는 Normal `48-44`, Hard `48-44`, Story/Easy `48-6`입니다. Capture에는
tutorial completion이 없으므로 tutorial skip은 exact client table의 40 terminal group을 쓰는 local synthetic
state로 명시적으로 분리합니다. Solo Raid unlock StageClear는 exact table의 `6-4`이고 Museum은 제외합니다.

Candidate DB는 545,413 bytes/SHA-256 `3009a738fa809d16e4b5026c70ff39fbd71a6c95e5ad1270727aaff02e277f96`이며
Epinel runtime round-trip을 통과했습니다. `StageClearHistorys`, scenario, quest, reward/currency는 만들지 않았고
character 193명과 나머지 canonical state는 유지됩니다. Golden 도구는 수정하지 않고 별도 UserProgression
start/completion 계열을 추가하며, offline rollback은 DB와 이 새 도구만 되돌립니다.

Windows PowerShell 5.1 TEMP generation validation은 staging, 후보 DB, 파생 start/completion 네 파일의 구문·해시
결박을 모두 통과했습니다. 이 검증은 Micron을 변경하지 않았고 progression 도구도 아직 `0`개입니다.

Deployable staging `ed26dd36-2640-4c79-9f82-790ad3af77bf`는 완료됐습니다. Receipt는 3,166 bytes/SHA-256
`a327f63b38fd417f920788d30742e0b6f8321785fdacd610832ce38bb753576a`이고 candidate DB는 545,413 bytes/SHA-256
`3009a738fa809d16e4b5026c70ff39fbd71a6c95e5ad1270727aaff02e277f96`입니다. 보호 pointer와 실제 파일의 digest가
일치하고 `consumed=false`이며, Micron은 golden DB/wrapper 그대로이고 progression tool count는 `0`입니다.

다음 허용 명령은 Samsung 관리자 Windows PowerShell의 offline apply 한 번입니다. 결과 JSON을 검토하기 전에는
Micron을 부팅하지 않습니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\apply-phase3b2-epinel-user-progression-offline.ps1'
```

Offline application `072cfb5c-d0a1-4a00-b307-cc78b9c981e2`는 완료됐습니다. Micron receipt는 2,320 bytes/SHA-256
`c6bfdc4a982d8341b88b03509a9e1252896031b75061388d039539efd95f1fce`이고 applied DB는 candidate
`3009a738…`입니다. 네 파생 도구의 실제 길이·SHA-256과 PowerShell syntax를 교차검증했고 golden wrapper/inner는
변경되지 않았습니다. Golden DB backup `c103b44b…`와 rollback plan `00ef55e2…`도 일치합니다. Application
pointer는 `rolledBack=false`, staging은 `consumed=true`, active pointer와 runtime process는 0입니다.

다음 허용 동작은 Micron `nlloperator` 관리자 세션에서 아래 새 start를 한 번 실행하는 것입니다. 기존
`Start-Phase3B2-Epinel-NativeCache.ps1`은 사용하지 않습니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& 'C:\NLL\Tools\Start-Phase3B2-Epinel-UserProgression.ps1'
```

Global 선택 뒤 tutorial 강제 진입 부재와 lobby를 먼저 확인하고, 가능하면 Solo Raid menu까지만 관측합니다. Start가
정상 receipt를 출력한 경우 NIKKE 창을 직접 닫은 뒤 새 UserProgression completion을 실제 stage/outcome으로 한 번
실행합니다. Start가 예외를 출력하면 completion이나 start를 반복하지 않습니다.

첫 UserProgression start assessment `ea00cdc1-efea-412a-8ed9-fee4ab6038e3`은 client 시작 전에
`bootstrap_exited_before_receipt`로 중단됐습니다. 자동 rollback은 완료됐고 active pointer/SQLite runtime은 없으며
DB `3009a738…`, completion 도구, cache, server DLL과 base hosts는 보존됐습니다. 원인은 파생 inner start가 physical
bootstrap이 지원하지 않는 evidence lane `epinel-user-progression-client-start-v1`을 전달한 packaging 오류입니다.

수정 범위는 inner lane을 `p2-client-start-v2`로 복원하는 것과 outer wrapper의 expected inner digest를 갱신하는 것,
정확히 두 runtime 파일뿐입니다. `-ValidateOnly`에서 candidate inner `ba435c45…`, outer `0ff50ecd…`, PS5.1 syntax
error 0과 두 역치환 exact match를 확인했습니다. Codex의 실제 적용 시도는 비관리자 검사에서 mutation 전에 중단됐으므로
현재 Micron 도구는 아직 broken digest `397b4b7b…`/`18bbf93e…` 그대로입니다.

Samsung 관리자 Windows PowerShell에서 다음 repair만 한 번 실행합니다. Receipt를 검토하기 전에는 Micron을 부팅하거나
UserProgression start/completion을 실행하지 않습니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\repair-phase3b2-epinel-user-progression-bootstrap-lane-offline.ps1'
```

Lane repair 뒤 assessment `3e6a398d-b79d-4a77-b049-732d576b264a`는 client를 시작했지만 `catalogue_path`의
`System Error`로 끝났습니다. 정상 completion receipt는 1,747 bytes/SHA-256
`bb486bee608f4381002b94433676531706978c125f0a00b36cdd2964326e2852`이며 candidate DB `3009a738…`, base hosts,
SQLite runtime 0개와 runtime-cold를 복원했습니다.

현재 운영 결정은 progression을 더 패치하지 않고 기존 lobby Golden을 DB-only 대조군으로 재검증하는 것입니다.
`restore-phase3b2-epinel-progression-to-golden-db-offline.ps1 -AuditOnly`은 Windows PowerShell 5.1에서 Golden backup
433/433, active 426/427, 유일 drift `runtime_top_level/db.json`, runtime top-level 422/422/unexpected 0, cache
40,111/39,030,643,658/partial 0을 확인했습니다. 보호 Golden 사본 검사는 관리자 actual 단계에서 mutation 전에 수행됩니다.

다음 허용 명령은 Samsung 관리자 PowerShell의 아래 DB-only recovery 한 번입니다. 이 도구는 활성 `db.json` 한 파일만
Golden `c103b44b…`로 바꾸며 wrapper, completion tool, server DLL, cache, LocalLow, hosts, progression tool, runtime binding,
startup preflight를 변경하지 않습니다. Receipt도 runtime에 결박하지 않는 detached evidence입니다. 결과 JSON을 검토하기
전에는 Micron을 부팅하지 않습니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\restore-phase3b2-epinel-progression-to-golden-db-offline.ps1'
```

Recovery가 `427/427`, drift `0`, runtime mutation `1`, DB `c103b44b…`를 확인한 뒤에만 Micron에서 기존 Golden
`C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1`을 한 번 실행합니다. 현재 `nlloperator` LocalLow는 그대로 둡니다.
Lobby가 다시 열리면 그때만 D: detached cold backup을 만들며, 그 backup을 wrapper나 preflight에 결박하지 않습니다.

DB-only recovery `30d5a069-1670-4ee8-8651-34dc69336c7f`는 완료됐습니다. Receipt는 2,464 bytes/SHA-256
`efb7c130a9023d57410cd117e3188eda514e68b54ed2898e8d08a6d86de03138`입니다. Micron/보호 Golden backup은
433/433, active Golden target은 427/427, drift 0이며 DB는 `c103b44b…`입니다. Golden start/completion 네 파일,
server DLL과 base hosts digest도 교차검증했고 두 active pointer, SQLite runtime 및 관련 process는 0입니다. Runtime
변경은 DB 하나뿐이고 LocalLow, wrapper, server, cache, hosts, binding/preflight는 변경하지 않았습니다.

이제 Micron `nlloperator` 관리자 세션에서 기존 Golden NativeCache start를 한 번만 실행합니다. 현재 LocalLow는 그대로
유지합니다. Start 예외 시 반복하거나 completion을 실행하지 않고 전체 오류를 Samsung으로 가져옵니다. Start receipt가
정상 출력된 경우에만 실제 관측 결과를 기록하고 client를 직접 닫은 뒤 Golden completion을 한 번 실행합니다.

## 2026-08-27 현재 운영 위치 — Challenge actual-play / Regroup v5

- 시즌 26 클래식 Challenge 실제 전투 진입은 성공했다. Museum과 공식 outbound fallback은 사용하지 않았다.
- 파생 v5는 v4/Golden/D:를 수정하지 않는다. Server DLL은 SHA-256 `9f350c9ba11df44365d890439f588fd29734e1ded14026934fea1c02bfed4c42`, selected-manager test는 `101/101`이다.
- Assessment `d7d5b339-4b66-4403-9dda-229cab797abf`에서 marker 결과 `4,4,4,4,6,6`을 관측했다. Regroup은 `6`, legacy non-consuming retry는 `4`다.
- Regroup 두 번 뒤 `raidJoinCount`, `recordCount`, `totalDamage` delta가 모두 `0`이고 재진입이 성공했다. Inspector verdict는 `observed_regroup_6_is_non_consuming_and_reentry_safe`다.
- Deployment/completion/marker SHA-256은 각각 `90179010e5c82fba6ff4d699fb0f913fa0f878b1100938e74645a3555752dc8a`, `5817bc8b0c3861532e118570935f396e45175bc9e25edde2f01cd7e07ad36707`, `94e0237ca0e052a64edd2b80473b2a3195346580c19c393f45e1b80c0dcec047`이다. Completion inner의 zero-safe repair SHA-256은 `cbb2fb3dd75ca038e5da8afcd128ef20c07710973eadefa79866353b8b5f1a90`이다.
- Completion 뒤 DB, base hosts, SQLite runtime과 extension firewall은 복구됐고 runtime은 cold다. Raw request payload/Player.log는 backup 대상이 아니며 runtime app log는 제거됐다.
- 다음 기술 작업은 실제 전투 완주 result 한 건을 별도 관측하는 것이다. 그 전까지 v5는 `regroup_semantics_candidate`이며 전체 Phase 3B-2 완료로 표현하지 않는다.
- D: backup은 `phase3b2-lobby-en-d830a90d-20260826T103327Z`를 불변 부모로 참조하는 새 detached checkpoint다. 기존 D: 경로를 덮어쓰거나 runtime preflight에 backup receipt를 결박하지 않는다.
- D: checkpoint `e40c70a0-16a3-4a83-9d30-b16f368ce73a`는 606개/195,874,486 bytes로 봉인됐다. 경로는 `D:\NikkeLocalLab\Backups\phase3b2-season26-challenge-regroup-v5-checkpoint-v1\e40c70a0-16a3-4a83-9d30-b16f368ce73a`, seal receipt SHA-256은 `e69ee9020abf5c77fc61f433ae56729d36c82c10289b385ee1bdde30604e3753`, manifest SHA-256은 `bed4e1ba8a58b42d3ae8e4b1d5409c0966efc19d53f6ec87cd6d426252e82b59`다. 모든 봉인 파일은 read-only이고 기존 parent seal/manifest는 각각 `e4c1f9af…`/`5fbde8b3…`로 유지된다.

## 2026-08-28 합딜·랭킹 v6 후보

- v5 actual play에서 Challenge 5덱 완주와 결과 합계 `31,145,048,111`은
  성공했지만 High Score 0, 로비의 이전 합계, Ranking 미등록을 관측했다.
- v6 source 후보는 완료 Challenge의 최고 `TotalDamage`를 GetInfo/High
  Score/로비/Ranking에 공통 투영하고, 더 낮은 후속 완주가 최고 기록과 다섯
  로그를 덮어쓰지 않게 한다.
- Ranking 상세는 `/soloraid/getrankersquad`가 담당한다. Epinel에는 이 classic
  handler가 없었으므로 새로 추가했으며, 합계를 만든 동일 기록의 5개 로그를
  덱 순서로 반환한다. `/soloraid/getranking`은 로컬 사용자 한 명을 rank 1로
  반환하고 공식 backend fallback은 없다.
- completion 진단은 `BattleResult=1` 완료/소비, `4` retry/비소비,
  `6` Regroup/비소비로 분류한다.
- external focused suite `106/106`, source manifest 20개 SHA-256
  `ca72c8933e0cc7f3c037dbca042d78dcdb98cbd2201e569e6ae744d5080fb207`,
  DLL 15,382,016 bytes/SHA-256
  `f9bb3696e8e2b550cebf01bd0065c3757cc9eb2fb064d93b000885f13fa0dba2`다.
- Samsung Windows PowerShell 5.1 관리자 배포는 deployment UID
  `6f14e2f7-b88a-42dd-9e7f-da8b3b51c1ce`로 성공했다. deployment receipt
  SHA-256은 `3aa96e0002c7661215c4d397f29e4137852d81e31a17353f584f22de75f63791`이며,
  runtime DLL과 네 start/completion 도구를 실제 E: 대상에서 다시 해시해 receipt와
  일치함을 확인했다. runtime은 cold이고 validation run은 미소모다.
- 권위 배포 엔진인 Windows PowerShell 5.1에서 v5/Micron Golden/D checkpoint
  불변 지문은 `389e9babfe045a336071a73b26adb4c7a1e322ec66b030a9d8bc2787c2fff0b5`다.
  같은 고정 개별 SHA 집합을 PowerShell 7로 audit하면 `Sort-Object` 문자열 정렬 차이로
  집계 지문만 `9d20896ad82984e90cd63a14bbccc323e3b80678676ef243ab87daea4df7c095`가 된다.
  이는 대상 drift가 아니며, 교차 PowerShell canonical ordering 고정은 actual-play 뒤
  후속 도구 개선으로 남긴다.
- 배포 스크립트는
  `scripts/deploy-phase3b2-epinel-solo-raid-score-ranking-v6-offline.ps1`이다.
  현재 권위 상태는 `deployed_validation_not_consumed`이며, 다음 단계는 Micron의
  `nlloperator`에서 Challenge 5덱 완주 한 번으로 result 합계, High Score, 로비 합계,
  Ranking 합계와 Ranking 상세 5덱 합계의 동일성을 검증하는 것이다.
- 2026-08-28 배포 직전 재감사에서도 external focused suite `106/106`, 후보 DLL,
  source manifest, v5 runtime cold, Micron Golden과 D checkpoint 불변성이 모두
  통과했다. Phase 0/2A1/2A2/2B unit/3A/3B-0/3B-1/3B-2 계약 게이트도 통과했다.
  `verify-repository.ps1` umbrella만 기존 `origin` remote 및 과거 `.trn` 산출물
  정책 위반 때문에 실패하며, 이는 v6 변경의 회귀가 아니다. v6 배포 스크립트
  syntax error는 0이고 관련 변경의 `git diff --check`도 통과했다.
- 첫 관리자 배포의 `candidate_dll_drift`는 external commit SHA가 DLL의
  `AssemblyInformationalVersion`에 자동 포함된 것이 원인이었다. v6 build는 이제
  source revision 자동 포함을 끄며, 두 번 연속 빌드에서 동일한 위 DLL digest를
  확인했다. 이 실패는 배포 mutation 전에 발생했다.

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
