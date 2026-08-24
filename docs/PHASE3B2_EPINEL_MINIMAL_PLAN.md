# Phase 3B-2 Epinel 최소 통합 계획

## 목적

원본 NIKKE PC client `150.6.9`에서 classic Solo Raid 시즌 26 Challenge를 실제 전투·HUD·결과까지 검증한다.

이번 작업선은 EpinelPS의 이미 동작하는 client bootstrap, asset cache, API 및 original-client runtime 경로를 최대한 유지한다. 이전 Physical P2의 증상별 projection 패치는 더 이상 누적하지 않는다. 시즌 26 selected-manager patch와 Micron client의 정확한 resource version만 최소한으로 결합한다.

## 실행 환경

- 대화·개발·빌드·Micron 오프라인 수정: **Samsung Windows**
- 원본 client 실행: **Micron Windows**, 전용 사용자 `nlloperator`
- Micron 물리 client 복제본: `C:\NLL\Clients\NIKKE-150.6.9-Physical`
- 주 설치본과 기존 `ccccc` LocalLow cache: 읽기 전용, 수정 금지
- 공식 launcher, 공식 로그인, 공식 API, 공식 계정 및 외부 outbound: 사용 금지

명령을 제시할 때마다 `Samsung` 또는 `Micron` 실행 위치를 명시한다.

## 고정 입력

### EpinelPS source 기준

- clean base commit: `519c3db51ec24ca19307e93e85acde7885928a72`
- clean base tree: `b9e8bfb1b1e065427a48d40cb2bcf2f30215436a`
- selected-manager integration ancestor: `92a6ca228aeb580988907b96189b2857dff2c62d`
- 작업 branch: `agent/phase3b2-season26-epinel-minimal`

`519c3db…`를 기준으로 새 branch를 만들며, 그 이후의 catalogue SQLite projection, parser probe, b22 projection, request tracing 및 증상별 repair commit은 가져오지 않는다.

### Micron client/resource 기준

- client build: `150.6.9`
- client executable SHA-256: `2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30`
- resource base: `https://cloud.nikke-kr.com/prdenv/150-b059c3f36c/StandaloneWindows64/pck/`
- core version: `150.6.b15`
- data-pack version: `651`
- latest postfix: `1c27990`
- core postfix: `b15`
- data-pack postfix: `1d5645e`
- feature-data postfix: `85b12fc`
- SAUS postfix: `19e939d`

### 봉인된 catalog set

- raw NKDB body 3개와 detached `.nds` signature 3개, 총 6개
- acquisition receipt SHA-256: `87d22ab630bea3851ad3af6b8a2b3be009c7f49b9320529186261bb38c24ae92`
- canonical set SHA-256: `d64ca266d6c1e7ee1f373a4092e777802d2a5186a243c099108c5efa3f95efd9`
- 기존 deployment UID: `bf669c3c-fcc8-4d57-9f18-32fee1288862`
- 기존 deployment receipt SHA-256: `27ec27253b56fae39967a5714a315a862908a268a62a7083d45f85df9de592f6`

Micron runtime의 EpinelPS asset route는 NKDB body를 변환하지 않고 봉인된 원본 byte와 `.nds`를 그대로 반환한다. 별도의 Samsung cold materializer만 Epinel 자체 NKDB parser로 body를 메모리에서 해석해 remote bundle closure를 계산하며, 복호화 SQLite를 disk나 Git에 저장하지 않는다.

## 확인된 원인과 폐기할 가설

### 확인된 원인

clean base의 `AssetDownloadUtil`은 cache file을 원본 byte 그대로 stream한다. 그러나 `SystemController.GetResourceHosts`는 base URL과 요청 version만 반환하고 `CoreVersionMap`과 `DataPackVersionMap`을 채우지 않는다. Micron client가 기대하는 `150.6.b15 / 651`을 명시적으로 반환하는 최소 패치가 필요하다.

### 폐기한 가설

