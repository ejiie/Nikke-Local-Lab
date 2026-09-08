# Phase 3B-2 Epinel 최소 통합 계획

> 보관 기록: 2026-09-06 문서 정리 때 이동했습니다. 본문의 ‘현재·다음·미완료’는 작성 당시 기준입니다. 현행 안내는 [문서 색인](../README.md)과 [현재 경로](../MICRON_CURRENT_PATHS.md)를 따릅니다.

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

`519c3db…`를 기준으로 새 branch를 만들며, b22 projection, 광범위한 request tracing 및 증상별 repair commit은 가져오지 않는다. 단, 아래에 기록한 Micron `Player.log`의 확정 증거에 따라 local-only `catalog.db` 세 개에만 적용되는 NKDB→SQLite transport projection과 그 사전검증 probe는 새 최소 변경으로 다시 허용한다.

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

봉인·cache 저장 형식은 raw NKDB body와 `.nds` 원문을 그대로 유지한다. Micron runtime의 EpinelPS asset route는 `--local-only`이고 요청 파일명이 `catalog.db`이며 source magic이 `NKDB`인 세 body에 한해서만 메모리에서 복호화한 SQLite byte를 응답한다. `.nds`는 원문 그대로 응답한다. 복호화 SQLite는 disk, evidence 또는 Git에 저장하지 않고 응답 후 source/decrypted buffer를 지운다.

## 확인된 원인과 폐기할 가설

### 확인된 원인

clean base의 `AssetDownloadUtil`은 cache file을 원본 byte 그대로 stream한다. `SystemController.GetResourceHosts`의 version map 결손은 이미 최소 패치로 보완됐다. Header closure 뒤 assessment `33edfa6a-9b3c-408d-898a-88c9cf34baee`에서는 4/7 오류 팝업이 사라졌지만 진행률 43%에서 멈췄고, offline Micron `Player.log`는 core/data-pack/feature-data `catalog.db`마다 `SQLiteException: database disk image is malformed`와 `Retry loading catalog`를 반복했다. `latest-651.txt` 404는 0건이었다. 즉 header 결손은 해결됐고, 다음 확정 원인은 raw NKDB body를 client가 SQLite로 여는 transport 형식 불일치다.

### 폐기한 가설

- 모든 NKDB를 일반 SQLite로 변환해야 한다: 폐기. 다만 local-only `catalog.db` 세 body의 응답 경계 projection은 확정 원인에 대한 좁은 예외다.
- 별도 key/version sidecar가 누락되었다: 공식 cache와 전용 cache 비교 결과 근거 없음
- Samsung의 후속 b22 cache를 Micron에 맞춰야 한다: 폐기
- 단계별 오류마다 새로운 transport/projection layer를 추가한다: 중단

## 포함 변경

clean base 위에서 다음 항목만 변경한다.

1. `GameConfigRoot`에 `ResourceCoreVersion` 추가
2. `gameconfig.json`에 `ResourceCoreVersion: 150.6.b15` 고정
3. `/v1/resourcehosts2` 응답에 target build의 core/data-pack version map 추가
4. handler-isolation test로 `150.6.b15 / 651` 응답을 고정
5. local-only `catalog.db` NKDB body 세 개만 Epinel `NkdbDecryptor`로 메모리 SQLite 응답
6. SQLite header 검증 실패 시 fail closed, `.nds` raw transport 유지, 변환 buffer zeroization
7. 원본 client 시작 전에 세 body의 exact SQLite length/SHA-256과 세 `.nds`의 exact raw digest를 loopback HTTPS로 검증

local-only 실행에 이미 필요한 `519c3db…`의 설정은 그대로 유지한다.

- headless/local-only mode
- official asset/locale/git update 차단
- local-only HTTP/3 비활성
- 민감 cache path logging 비활성
- selected-manager season 26 patch
- raw cache 저장과 `.nds` byte streaming

## 제외 변경