- NKDB를 일반 SQLite로 변환해야 한다: 폐기
- 별도 key/version sidecar가 누락되었다: 공식 cache와 전용 cache 비교 결과 근거 없음
- Samsung의 후속 b22 cache를 Micron에 맞춰야 한다: 폐기
- 단계별 오류마다 새로운 transport/projection layer를 추가한다: 중단

## 포함 변경

clean base 위에서 다음 네 항목만 변경한다.

1. `GameConfigRoot`에 `ResourceCoreVersion` 추가
2. `gameconfig.json`에 `ResourceCoreVersion: 150.6.b15` 고정
3. `/v1/resourcehosts2` 응답에 target build의 core/data-pack version map 추가
4. handler-isolation test로 `150.6.b15 / 651` 응답을 고정

local-only 실행에 이미 필요한 `519c3db…`의 설정은 그대로 유지한다.

- headless/local-only mode
- official asset/locale/git update 차단
- local-only HTTP/3 비활성
- 민감 cache path logging 비활성
- selected-manager season 26 patch
- raw cache byte streaming

## 제외 변경

- NKDB 복호화 또는 SQLite projection
- catalogue parser/probe runtime
- b22 core pin
- live request-stage tracing 확대
- 공식 launcher 실행
- 공식 outbound fallback
- anti-cheat 우회, process injection, hooking, memory patch
- primary install 또는 기존 `ccccc` cache 수정

## 실행 순서

### A. Samsung: clean external build 확정

1. external EpinelPS에서 `519c3db…` 기반 branch 생성
2. 위 네 항목만 적용
3. selected-manager, handler-isolation focused test 실행
4. local-only build 생성
5. HEAD/tree/build manifest와 binary hash를 receipt로 봉인

중단 조건: base ancestry, checkout cleanliness, test count, exact version pin 또는 raw-stream 계약이 다르면 Micron을 수정하지 않는다.

### B. Samsung: Micron 오프라인 복구

1. 실행 중 process가 없는 cold state 확인
2. 마지막 P2 실패의 DB 복구 및 SQLite runtime 제거
3. P2 hosts/firewall extension rollback
4. 기존 잘못된 SQLite transport/projection authorization을 archive
5. P0/P1 backup과 rollback chain 검증

중단 조건: runtime이 cold가 아니거나 backup/hash chain이 불일치하면 자동 변경하지 않는다.

### C. Samsung: Epinel native cache materialization

1. 기존 sealed b15 six-member set을 Epinel NKDB parser로 in-memory 해석
2. role host token이 정확히 하나인 remote bundle만 materialization plan에 포함
3. provider metadata와 `RuntimePath` row는 `not_applicable_local_runtime_asset`으로 분리
4. Micron `naps` exact identity+length member는 Samsung protected cache에 read-only 복사
5. 결손 또는 size mismatch member만 Samsung cold materializer가 exact static CDN path로 획득
6. 전체 native cache의 declared length와 canonical SHA-256 manifest를 봉인
7. 완성 뒤에만 clean external build, raw catalog/signature와 cache를 Micron에 offline staging
8. gameconfig pin, hosts, CA, certificate bundle, sodium shim과 firewall rollback manifest 재봉인

중단 조건: Micron client hash, b15 set, native cache member count/length, version map 또는 rollback manifest 중 하나라도 불일치하면 client를 시작하지 않는다. 전체 cache materialization 전에는 추가 Micron retry를 소비하지 않는다.

### D. Samsung: source-free preflight

server/client를 시작하지 않은 상태에서 다음을 검증한다.

- exact build/hash
- local-only mode와 wildcard/LAN 차단
- official outbound 차단
- `resourcehosts2`의 `150.6.b15 / 651`
- raw NKDB와 `.nds` byte 보존
- 시즌 26 selected manager exact selection
- DB baseline과 rollback 가능성

### E. Micron: 단일 reference run

`nlloperator`로 부팅한 뒤 승인된 start wrapper를 한 번만 실행한다.

1. client 1회 시작
2. 30초 interactive health measurement
3. 4/7 catalogue path 통과 관측
4. lobby 진입 관측
5. Solo Raid → classic 시즌 26 → Challenge 진입
6. 실제 전투, HUD, damage, 결과 화면 관측
7. 즉시 completion/rollback 도구 실행

기존 10분 baseline receipt가 있으므로 매 interactive retry마다 10분을 반복하지 않는다. 운영자가 조작해야 하는 시점과 완료 도구 실행 시점을 콘솔에서 명확히 표시한다.

### F. Micron/Samsung: 종료 및 증거 봉인

- client/bootstrap/server 순서로 정상 종료; 필요 시 bounded 강제 종료
- DB baseline 복구와 SQLite runtime 제거
- hosts/firewall extension rollback
- raw secret, token, identity, raw proprietary asset를 evidence에 복사하지 않음
- Samsung 복귀 후 receipt/hash와 화면 단계만 보호 위치에 봉인

## 성공 조건

다음 조건을 모두 만족해야 actual-play 성공으로 판정한다.

- 원본 client build/hash 일치
- 공식 outbound, 공식 identity/credential, official launcher 사용 없음
- 4/7 및 lobby 통과
- classic 시즌 26 selected manager가 선택한 Challenge wave 실행
- original client의 실제 battle runtime, HUD, damage, result 관측
- Museum 미사용
- primary install과 기존 `ccccc` cache 미수정
- completion 후 DB/network/client mutation rollback 검증

## 현재 상태와 다음 작업