- catalog 이외 NKDB 복호화 또는 SQLite projection
- 원본 client 실행 뒤 복호화 content를 저장하는 catalogue parser/probe
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
- Long-path verifier를 포함한 external EpinelPS 도구 commit은 `6abf39b8daa1b7ee04da651e14941a2ece1ca29b`이다. 첫 재실행은 이전 clean build DLL digest를 고정한 사전검사에서 중단됐으며 cache 또는 staging은 이동되지 않았다. DLL은 source checkout의 line-ending normalization 등 비의미적 build 입력에도 digest가 달라질 수 있으므로, 수정된 배포기는 .NET SDK `10.0.400`과 Program/csproj/global.json/연결 소스/참조 SQLite binary 11개의 compile-input canonical SHA-256 `eaf339d04519010b8379ad2c30ef4321d5e6e2623a5d90116f350f0eac32bba3`을 fail-closed로 고정한다. 실제 build DLL digest는 receipt에 관측값으로 남기고 cache 검증 권위는 private manifest에 대한 member별 SHA-256 대조에 둔다.
- Native cache offline deployment `bc753164-afa2-41f2-9df1-09ea13a2d2a1`은 검증된 prior staging을 재복사 없이 사용해 완료됐다. Deployment receipt SHA-256은 `14bf845aec4cded1d80e8efb57a3eb4f4639ef68bd1fdf7a8d9de462689aae7d`, active cache는 40,108개, 39,030,629,947 bytes, canonical SHA-256 `9c2874cd3c811609b4c8d6c34caf393aaf3e24b09825294a66b063e4fe1b521b`이다. 이전 11-file cache는 `cache-before` rollback으로 보존됐고 DB/SQLite/hosts는 cold baseline이다.
- 배치 후 audit에서 Micron start wrapper에도 Windows PowerShell 5.1 `Get-ChildItem -Recurse` shape 검사가 남아 있음을 발견했다. 이는 client 시작 전 fail-closed 지점이지만 불필요한 boot round trip을 만들 수 있다. 다음 Samsung 단계는 39 GB cache를 변경·재복사하지 않고, 8-member .NET 10 verifier bundle과 long-path-safe wrapper를 offline 배치하는 것이다. Read-only long-path inspection은 현재 active cache에서 1.3초, 40,108개/39,030,629,947 bytes/partial 0으로 통과했다.
- repository tracked policy(`-AllowRemote`), Phase 0, Phase 2A1, Phase 2A2, Phase 2B unit, Phase 3A, Phase 3B-0, Phase 3B-1, Phase 3B-2 contract-only 및 Actions contract 검증이 통과했다.
- Samsung에 PostgreSQL service가 없으므로 Phase 2B live PostgreSQL integration gate는 이번 staging에서 실행하지 않았다. 이 미실행은 original-client reference run 성공을 대신하거나 약화하지 않으며, PostgreSQL 환경을 복구한 뒤 별도 gate로 수행한다.
- `verify-repository.ps1 -Mode working`은 기존 `origin` remote와 이전 도구가 남긴 untracked `.tmp-dotnet-cli-home` telemetry 때문에 실패했다. 사용자 소유 상태를 임의 삭제·변경하지 않았으며, tracked policy는 통과했다.
- Samsung에 이미 실행 중이던 공식 `nikke` process 1개는 종료·수정하지 않았다. 위 `serverExecutionStarted/clientExecutionStarted = false`는 이번 Epinel 최소 staging 작업이 새 runtime을 시작하지 않았다는 뜻이다.
- Native-cache start long-path repair receipt SHA-256은 `ed337fea541f3807664e18925477ae3f464c8a388901fc881bd93fbc4da32dc1`이다. Cache 재복사·변경 없이 40,108개/39,030,629,947 bytes를 long-path-safe verifier로 확인했다.
- 그 뒤 Micron assessment `cbce0850-d821-4f0a-99cc-fb3603c4722d`는 server selection을 통과했지만 다시 `4/7 catalogue_path`에서 `system_error`로 종료됐다. Start receipt SHA-256은 `dcae81e2298c873a5af97b60e2aa1c5e89be6829a92a76611e8cad74936e39a5`, native-cache binding SHA-256은 `b37b754059cdea2b43d3ee227ddc5f24b3b3f618c030383dfb45a097ed25e08b`이다.
- 이 실행의 Micron `Player.log`를 Samsung에서 오프라인 검산한 결과, client의 첫 결정적 실패는 `https://cloud.nikke-kr.com/prdenv/150-b059c3f36c/StandaloneWindows64/pck/latest-651.txt`에 대한 local HTTP 404였다. Active native cache 40,108개에는 이 member가 없었다.
- 추가할 header는 설치 client의 serialized content-version에서 이미 오프라인 투영·봉인된 exact 139 bytes, SHA-256 `5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a`이다. 임의 생성·공식 outbound 취득이 아니다.
- 다음 작업은 Samsung 관리자 PowerShell에서 실패 run을 cold baseline으로 복구하고 이 header 한 개만 active Epinel cache에 추가하는 것이다. 배치 후 기대 shape는 40,109개/39,030,630,086 bytes다. 시작 도구는 Epinel listener 준비 뒤, bootstrap과 원본 client 시작 전에 해당 URL이 loopback으로 해석되고 local HTTPS GET이 status 200, 139 bytes, exact SHA-256을 반환하는지 fail-closed로 확인한다.
- Header closure repair는 2026-08-24 13:41:57Z에 완료됐다. Repair receipt SHA-256은 `bc5e9e0f8f45f17c4db0408cee3d8a88389e11d1578670e9733a2563535444ce`, tool-binding receipt SHA-256은 `06967b54d83af2985c4908b3bc8a83cb246b9a17d43d699482ba542d6f523a18`이다. Active cache는 기대 shape 40,109개/39,030,630,086 bytes이고 header digest는 `5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a`로 재검증됐다. DB baseline 복구, SQLite runtime 0개, hosts baseline 복구, active pointer archive와 rollback manifest가 모두 봉인됐다.
- 바인딩된 Micron start tool SHA-256은 `1c9c053508e093df2ed3febb8e0d57ad39d5bb6b1ce2c8b96a782c35ea8874a7`, 실제 minimal start tool SHA-256은 `695a65a2ba64e07706dd95da28fcfcd197b9b584fb9f581b3a22953a5d758ea7`이다.
- Header-preflight assessment `33edfa6a-9b3c-408d-898a-88c9cf34baee`에서는 139-byte header local HTTPS preflight가 exact status/length/SHA-256으로 통과했다. 이전 System Error 팝업은 사라졌지만 4/7 43%에서 내부 retry가 지속됐다. Run start SHA-256은 `ef9b5fb8af18c421e54ee0248fbfce04cbe49d2da29f87934e04638ff8fec56f`, binding SHA-256은 `1e90a47a540de4a926e0243c2308bcbff4a930b63632adf5e157cda53bd7cf0a`이다.
- Offline `Player.log` 40,711 bytes/SHA-256 `e0f3dc129cb76865c4842ff1b0e0b39477da17bf4caa23723cbeb1861eccea1f`에서 malformed SQLite 5건, catalog retry 3건, header 404 0건을 확인했다. 세 raw NKDB body의 in-memory probe 결과 exact SQLite는 각각 core 24,707,072 bytes/`a9129fdade089805b23b389801e300921d52a7bf10a3fb4fa43d66a41ae23804`, data-pack 19,005,440 bytes/`8616dbff5eeadaf7326a6e9c64c7a4983ca2d591b52ee2c299d1ffe37493b306`, feature-data 1,310,720 bytes/`81e120aebfb192355e56d1aad8e50317c7ca38d40b52e58c862a09c1c33fa502`다. Raw decrypted content는 저장하지 않았다.
- 물리 client의 `asset-catalog-0.cat`은 read-only 검사에서 0 bytes였지만 client가 server selection과 4/7까지 진행했으므로 현재 결정 원인으로 보지 않는다. 이 파일은 수정하지 않는다.
- External 최소 transport commit은 `aa01ad90b807be1c2ceffe958519cb529622d472`, tree는 `c324c11d32365b1524f266cba6bc014e89545204`다. Selected-manager 65개와 handler-isolation 6개가 통과했다. 적용 예정 server DLL은 15,366,144 bytes/SHA-256 `aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c`다.
- 다음 허용 동작은 Samsung 관리자 PowerShell에서 실패 run을 cold baseline으로 복구하고 새 DLL/세-catalog 사전검증 도구를 Micron offline에 결박하는 것이다. 이 단계에서는 cache/client를 수정하거나 server/client를 실행하지 않는다. Repair JSON을 검토하기 전에는 Micron retry를 허용하지 않는다.