- 현재 부팅: Samsung Windows
- main repository branch: `agent/phase3b2-wave1-sandbox`
- external EpinelPS branch: `agent/phase3b2-season26-epinel-minimal`
- external HEAD: `116c35fb2d31ae4738142cc5f7a08b935e7a693d`
- external tree: `9a308834300373c88b1ed1083d4484214fd43a00`
- checkout clean: `true`
- .NET SDK: `10.0.400`
- selected-manager test: `64/64` passed
- handler-isolation test: `6/6` passed
- Micron deployment build file count: `577`
- deployment build content byte length: `193938021`
- canonical build manifest SHA-256: `44a5d022389d21138c79b7003173581ec5ddb0b4c7126cd4c52778f31f554e39`
- deployment `EpinelPS.exe` byte length: `162304`
- deployment `EpinelPS.exe` SHA-256: `a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b`
- deployment `EpinelPS.dll` byte length: `15364096`
- deployment `EpinelPS.dll` SHA-256: `ba46ae42b59c2058c7c8e5b02e31af1fe32a28e70d685f3a470e63adefc60cfc`
- deployment `gameconfig.json` SHA-256: `c3154538fb69a8fc6f2b23cea73fd1a8667acd0317a05c93c96bae84a6dcf945`
- deployment build receipt path: `%LOCALAPPDATA%\NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalBuild-v3\build.receipt.json`
- deployment build receipt SHA-256: `9fc554705e3d9778bf0d56e2bd5ea8399909bb8acf53ae39ba61668cd02af98d`
- 먼저 생성한 self-contained publish v1 receipt는 보존하지만 Micron 배치에는 사용하지 않는다.
- Micron offline recovery contract: `nll/phase3b2-epinel-minimal-p2-offline-recovery/v1`
- recovered failed assessment UID: `8a38765e-4d53-4bc2-9207-df8b0e6bcba5`
- restored DB baseline SHA-256: `c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194`
- archived post-failure DB SHA-256: `e524a3c8967af6bb8447fda0c50fc8a86ebccd02e1d1a45df73b2625430acc8d`
- archived SQLite runtime member count: `3`
- raw catalog member count verified during recovery: `6`
- Micron recovery receipt path: `E:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-recovery-v1\recovery.receipt.json`
- Samsung recovery receipt path: `%LOCALAPPDATA%\NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalRecovery-v1\recovery.receipt.json`
- recovery receipt SHA-256: `fcf155d15936c02796bbfbe8bbac37df9e2afecab6c9a2b40006f7049233ba41`
- recovery backup manifest SHA-256: `978454fc54e9c8669f6ae15b6d5c0ef47ee2b927789c26f3d67b3c133b9d0244`
- Samsung에서 실행 중이던 공식 NIKKE/launcher process는 Micron offline file의 exclusive-read 검증과 분리했으며 변경하거나 종료하지 않았다.
- minimal deployment contract: `nll/phase3b2-epinel-minimal-offline-deployment/v1`
- initial v1 deployed build file count/content bytes: `577 / 193938533`
- initial v1 deployed build manifest SHA-256: `a2ad30f684b4697266557a86a22dd770b39c6ce3ef90af740e86ea17f8308cc0`
- initial v1 deployed `EpinelPS.dll` SHA-256: `25b7251f860518418ae8f50c59c311f25cf3a2615ded34a12f07ab845168bb38`
- preserved cache member count/content bytes: `11 / 43007317`
- preserved cache manifest SHA-256: `2f26e48f2243955d377a93bf4fcb6875b34d65aa0feb529eb2921801c3febf2e`
- raw catalogue member count: `6`
- prior server root backup manifest SHA-256: `542a042d94b85758dcbdc10574029f7d8debc1b79b7f5a44e289e8bd326fc6b7`
- Micron deployment receipt path: `E:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-deployment-v1\deployment.receipt.json`
- Samsung deployment receipt path: `%LOCALAPPDATA%\NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalDeployment-v1\deployment.receipt.json`
- deployment receipt SHA-256: `101a43a90791bf79f62ac661f35802ed53261cda37d22d7d68b6d4bff487befa`
- rollback tool SHA-256: `f219bafa459b645149298f8906ba364050faf2b3808fb1ceda550c62d2976990`
- source-free preflight contract: `nll/phase3b2-epinel-minimal-source-free-preflight/v1`
- preflight verdict: `ready_to_stage_single_micron_reference_run_tools`
- Micron preflight receipt path: `E:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-preflight-v1\preflight.receipt.json`
- Samsung preflight receipt path: `%LOCALAPPDATA%\NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalPreflight-v1\preflight.receipt.json`
- preflight receipt SHA-256: `f6699da26a55c95ab0d5ed250930910896b098b245907ac73d852fd700f36b0a`
- source-free preflight에서 build 577개, cache 11개, raw catalogue 6개, DB baseline, P0/P1, physical client/certificate/shim, dedicated operator와 rollback tool을 다시 검증했다.
- reference tool deployment contract: `nll/phase3b2-epinel-minimal-reference-tool-deployment/v1`
- deployed tool member count: `4`
- tool manifest SHA-256: `d7ddd8872d709690c2b25f82478543e554938831e95ed88e8a5c51f9d1ed0b6f`
- Micron tool deployment receipt path: `E:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-tools-v1\tool-deployment.receipt.json`
- Samsung tool deployment receipt path: `%LOCALAPPDATA%\NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalReferenceTools-v1\tool-deployment.receipt.json`
- tool deployment receipt SHA-256: `1d1081031ec706381d752f5eba5b61784b0f55e228eec6694ed5446b2d2f00ec`
- start/completion 도구는 기존 파일을 덮어쓰지 않고 배치됐으며, source와 Micron copy의 네 SHA-256이 모두 일치한다.
- 첫 Micron reference run `eae0f37c-6939-446f-93f6-d88c1c447311`은 client와 local login까지 정상 실행됐지만, 30초 벽시계 동안 관측 연산이 포함되어 13개 표본만 생성된 것을 고정 최소 15개 표본 조건이 실패로 오판했다. 13개 표본은 모두 응답 정상이고 non-loopback 연결은 0건이었다.
- 실패 rollback은 자동 완료됐고 DB baseline 복구, SQLite runtime 제거, active pointer 부재를 검증했다. 따라서 뒤이어 실행한 completion의 `pointer_missing`은 별도 장애가 아니라 start 실패 rollback 후의 예상 결과다.
- 실패 증거의 server stdout에서 발견된 local synthetic auth token 한 줄은 원문 백업 없이 `[REDACTED]`로 교체했다. recovery receipt SHA-256은 `4b37cac89e123351a25ba9f705cc6a3ddbecd488ef627f49e27a004bc20bf8e1`이다.
- Epinel source의 local auth token console logging을 제거하고 64개 selected-manager test와 6개 handler-isolation test를 다시 통과했다. start는 이제 최소 10개 표본과 최소 28,000 ms 경과를 함께 요구하며, start 실패 및 정상 completion 모두 server stdout에 방어적 비식별화를 적용한다.
- Micron sampling/log repair contract는 `nll/phase3b2-epinel-minimal-sampling-log-repair/v1`, receipt SHA-256은 `e8fc382f236075a3b96d73c200be9a07ff00536cba4122c2d12118ce98508e2a`이다. 기존 cache 11개와 DB baseline은 보존했고 이전 server root와 도구는 rollback용으로 보존했다.
- 최종 reference tool deployment contract는 `nll/phase3b2-epinel-minimal-reference-tool-deployment/v2`, tool manifest SHA-256은 `fa845bf5c43ad6587c2d06b5a140b332636a0dc21ffd977ea4988c061f005a2d`, receipt SHA-256은 `df7b7102096961d9cb9aad5f70957262b9f880477faec6a6cef0c8dc6acbb88b`이다.
- 첫 minimal reference run `0f37da44-dc19-4f5e-b7a8-25556a9f52b3`은 server selection을 통과했지만 `4/7 catalogue_path`에서 `system_error`로 정지했다. client를 닫지 않은 상태에서 completion을 호출해 pointer는 아직 active이고, DB/SQLite/hosts는 실행 후 상태다. 추가 Micron retry 전에 Samsung offline baseline recovery가 필수다.
- Samsung native-cache materialization assessment는 `24ddf43f-ad59-464a-ae1b-c527441c203b`이다. Remote materialization member 40,097개와 fixed catalog 6개를 합한 40,103개, 39,007,142,815 bytes를 모두 declared length와 SHA-256으로 검증했다. local exact copy는 34,624개, static CDN GET 완료는 5,479개이고 network attempt는 transient retry 1회를 포함해 5,480회다.
- materialization receipt SHA-256은 `89a76b1e5237ea3864d87303418e638d9ad7de0570ad456182568a17c5ead921`, private manifest SHA-256은 `c1223ee05fec7cf3780171ead9a3e5da7f2942f129e0014995f10fabee0782a1`, canonical SHA-256은 `95000d45cb52f4bdd81b6ca9caf7e2e13eeae7bbddfa67e33ed8ef8896f22ffe`이다. Quarantine member는 0개이고 이 단계에서 Micron/server/client는 변경·실행하지 않았다.
- 현재 Micron Epinel cache 기준선은 11개, 43,007,317 bytes, canonical SHA-256 `2f26e48f2243955d377a93bf4fcb6875b34d65aa0feb529eb2921801c3febf2e`이다. Materialized set과 겹치는 raw catalog 6개를 한 번만 세면 배치 후 기대 shape는 40,108개, 39,030,629,947 bytes다.
- `scripts/recover-phase3b2-epinel-native-cache-baseline-offline.ps1`은 실패 run을 cold baseline으로 복구하고, `scripts/deploy-phase3b2-epinel-native-cache-offline.ps1`은 Samsung에서 그 복구를 확인한 뒤 39 GB cache를 staging 검산·directory swap하며 backup과 rollback을 남긴다. Codex 비승격 process에서는 Micron ACL 때문에 baseline move가 거부됐으므로 실제 배치는 Samsung 관리자 PowerShell에서 수행한다.
- 첫 관리자 배포는 robocopy 완료 뒤 Windows PowerShell 5.1 `Get-ChildItem -Recurse`가 260자를 넘는 cache path를 열거하지 못해 swap 전에 중단됐다. 활성 cache는 11-file 기준선을 유지했고, 40,108-file staging은 `staging-failed-*`로 보존됐다. .NET 10 long-path verifier로 이 staging의 39,030,629,947 bytes 전체를 manifest와 SHA-256 대조한 결과 누락·추가·digest mismatch가 모두 0이고 active canonical SHA-256은 `9c2874cd3c811609b4c8d6c34caf393aaf3e24b09825294a66b063e4fe1b521b`였다. 수정된 배포기는 이 검증된 staging을 재복사 없이 재사용하고 swap 후 long-path tree shape를 다시 확인한다.
- Long-path verifier를 포함한 external EpinelPS 도구 commit은 `6abf39b8daa1b7ee04da651e14941a2ece1ca29b`이며 clean .NET 10 build의 verifier DLL SHA-256은 `5b3c941374a68fa9090481de0e96d479f6bc40601776c98bfe1d64ac78d9b5fb`이다.
- repository tracked policy(`-AllowRemote`), Phase 0, Phase 2A1, Phase 2A2, Phase 2B unit, Phase 3A, Phase 3B-0, Phase 3B-1, Phase 3B-2 contract-only 및 Actions contract 검증이 통과했다.
- Samsung에 PostgreSQL service가 없으므로 Phase 2B live PostgreSQL integration gate는 이번 staging에서 실행하지 않았다. 이 미실행은 original-client reference run 성공을 대신하거나 약화하지 않으며, PostgreSQL 환경을 복구한 뒤 별도 gate로 수행한다.
- `verify-repository.ps1 -Mode working`은 기존 `origin` remote와 이전 도구가 남긴 untracked `.tmp-dotnet-cli-home` telemetry 때문에 실패했다. 사용자 소유 상태를 임의 삭제·변경하지 않았으며, tracked policy는 통과했다.
- Samsung에 이미 실행 중이던 공식 `nikke` process 1개는 종료·수정하지 않았다. 위 `serverExecutionStarted/clientExecutionStarted = false`는 이번 Epinel 최소 staging 작업이 새 runtime을 시작하지 않았다는 뜻이다.
- 다음 작업: Samsung 관리자 PowerShell에서 baseline 복구와 native cache offline deployment를 한 번 수행한다. 이 명령은 client/server를 시작하지 않는다.

### 다음 Samsung 실행 명령

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\deploy-phase3b2-epinel-native-cache-offline.ps1'
```

배치 receipt가 `nativeCacheDeploymentVerified=true`, `activeCacheFileCount=40108`, `stagingSourceCode=verified_prior_failed_staging_reused_without_recopy`를 출력한 뒤에만 Micron으로 부팅한다.

### 다음 Micron 실행 명령

관리자 Windows PowerShell에서 한 번만 실행한다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
```

- 서버 선택 화면이 나오면 `Global`을 선택한다.
- 진행 가능한 만큼 원본 client를 관측하거나 플레이한다.
- 오류 또는 목표 단계 관측 후에는 **먼저 NIKKE 창을 직접 닫는다**.
- start wrapper를 반복 실행하지 않는다.
- start가 예외를 출력한 경우 자동 rollback으로 active pointer가 제거되므로 completion을 실행하지 않는다. start receipt가 정상 출력되고 PowerShell prompt가 돌아온 경우에만, NIKKE 창을 닫은 뒤 completion을 실행한다.

client 종료 후 실제 관측 단계와 결과를 기록하며 completion을 한 번 실행한다. 예를 들어 4/7 System Error라면:

```powershell
& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1' `
    -ObservedStageCode catalogue_path `
    -OutcomeCode system_error
```

전투 결과 화면까지 성공했다면:

```powershell
& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1' `
    -ObservedStageCode battle_result `
    -OutcomeCode success
```

허용되는 단계 값은 `startup_only`, `server_selection`, `catalogue_path`, `lobby`, `solo_raid_menu`, `season26_challenge_battle`, `battle_result`이다. 허용되는 결과 값은 `success`, `system_error`, `operator_abort`, `client_exit`이다.

이 문서의 pin, 포함/제외 변경, 중단 조건을 바꾸는 경우에는 변경 이유와 새 hash/receipt를 먼저 기록한다.