### 다음 Samsung 실행 명령

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\repair-phase3b2-epinel-native-cache-catalog-transport-offline.ps1'
```

Header repair는 이미 완료됐으므로 다시 실행하지 않는다. 현재는 위 catalog-transport repair만 실행한다. Receipt가 `decryptedSqliteBodyCount=3`, `signatureMemberCount=3`, `databaseRestored=true`, `sqliteRuntimeRemoved=true`, `hostsRestored=true`, `clientExecutionStarted=false`를 출력한 뒤 결과를 검토한다. Micron retry에서는 client 시작 전에 header 하나와 SQLite body 세 개, raw `.nds` 세 개의 local HTTPS preflight가 모두 exact status/length/digest로 봉인되어야 한다.

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

## 2026-08-25 SAUS materialization 실패 기준선

- 최신 Micron assessment는 `d78b3434-6d86-4479-b1d4-23dfd170483a`이다. Start receipt SHA-256은 `62647b3939e65180ea0272a45577f65ae4eba9062f8ecc8b94cf560c3747a72a`, completion receipt SHA-256은 `135f10e68a07f10b1fd5550be9333bdc1c2448e7af0946133162956625de11af`, native-cache binding receipt SHA-256은 `d38698828443318b150485ee0e5d17518f5ab4cdee06a8ba5da3980bb149fc92`다.
- Header 1개와 remote `catalog.db` body 3개/`.nds` 3개의 local-only preflight는 통과했고 body 3개가 모두 SQLite임을 client 시작 전에 검증했다. Non-loopback 성공 연결은 0건이다.
- Micron `Player.log`는 72,086 bytes/SHA-256 `b0a5a75e08ec513e2ecb38fc45633ffc008c9b29d21d903d58d3322b41103cee`다. Raw log는 복사하지 않았다. `SQLiteException: database disk image is malformed`와 `asset-catalog-0.cat (0)`가 각각 4회, `AssetCatalogNotInitializedException`이 1회 관측됐다.
- 물리 clone의 `saus/saus/asset-catalog-0.cat`과 `.nds`는 모두 0 bytes다. 이전에 이 0-byte pair를 결정 원인에서 제외한 판단은 최신 Player.log로 반증됐으며 더 이상 유효하지 않다.
- 정확한 Micron b15 원본과 clone의 `asset-catalog-2651531605.cat`은 모두 13,476 bytes/SHA-256 `a8ad0f199f5db1213658c3238369ad472a98db74bb3a15a274931119ca22d0df`, `.nds`는 96 bytes/SHA-256 `01de2cc79b8f04297faf262666a7701242a942ba74d48b513c0998ab08b91fa2`로 일치한다.
- Numbered NKDB를 Epinel `NkdbDecryptor`로 메모리에서만 복호화하면 114,688-byte SQLite/SHA-256 `e81638c73f62bdffefa0b7bbe5465dd06ac4258c8318d2fd6beedd0d43982f41`가 된다. 복호 byte는 disk/evidence/Git에 저장하지 않았고 검산 후 buffer를 지웠다.
- 기준선 계약은 `nll/phase3b2-epinel-saus-materialization-baseline/v1`이다. Micron과 Samsung 보호 경로의 동일 receipt는 3,103 bytes/SHA-256 `b342004950de0b9c0bd708b470f7d22e54f8057a78d41cbb27a12dcc94b390be`다.
- Completion은 DB baseline 복구, SQLite runtime 제거, hosts 복구, extension firewall 제거와 active pointer 부재를 검증했다. 현재 Micron은 offline runtime-cold이고 cache/client 원본은 변경되지 않았다.
- Retry는 허용하지 않는다. 다음 단계는 실행 없이 `asset-catalog-2651531605`에서 derived cache index `0`으로 가는 target mapping과 `.nds` 의미를 오프라인으로 증명하는 것이다. 이 두 항목이 증명되기 전에는 materialization repair를 작성하거나 Micron을 부팅하지 않는다.

## 2026-08-25 SAUS catalog target·sidecar 매핑 증명

- 메모리 전용 검사 계약은 `nll/phase3b2-saus-catalog-memory-inspection/v1`이다. 검사기는 Epinel `NkdbDecryptor`와 SQLite `deserialize`를 사용하며 복호 DB나 raw table row를 disk/evidence/Git에 쓰지 않는다.
- `asset-catalog-2651531605.cat`의 encrypted CRC32 unsigned decimal은 파일 suffix와 같은 `2651531605`다. 복호 결과는 114,688-byte SQLite이고 `integrity_check`와 `quick_check`가 모두 `ok`다. Table은 `AssetEntity`, `DependencyGroup`, `FileInfoEntity`, `LabelToUnionEntity`, `TableVersion` 5개이며 schema canonical SHA-256은 `a03049b57e60d833ad12b5ec8aeee589ce74ce9523eeab77c9f697139813d447`다.
- `StreamingAssets/aa/catalog.db`는 복호 후 24,707,072-byte Addressables 9-table SQLite로 별도 역할임을 확인했다. 따라서 SAUS target의 원천은 이 large catalog가 아니라 numbered 13,476-byte SAUS NKDB다.
- 빈 byte sequence의 CRC32는 `0`이고 실패 target 이름도 `asset-catalog-0.cat`이다. 최신 실패 초에 Epinel local-only asset request 6건 중 cache miss가 정확히 2건이었고, 같은 초에 clone에서 수정된 파일도 17.4206 ms 간격의 `asset-catalog-0.cat`과 `.nds` 두 개뿐이며 둘 다 0 bytes다. Target mapping은 `asset_catalog_suffix_is_unsigned_crc32_of_encrypted_body`로 판정한다.
- `latest-651.txt`가 지정한 SAUS revision은 `19e939d`지만 Epinel active cache의 해당 revision file count는 `0`이다. 올바른 numbered body와 96-byte `.nds`는 원본 Micron install과 물리 clone에서 exact SHA-256이 일치한다.
- 다섯 official catalog `.nds` 표본은 모두 96 bytes이고 공통 32-byte prefix family를 갖지만 full member는 다섯 개 모두 다르다. Body basename에 `.nds`를 붙이는 exact sidecar pair mapping은 검증했다. 공개 key 없이 암호학적 서명 검증을 수행하거나 권위를 주장하지 않는다.
- 매핑 증명 계약은 `nll/phase3b2-epinel-saus-catalog-mapping/v1`이다. Micron과 Samsung 보호 경로의 동일 receipt는 4,735 bytes/SHA-256 `b9f2d7dbb2c266d983c3ff5088c2ca9749d2f13370172bf0dcdd9c80efbd8589`다.
- 이 단계는 Micron cache/client/install을 수정하지 않았고 server/client를 실행하지 않았다. DB/SQLite/hosts/firewall은 cold baseline이며 retry는 아직 허용하지 않는다.
- 다음 단계는 exact official encrypted SAUS body와 `.nds` sidecar만 Epinel local-only server cache에 offline staging하고, client 시작 전 loopback HTTP body/sidecar length·SHA-256·CRC32 preflight와 rollback을 봉인하는 것이다. 그 receipt를 검토하기 전에는 Micron을 부팅하지 않는다.

## 2026-08-25 SAUS local-only HTTP pair staging

- Staging UID는 `91e926f1-1073-4bb1-a0ae-6ad70dbab935`이고 계약은 `nll/phase3b2-epinel-saus-pair-staging/v1`이다. Micron과 Samsung 보호 경로의 동일 receipt는 2,139 bytes/SHA-256 `2350aae3ba7320da21bb80a1eb26c118275b39b0678b3d844990742240f019e2`다.
- Epinel cache의 `prdenv/150-b059c3f36c/StandaloneWindows64/pck/saus/19e939d/asset-catalog.cat`에 exact encrypted 13,476-byte body/SHA-256 `a8ad0f199f5db1213658c3238369ad472a98db74bb3a15a274931119ca22d0df`를, 동일 basename의 `.nds`에 exact 96-byte sidecar/SHA-256 `01de2cc79b8f04297faf262666a7701242a942ba74d48b513c0998ab08b91fa2`를 배치했다.
- HTTP pair contract SHA-256은 `0a29dc7d5bfbfd53cba8735029f9fbcc708834d678c7e51ea5a84b234fc3a65d`다. Body의 unsigned CRC32 `2651531605`와 expected client materialized basename `asset-catalog-2651531605.cat`을 결박한다. `.nds`의 암호학적 서명 검증을 수행했다는 주장은 계속 하지 않는다.
- Active cache는 long-path verifier로 40,109개/39,030,630,086 bytes에서 40,111개/39,030,643,658 bytes로 정확히 두 member만 증가했고 partial member는 0이다.
- Minimal start tool SHA-256은 `a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69`, 배치 wrapper SHA-256은 `fe667ba466ea27a5bfd55e09c4d0cd9ef94b04d434d95ac1590ccd7f813e493b`, tool-binding receipt SHA-256은 `604ae318c4fefda2371e1e74eb648e008359758e8231ef95fbbbf3ff357c03a5`다.
- 새 start path는 Epinel listener 준비 뒤 bootstrap 전에 body와 sidecar를 loopback HTTPS로 GET하고 status 200, 길이, SHA-256 및 body CRC32를 모두 확인한다. 기존 header 1개와 catalog body 3개/sidecar 3개의 preflight도 유지한다. 하나라도 다르면 client를 시작하지 않는다.
- 기존 start/wrapper는 `E:\NLL\Backups\Phase3B2\EpinelSausPair-v1\91e926f1-1073-4bb1-a0ae-6ad70dbab935`에 보존했고 rollback plan SHA-256은 `6e9173e0cccf4ced451414a9f2585cda137f508642745340e4137a19d49f826c`다. Repository rollback 도구는 exact pair와 active tool digest가 모두 일치할 때만 두 member를 제거하고 기존 도구를 복구한다.
- 이번 staging에서는 source catalog, physical client, primary install과 기존 operator cache를 수정하지 않았고 server/client를 실행하지 않았다. Runtime은 cold이며 retry consumption은 여전히 없다.
- 다음 단계는 이 receipt를 기준으로 Micron `nlloperator`에서 preflight-enabled wrapper를 한 번만 실행하는 것이다. 아직 실제 `4/7` 통과나 original-client runtime 성공을 주장하지 않는다.

## 2026-08-25 original-client lobby 성공과 account-state 후속 lane

- 단일 허용 retry assessment `e3f33bd6-49bb-4f5f-a0b4-a7646f59108c`에서 original client가 `4/7`을 통과해 원본 로비와 NIKKE roster UI에 진입했다. Run-start receipt는 2,731 bytes/SHA-256 `b6f53d34daafd53e133fbd803834ae8d3b043f8b1da268bafb3515f761ef899b`, completion receipt는 1,735 bytes/SHA-256 `da485e2e0acb72ac6772473b5e7a151be476177071ab8145c4ff1e371c838350`이다.
- Client 시작 전 header 1개, decrypted SQLite catalog body 3개와 raw `.nds` 3개, encrypted SAUS body 1개와 raw `.nds` 1개의 loopback HTTPS preflight가 모두 통과했다. SAUS body CRC32도 일치했고 non-loopback 성공 연결, official launcher, official outbound fallback, anti-cheat substitution은 모두 없었다.
- 운영자가 client를 직접 닫은 뒤 completion은 DB baseline 복구, SQLite runtime 3개 제거, hosts 복구, extension firewall 제거와 runtime-cold를 검증했다. 이 성공으로 native cache/catalogue transport 병목은 종료하며 같은 영역의 자동 retry나 증상별 patch를 더 만들지 않는다.
- 복구된 local Epinel baseline DB는 user 1명, character 193명을 가지지만 tutorial completion group, contents-open unlock, stage-clear history, normal/story/hard last-stage, completed scenario, main quest와 field state는 모두 0이다. 로비의 tutorial 유도와 잠긴 Solo Raid UI는 이 비어 있는 account progression projection으로 설명된다.
- 후속 lane은 두 단계로 분리한다. 첫째, Epinel의 기존 `finish-all-tutorials` 의미를 exact build의 `ContentsTutorialTable` 최대 group state에 고정해 tutorial-only revision으로 봉인한다. 둘째, 전체 공식 계정이나 identity/credential을 복제하지 않고 운영자가 승인한 비민감 campaign progress 입력만 받아, exact `ContentsOpenTable` 조건으로 Solo Raid에 필요한 최소 coherent local progression을 materialize한다.
- Epinel의 기존 `complete-stage`는 reward, currency, user level, outpost level, quest, scenario, trigger와 field state까지 함께 변경하므로 검산 없이 `complete-all-stages`를 실행하지 않는다. 다음 구현은 source DB backup/rollback, before/after canonical projection, no-identity/no-credential receipt와 client 미실행 preflight를 먼저 제공해야 한다.

## 2026-08-25 lobby golden baseline과 tutorial-only revision

- 로비 성공 상태는 seal UID `15089f3e-92f2-4833-ab1b-348d1463f9fc`로 별도 봉인했다. Golden receipt는 2,596 bytes/SHA-256 `ebf5c2f7692e7de7ec9b8bcf3acba112cdb8efbfbb888967acde7e429e877f9c`다. DB `c103b44b…`, 서버 DLL `aaa1e49d…`, runtime top-level 422개, 성공 도구/receipt와 Epinel source bundle `d3206ec8…`를 Micron backup과 Samsung 보호 경로에 동일하게 보존했다. 39GB cache는 복사하지 않고 검증된 40,111개/39,030,643,658 bytes shape와 선행 manifest/receipt에 결박했다.
- Exact Micron `StaticData.pack`은 17,177,168 bytes/SHA-256 `8c0dfdca…`다. Epinel native `finish-all-tutorials`와 동일하게 448 tutorial row를 group별 최대 tutorial ID와 해당 version group으로 축약하면 40 group이며, raw identifier를 stdout/evidence/Git에 출력하지 않은 canonical SHA-256은 `70686be8…`다.
- Tutorial-only revision UID는 `8ba2fb71-913c-4eaf-a56e-55c10c79d5c1`이다. DB는 413,327 bytes/SHA-256 `c103b44b…`에서 416,762 bytes/SHA-256 `e8c6c7d2…`로 바뀌었고 tutorial group만 `0 → 40`이다. Non-tutorial canonical SHA-256 `5c0c5cc8…`는 before/after가 같다. Character 193, contents-open 0, stage history 0, normal/story/hard 0, scenario/quest/field 0도 모두 유지됐다.
- Materialization receipt는 3,186 bytes/SHA-256 `5685274460cd64bee2391a962ec0988b5938dbb0f3ee98ac64e16c8204e31f00`다. Before/after DB와 rollback plan은 Micron과 Samsung 보호 경로에 이중 보존했고 private projection은 삭제했다. Cache, 서버 binary, native-cache wrapper와 기존 operator cache는 수정하지 않았고 server/client/official outbound는 실행하지 않았다.
- Inner Start 도구는 tutorial receipt와 새 DB digest를 fail-closed preflight하도록 교체했다. 기존 성공 도구 SHA-256 `a039cd51…`는 별도 before backup에 남았고, bound 도구는 41,649 bytes/SHA-256 `00270a38…`다. Binding receipt는 1,358 bytes/SHA-256 `6706cae31a8c3e08426c0470142ad20b3b02726ae39fe655ef911ca5ce591ede`다. Active cache는 재검사에서 여전히 40,111개/39,030,643,658 bytes, partial member 0이다.
- 다음 동작은 Micron `nlloperator`에서 native-cache wrapper를 한 번만 실행하는 tutorial validation이다. 목적은 tutorial 유도가 사라지고 원본 lobby에 진입하는지만 확인하는 것이며, campaign/contents-open/Solo Raid unlock은 아직 기대하거나 조작하지 않는다. 성공 또는 오류 관측 뒤 client를 직접 닫고 completion을 `ObservedStageCode lobby`와 실제 outcome으로 한 번 실행한다.

## 2026-08-26 tutorial native-cache wrapper 전이 감사

- 첫 tutorial validation은 client 시작 전 `phase3b2_epinel_catalog_transport_start_input_missing_or_drifted`로 중단됐고 server/client는 시작되지 않았다. 원인은 tutorial binding이 inner start를 `a039cd51…`에서 `00270a38…`로 교체했지만 outer native-cache wrapper가 과거 inner digest를 계속 고정한 packaging drift다.
- 단일 digest만 교체하면 다음 preflight에서 과거 SAUS tool-binding이 현재 inner/wrapper와 동일해야 한다는 조건이 다시 실패한다. 과거 SAUS receipt SHA-256 `604ae318…`와 성공 wrapper SHA-256 `fe667ba4…`는 변경하지 않고 역사적 증거로 보존한다.
- 새 전이는 `historical SAUS binding → tutorial materialization → tutorial start binding → repaired wrapper`의 네 고리를 별도 `nll/phase3b2-epinel-tutorial-native-cache-rebind/v1` receipt로 연결한다. Wrapper는 실행 전 이 receipt, tutorial DB `e8c6c7d2…`, materialization receipt `56852744…`, start-binding receipt `6706cae3…`와 자신의 digest를 함께 fail-closed 검증한다.
- 실행 후 inner start receipt도 tutorial revision UID, receipt SHA-256, tutorial group 40과 `tutorial_only_no_campaign_or_contents_open_projection`을 반환해야 한다. 같은 필드를 native-cache run binding에도 기록한다.
- Read-only audit는 golden receipt, 두 tutorial receipt, 과거 SAUS binding, active inner/outer tool, DB와 long-path cache 전부를 재검증했다. Cache는 `40,111 / 39,030,643,658 / partial 0`이고 candidate wrapper는 `21,624` bytes/SHA-256 `4711bf99fdbe74d503d1705c37ea175b24766ab1915972beb8e91b1ed7a600a8`이다.
- 배포 도구는 `scripts/repair-phase3b2-epinel-tutorial-native-cache-rebind-offline.ps1`이다. Samsung 관리자 PowerShell에서 Micron이 offline이고 runtime이 cold일 때 wrapper 하나만 atomic replace하며 DB/cache/server binary/inner start를 변경하지 않는다. 기존 wrapper와 rollback plan은 별도 backup에 남긴다.
- 전용 원복 도구는 `scripts/rollback-phase3b2-epinel-tutorial-native-cache-rebind-offline.ps1`이다. 새 wrapper, 기존 backup, DB와 inner digest가 모두 exact match일 때만 wrapper 하나를 복구하며 rollback receipt를 Micron과 Samsung 보호 경로에 남긴다.
- 배포 receipt를 검토하기 전에는 Micron을 부팅하지 않는다. 배포 후에도 tutorial validation은 한 번만 허용하며 campaign 또는 Solo Raid unlock은 이 run의 acceptance가 아니다.

## 2026-08-26 tutorial wrapper v1 실패와 v2 교정

- v1 rebind receipt SHA-256 `673b1e91…` 검토 후 실행한 Micron start는 다시 client 시작 전 `input_missing_or_drifted`로 중단됐다. Active pointer는 없고 SQLite runtime은 0개이며 DB `e8c6c7d2…`, cache `40,111 / 39,030,643,658 / partial 0`과 wrapper `4711bf99…`는 그대로다.
- 원인은 v1 wrapper에 결박한 두 precursor digest 오기입이다. 실제 catalog transport repair는 `fcd1469e6c348a91f2a9ef5bef02ad52d6a95099b20a3ff354c73fb36d40f430`, catalog contract는 `4e7903d912b3859691864b22a75a53e80881c744bd0fbee9e375036142d65654`인데 v1 candidate는 각각 다른 값을 사용했다.
- v1 audit가 두 precursor 파일을 직접 검사하지 않은 것이 검증 누락의 원인이다. v1 repair source는 재사용을 막기 위해 `superseded_by_wrapper_correction_v2`로 fail-closed 처리하고 v1 receipt/backup은 역사 증거로 보존한다.
- v2 correction audit는 wrapper가 요구하는 deployment, verifier manifest/DLL, header closure, transport repair/contract, SAUS 3종, tutorial 3종, v1 rebind, DB, header, inner start, server DLL, prior wrapper, dotnet, hosts와 template 총 20개 입력의 길이와 SHA-256을 실제 Micron offline 파일과 직접 비교했다. 결과는 `20/20` match다.
- v2 candidate wrapper는 `23,779` bytes/SHA-256 `26dccd12c7f0daaa35ac225b0fbdb0abf7767cd0ab529a0958663efaaccf2fbc`다. v1 receipt를 수정하지 않고 새 `nll/phase3b2-epinel-tutorial-native-cache-wrapper-correction/v2` receipt가 v1 wrapper에서 corrected wrapper까지의 전이를 증명한다.
- 다음 허용 동작은 Samsung 관리자 Windows PowerShell에서 `scripts/repair-phase3b2-epinel-tutorial-native-cache-wrapper-correction-v2-offline.ps1`을 한 번 실행하는 것이다. Receipt의 `requiredInputCount=20`, `requiredInputMatchedCount=20`, `fullRequiredInputAuditPassed=true`, 모든 non-wrapper mutation flag `false`를 검토하기 전에는 Micron을 부팅하지 않는다.

## 2026-08-26 tutorial lane 중단과 lobby golden 복귀

- v2 correction receipt `8ad2a714…`의 20/20 input audit 뒤 허용한 assessment `de00aafb-bab3-48ca-8caf-49261a49a654`도 `catalogue_path`에서 `System Error`로 끝났다. 이 결과로 tutorial-only DB 투영을 original-client acceptance 경로로 더 패치하지 않는다.
- 운영 결정은 tutorial 변경 직전 실제 lobby 성공 seal `15089f3e-92f2-4833-ab1b-348d1463f9fc`를 다시 active baseline으로 삼는 것이다. Golden manifest 427개 active 비교 대상 중 drift는 `db.json`, native-cache outer wrapper, minimal inner start의 정확히 세 개뿐이며 server DLL과 나머지 424개는 golden과 같다.
- Micron completion을 실행하지 않고 Samsung으로 전환했으므로 active pointer, applied hosts와 SQLite runtime 3개가 남았다. 이를 성공 completion으로 위조하지 않는다. `restore-phase3b2-epinel-lobby-golden-baseline-offline.ps1`은 실패 run을 별도 backup에 보존하고 pointer를 archive한 뒤 base hosts, golden DB `c103b44b…`, outer wrapper `fe667ba4…`, inner start `a039cd51…`만 복원한다. Cache와 server binary는 변경하지 않는다.
- Offline restore는 방화벽 offline registry를 수정하지 않는다. 대신 `Finalize-Phase3B2-Epinel-Lobby-Golden-Restore.ps1`을 exact restore receipt에 결박해 배포하고, 다음 Micron `nlloperator` 관리자 세션에서 extension firewall group만 제거한 뒤 golden digest와 cold runtime을 다시 검증한다.
- Windows PowerShell 5.1 read-only audit는 drift `3/3`, cache `40,111 / 39,030,643,658 / partial 0`, active pointer와 applied hosts를 확인했고 verdict는 `exact_three_file_drift_and_abandoned_run_recovery_ready`다. 새 validation은 이 복귀의 일부가 아니며, finalization 뒤 Samsung에서 golden baseline을 바탕으로 progression 구현을 다시 설계한다.

## 2026-08-26 golden-parent user progression projection

- Lobby golden restore finalization은 receipt SHA-256 `6d4c9fadd0c500cca3a95f3c2eeae7a141eacacc073167874c1eff2989d4a4e3`로 완료됐다. Active DB는 `c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194`, outer start는 `fe667ba4…`, inner start는 `a039cd51…`이며 tutorial revision은 active가 아니다.
- 운영자가 제공한 credential-bearing capture는 원문 복사·커밋 없이 `GetUserProfileBasicInfo.basic_info`의 캠페인 진행도 세 필드만 추출한다. Source는 964,036 bytes/SHA-256 `efb1b38b4557e45cbefc1922649c22f6725071cb8c5cb2ad269650d7807fe605`로 고정하고 UID, credential, session, token은 추출하거나 receipt에 쓰지 않는다.
- Exact Micron build `StaticData.pack` 17,177,168 bytes/SHA-256 `8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3`로 원본 진행도를 해석한 결과는 Normal `48-44`, Hard `48-44`, Story/Easy `48-6`이다. Solo Raid StageClear 조건은 이 exact table에서 `6-4`이고 Museum row는 명시적으로 제외한다.
- Raw capture에는 tutorial completion이 없다. Tutorial skip은 exact client tutorial 448 row의 40개 terminal group을 쓰는 local synthetic UX state로 별도 표기한다. Campaign 진행도와 tutorial group은 한 후보 DB에 원자적으로 materialize하지만 출처는 receipt에서 구분한다.
- Candidate DB는 545,413 bytes/SHA-256 `3009a738fa809d16e4b5026c70ff39fbd71a6c95e5ad1270727aaff02e277f96`다. Normal/Hard/Story main-stage closure는 각각 1,787/1,787/433개, field map은 147개다. Epinel `CoreInfo/User` round-trip을 통과했다.
- `StageClearHistorys`, scenario, quest, reward/currency는 만들지 않는다. Character 193명과 progression 외 canonical state는 그대로이며, `complete-all-stages`는 사용하지 않는다.
- Golden start/completion 네 파일은 수정하지 않는다. 적용 시 별도 `Start/Complete-Phase3B2-Epinel-UserProgression.ps1` 계열만 추가하고 DB만 candidate로 교체한다. 각 run의 inner start/completion은 candidate DB를 backup·restore하며, 별도 offline rollback은 golden DB를 복원하고 progression 소유 도구만 retired evidence로 이동한다.
- `stage-phase3b2-epinel-user-progression-from-raw-offline.ps1`, `apply-phase3b2-epinel-user-progression-offline.ps1`, `rollback-phase3b2-epinel-user-progression-offline.ps1`은 Windows PowerShell 5.1 parse를 통과했다. TEMP generation validation은 네 파생 도구의 syntax와 hash binding을 통과했고 `goldenDatabaseModified=false`, `micronMutationPerformed=false`, Micron progression tool count `0`을 확인했다.
- Deployable staging `ed26dd36-2640-4c79-9f82-790ad3af77bf`는 Samsung 보호 경로에 봉인됐다. Receipt는 3,166 bytes/SHA-256 `a327f63b38fd417f920788d30742e0b6f8321785fdacd610832ce38bb753576a`, candidate DB는 545,413 bytes/SHA-256 `3009a738fa809d16e4b5026c70ff39fbd71a6c95e5ad1270727aaff02e277f96`다. Read-only 교차검사에서 pointer는 같은 receipt/candidate를 가리키고 `consumed=false`, Micron DB/wrapper는 golden digest, progression tool count는 `0`이었다.
- 다음 허용 동작은 Samsung 관리자 Windows PowerShell에서 offline apply script 한 번뿐이다. Apply receipt를 검토하기 전에는 Micron을 부팅하지 않는다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\apply-phase3b2-epinel-user-progression-offline.ps1'
```

- Offline application `072cfb5c-d0a1-4a00-b307-cc78b9c981e2`는 완료됐다. Micron receipt는 2,320 bytes/SHA-256 `c6bfdc4a982d8341b88b03509a9e1252896031b75061388d039539efd95f1fce`, applied DB는 candidate SHA-256 `3009a738…`다.
- 파생 start wrapper/inner와 completion wrapper/inner의 SHA-256은 각각 `18bbf93e…`, `397b4b7b…`, `8c5ac3c7…`, `5128eeee…`이고 Windows PowerShell syntax error는 모두 0이다. Golden wrapper/inner는 `fe667ba4…`/`a039cd51…` 그대로다.
- Protected golden DB backup은 `c103b44b…`, rollback plan은 `00ef55e2…`로 확인됐다. Application pointer는 `rolledBack=false`, staging pointer는 같은 application UID로 `consumed=true`다. Golden/progression active pointer는 없고 runtime process는 0이다.
- 다음 허용 동작은 Micron `nlloperator` 관리자 세션에서 새 `Start-Phase3B2-Epinel-UserProgression.ps1`을 한 번 실행하는 것이다. 기존 NativeCache start는 사용하지 않는다. Global 선택 뒤 tutorial 강제 진입 부재와 lobby를 먼저 확인하고, 가능하면 Solo Raid menu까지만 관측한다. Client를 직접 닫은 뒤 새 UserProgression completion을 실제 관측 단계/outcome으로 한 번 실행한다.

## 2026-08-26 user progression bootstrap lane packaging repair

- 첫 UserProgression validation assessment `ea00cdc1-efea-412a-8ed9-fee4ab6038e3`은 `physical_bootstrap_and_sail_observation`에서 `bootstrap_exited_before_receipt`로 중단됐다. Client는 시작되지 않았고 automatic rollback은 완료됐으며 active pointer와 SQLite runtime은 남지 않았다.
- 원인은 candidate DB가 아니라 파생 inner start의 packaging 오류다. Apply generator가 `NLL_PHASE3B2_EVIDENCE_LANE` 기본값을 bootstrap executable이 허용하지 않는 `epinel-user-progression-client-start-v1`로 바꿨다. Physical bootstrap은 `p2-client-start-v1` 또는 `p2-client-start-v2`만 허용하므로 receipt directory 생성 전 exit code 64로 종료됐다.
- 최소 repair의 runtime 변경 대상은 정확히 두 파일이다. Inner start의 lane 선언 1개를 `p2-client-start-v2`로 복원하고, outer wrapper의 expected inner SHA-256 1개만 새 digest로 갱신한다. DB, cache, server DLL, inner completion, completion wrapper, golden 도구와 역사 application/failure receipt는 변경하지 않는다.
- Read-only `-ValidateOnly` 검증 결과 candidate inner는 39,535 bytes/SHA-256 `ba435c458039b4260a0938a093e2f1a2d8dc427b5b7e7628dc15438b5a12bff3`, candidate outer는 17,637 bytes/SHA-256 `0ff50ecda1770cfe0feb4d254ef846ce1ab5778159ee7f9e513125c98b13999b`다. 두 파일 모두 Windows PowerShell 5.1 syntax error 0이며 각 변경을 역치환하면 원문과 exact match한다.
- Repair source는 `repair-phase3b2-epinel-user-progression-bootstrap-lane-offline.ps1`이다. Codex 비관리자 프로세스의 실제 적용 시도는 관리자 검사에서 mutation 전에 중단됐고 Micron active inner/outer는 계속 `397b4b7b…`/`18bbf93e…`다. 다음 허용 동작은 Samsung 관리자 PowerShell에서 이 repair를 한 번 실행하고 receipt를 검토하는 것뿐이다. 그 전에는 Micron start/completion을 실행하지 않는다.

## 2026-08-26 progression 실패 완료와 Golden DB-only 대조 복구

- Lane repair 뒤 assessment `3e6a398d-b79d-4a77-b049-732d576b264a`는 bootstrap/SAIL과 30초 관측을 통과해 원본 client를 시작했지만 `catalogue_path`에서 `System Error`로 끝났다. 이 결과는 packaging lane 문제가 해결됐어도 progression candidate DB가 Golden lobby acceptance를 보존하지 못했음을 뜻한다.
- 운영자가 client를 닫은 뒤 completion을 실행했다. Completion receipt는 1,747 bytes/SHA-256 `bb486bee608f4381002b94433676531706978c125f0a00b36cdd2964326e2852`이고, candidate DB `3009a738…` 복원, SQLite runtime 3개 제거, base hosts와 firewall 복원 및 runtime-cold를 확인했다. 성공 completion이나 lobby 도달로 해석하지 않는다.
- 다음 대조 run은 tutorial/progression 도구를 다시 결박하거나 수정하지 않는다. 실제 lobby 성공 Golden start/completion과 server/cache를 그대로 두고 활성 `db.json` 하나만 Golden `c103b44b…`로 돌린 뒤, 현재 `nlloperator` LocalLow는 읽거나 수정하지 않은 채 기존 `Start-Phase3B2-Epinel-NativeCache.ps1`을 한 번 실행한다.
- `restore-phase3b2-epinel-progression-to-golden-db-offline.ps1 -AuditOnly`의 Windows PowerShell 5.1 결과는 Micron Golden backup 433/433, 활성 Golden 대상 426/427, 유일 drift `runtime_top_level/db.json`, runtime top-level 422/422와 unexpected 0, cache 40,111/39,030,643,658/partial 0이다. 보호 Golden 사본은 관리자 actual 단계에서 mutation 전에 다시 검증하므로 audit verdict는 `conditional_on_administrator_protected_copy_verification`이다.
- Actual recovery는 Samsung/Micron 물리 디스크 identity와 C: 보호 경계를 먼저 확인하고 candidate DB를 Samsung 보호 경로와 Micron evidence에 이중 백업한다. 활성 runtime의 영구 변경 대상은 `db.json` 하나뿐이다. Wrapper, completion tool, server DLL, cache, LocalLow, hosts, progression tool, runtime binding과 startup preflight는 변경하지 않는다.
- Recovery receipt는 두 위치의 pending copy를 검산한 뒤에만 publish한다. Commit 전 실패는 두 DB backup을 순서대로 사용해 candidate digest까지 rollback 검증하고 uncommitted receipt를 제거한다. Recovery receipt는 runtime이나 start preflight가 참조하지 않는 detached evidence다.
- 관리자 recovery JSON을 검토하기 전에는 Micron을 부팅하지 않는다. Golden control이 lobby에 다시 도달한 경우에만 코드·DB·도구·검증 metadata를 D:에 detached cold backup으로 복사하며, 그 backup도 runtime wrapper 또는 preflight에 결박하지 않는다.
- DB-only recovery `30d5a069-1670-4ee8-8651-34dc69336c7f`는 2026-08-26 01:25:08Z에 완료됐다. Receipt는 2,464 bytes/SHA-256 `efb7c130a9023d57410cd117e3188eda514e68b54ed2898e8d08a6d86de03138`이고 Micron/보호 Golden backup은 각각 433/433 일치했다.
- 적용 뒤 active Golden 대상은 427/427, drift 0이며 DB는 Golden `c103b44b…`다. Golden start/completion 네 파일, server DLL, base hosts도 기존 digest와 일치하고 양쪽 active pointer, SQLite runtime과 관련 process는 모두 0이다. 실제 runtime mutation은 DB 하나였고 모든 binding/preflight 및 LocalLow mutation flag는 false다.
- 다음 허용 동작은 Micron `nlloperator` 관리자 세션에서 기존 Golden `Start-Phase3B2-Epinel-NativeCache.ps1` 대조 run 한 번뿐이다. 현재 LocalLow를 그대로 둔 결과를 분류하며, 성공/실패 completion 전에는 재시작하지 않는다.

## 2026-08-26 Golden control의 English SAUS 단일 A/B

- Golden control 재실패의 첫 결정적 경계는 DB나 wrapper drift가 아니라 English catalogue miss다. Exact client header `latest-651.txt`는 English revision `dee9e75`를 광고하지만 Epinel server cache에는 `pck/en/dee9e75/asset-catalog.cat`과 `.nds`가 없고, 현행 Epinel static handler는 두 요청 모두 `404 / 0 bytes`로 끝낸다. 같은 실행의 client clone `saus/en`에는 `asset-catalog-0.cat`과 `.nds`가 각각 0 bytes로 남고 `Player.log`는 malformed catalogue DB와 `AssetCatalogNotInitializedException`으로 이어진다.
- A/B UID는 `21b02d07-ff0a-44bf-8c6f-8f1b5bb4d331`이다. 두 0-byte member의 before manifest는 SHA-256 `5168cb50…`, quarantine receipt는 `3f5cce01…`, rollback plan은 `48529574…`다. Micron before-copy, Micron same-volume quarantine, Samsung protected before-copy의 세 복원 원본을 보존했으며 현재 active clone의 `saus/en`만 부재한다.
- Golden start/completion 네 파일, DB `c103b44b…`, server DLL `aaa1e49d…`는 모두 기존 digest와 일치한다. Server cache는 보호 private manifest와 파일별 SHA-256을 대조해 `40,111 / 39,030,643,658`, canonical SHA-256 `159b152960c35e8898bc1ea06dd17239b200f46e65095fa79b1aeead19dd8c56`으로 exact match했다. 이 결과의 별도 dual receipt SHA-256은 `a3c1c5a3c0e043392207b778eec24f1746f59733186c691b518aac669a490c97`다.
- 이 lane은 runtime wrapper, startup preflight, DB, server cache, hosts 또는 firewall에 새 receipt/hash를 결박하지 않는다. `ccccc` profile은 참조하지 않으며 `nlloperator` LocalLow는 Player.log read-only 관측 외에 수정하지 않는다. Samsung-side 분류/복원 도구만 detached evidence를 만들고, 정상 분류와 emergency `-RestoreOnly` 모두 original English pair 복원을 진단보다 먼저 dual checkpoint로 확정한다.
- 실행 전 fail-safe 시험은 completion receipt가 없는 상태에서 `phase3b2_english_saus_ab_completed_single_run_not_present`로 중단됐고, active `saus/en` 부재와 retry 미소비를 유지했다. 다음 허용 동작은 Micron에서 기존 Golden start를 정확히 한 번 실행하고 client를 직접 닫아 기존 Golden completion을 한 번 실행하는 것이다. 그 뒤 Samsung에서 분류/원복한다. Start 또는 completion이 정상 receipt를 남기지 못하면 재실행하지 않고 Samsung `-RestoreOnly`만 사용한다.
- 단일 A/B assessment `34a2c8b3-2b26-4cc7-980b-af9ef3beaf43`은 `catalogue_path / system_error`로 완료됐다. Completion은 client operator-close, DB restore, SQLite 3개 제거, hosts/firewall 복구와 runtime-cold를 확인했다. Player.log는 73,271 bytes/SHA-256 `1fc99d7637943daa0ef0bde392f17abd351b0c5367e2327b738d62c728911b43`이다.
- 분류 결과는 `english_revision_absent_recreated_zero_pair_same_failure`다. 실패 초에는 local-only asset request `8`, miss `2`가 있었고 client는 정확히 `asset-catalog-0.cat`과 `.nds` 두 개를 다시 만들었으며 둘 다 0 bytes였다. Player.log에는 malformed DB 4회와 `AssetCatalogNotInitializedException` 1회가 재현됐다. 따라서 pre-existing 0-byte English pair가 단독 원인이라는 가설은 기각하며, English revision server closure 또는 별도의 권위 있는 local state가 필요하다.
- 정상 분류 전에 post-run tree를 격리하고 original English pair를 same-volume 원본에서 복원했다. Restore checkpoint SHA-256은 `1fa9546a…`, post-run manifest는 `5e13af22…`, Micron/Samsung dual classification receipt는 4,326 bytes/SHA-256 `d718006deaa4d87d614febbc00b9a30e96582f74946987cbf81e8667786d90ae`다. Golden 6개와 exact server-cache canonical SHA-256 `159b1529…`는 run 전후 동일하다.
- 이 A/B retry는 소비됐고 추가 retry는 허용하지 않는다. 승인된 Micron NLL tree와 Samsung 보호 PhysicalP2 evidence에서 `pck/en/dee9e75` body/signature 후보는 발견되지 않았다. 다음 단계는 client를 실행하지 않는 English closure source audit다. 로컬 권위 source가 끝내 없으면, 별도 운영자 승인 뒤 Samsung에서 credential/cookie/proxy/redirect 없이 exact public static asset 두 member만 취득·봉인하는 새 lane을 설계해야 한다.

## 2026-08-27 시즌 26 Challenge actual-play와 Regroup v5 기준선

- 원본 client build `150.6.9`의 클래식 `SoloRaid` 시즌 26 Challenge에서 실제 전투 진입을 확인했다. `SoloRaidMuseum`, Quick Battle, Normal/Union Raid runtime은 사용하지 않았다.
- v5는 검증된 v4 관측 lane에서 파생한 별도 runtime/tool lane이다. v4, Micron lobby Golden과 기존 D: full Golden은 수정하지 않았다. Applied server DLL은 15,378,432 bytes/SHA-256 `9f350c9ba11df44365d890439f588fd29734e1ded14026934fea1c02bfed4c42`이고 selected-manager focused test는 `101/101`을 통과했다.
- Marker-only 관측에서 `soloraid_trial_setdamage`의 `BattleResult`는 순서대로 `4, 4, 4, 4, 6, 6`이었다. 직접 관측된 Regroup 값은 `6`, 기존 비소모 retry 값은 `4`이며 둘 다 trial의 비소모 결과로 처리한다. Practice 의미는 변경하지 않았다.
- 운영자는 Regroup 두 번과 그 뒤 Challenge 재진입을 확인했다. 완료 전후 `raidJoinCount`, `recordCount`, `totalDamage`의 delta는 모두 `0`이다. `levelCount`의 `0 → 1`은 첫 접근에 따른 level state materialization이며 전투 소비나 기록 생성으로 판정하지 않는다.
- Completion의 첫 실패는 빈 baseline 집계에 대한 StrictMode `Measure-Object.Sum` 처리 오류였다. Server/runtime/DB 문제와 분리해 completion inner tool만 zero-safe하게 교정했고, 같은 active pointer와 marker evidence로 completion을 재개했다. 교정 뒤 DB 복원, SQLite runtime 제거, base hosts 복원, extension firewall 제거와 runtime-cold를 확인했다.
- 권위 receipt는 deployment SHA-256 `90179010e5c82fba6ff4d699fb0f913fa0f878b1100938e74645a3555752dc8a`, completion repair SHA-256 `d3e80b6e8598b127a3f4515810c39df3f959fec5273c10336e8df56c281eabba`, completion SHA-256 `5817bc8b0c3861532e118570935f396e45175bc9e25edde2f01cd7e07ad36707`, marker SHA-256 `94e0237ca0e052a64edd2b80473b2a3195346580c19c393f45e1b80c0dcec047`이다. Assessment UID는 `d7d5b339-4b66-4403-9dda-229cab797abf`다.
- 최종 read-only inspector verdict는 `observed_regroup_6_is_non_consuming_and_reentry_safe`다. Raw request payload와 raw Player.log는 보존하지 않았고 runtime app log는 completion에서 제거했다. 공식 launcher/outbound fallback, 공식 identity/credential persistence와 anti-cheat substitution은 사용하지 않았다.
- 이 기준선이 증명하는 범위는 원본 UI의 Challenge 전투 진입, Regroup 비소모, 기록/횟수/damage 비증가와 재진입이다. 전투 완주 결과, 원본 result 화면, 다음 팀 전이와 1~5팀 aggregate는 아직 증명하지 않았으며 후속 lane에서 별도로 닫는다.
- 이 상태는 전체 Phase 3B-2 완료나 original-runtime result authority 승격이 아니라 `regroup_semantics_candidate` checkpoint다. D: 봉인은 기존 full Golden을 부모로 참조하는 detached backup이며 runtime preflight나 wrapper에 결박하지 않는다.
- Detached D: checkpoint 봉인은 `e40c70a0-16a3-4a83-9d30-b16f368ce73a`로 완료됐다. 경로는 `D:\NikkeLocalLab\Backups\phase3b2-season26-challenge-regroup-v5-checkpoint-v1\e40c70a0-16a3-4a83-9d30-b16f368ce73a`이고 606개/195,874,486 bytes다. Seal receipt SHA-256은 `e69ee9020abf5c77fc61f433ae56729d36c82c10289b385ee1bdde30604e3753`, content manifest SHA-256은 `bed4e1ba8a58b42d3ae8e4b1d5409c0966efc19d53f6ec87cd6d426252e82b59`다. 봉인 파일은 모두 read-only이며 기존 D: Golden의 seal/manifest SHA-256은 그대로다.
