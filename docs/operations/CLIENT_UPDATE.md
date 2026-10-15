# 공식 client 업데이트 적용 순서

151.8.5 → 152.8.11(2026-09-17)과 152.8.11 → 152.8.13(2026-10-15~16) 적용에서 실제로 거친 순서입니다.
152.8.13부터는 단계별 도구를 `scripts/client-update/`에 두었습니다. 다음 버전에서도 같은 결과가 나온다는 보장은 없으며,
각 단계의 판정은 그 버전의 증거로 다시 합니다. 원문: [152 기록](../archive/client/CLIENT_152_COMPATIBILITY_ASSESSMENT.md).

## 경계

- 공식 설치본 `E:\NIKKE`(2026-10-15 운영자 지정, 이전 `C:\NIKKE`)는 공식 launcher만 업데이트합니다. NLL 도구는 읽기 입력과 봉인 복제 원본으로만 쓰고 실행 대상으로 삼지 않습니다.
- 새 버전은 새 후보입니다. 기존 lane이나 receipt를 새 버전으로 조용히 바꾸지 않습니다.
- 공식 로그인·토큰·통신 가로채기·메모리 주입을 쓰지 않습니다. CDN 요청 범위는 [보안 경계](../SECURITY_BOUNDARY.md)를 따릅니다.
- 게임 실행·화면 판정과 관리자 권한 설치(방화벽 변경)는 운영자가 합니다. 자동 검사·설치 완료와 실게임 확인을 따로 기록합니다.

## plan 파일

업데이트마다 `config/client-update.plan.example.json`을 `<stagingRoot>\client-update.plan.json`으로 복사해 채웁니다.
모든 도구는 이 파일만 읽고 경로·버전을 추측하지 않습니다(`Read-NllClientUpdatePlan`이 경로 권위를 검사).

| 항목 | 뜻 (152.8.13 값) |
|---|---|
| `build`, `previousBuild` | 새·이전 build (`152.8.13`, `152.8.11`). client 경로는 `C:\NLL\Clients\NIKKE-<build>-ResourceProbe`로 계산 |
| `stagingRoot` | 증거·중간물 (`C:\NLL\Staging\ClientUpdates\152.8.13-20261015`) |
| `runtimeRoot` | 새 bundle. bundle 판독 규칙상 `PhaseD<major>-v<n>` (`C:\NLL\Runtime\PhaseD152-v2`) |
| `pipelineInputsRoot` | native 입력 계획·catalog 도구 (`C:\NLL\RuntimeInputs\BossPipeline\152.8.13-v1`) |
| `workName` | 메인 checkout의 Git 제외 `artifacts/<workName>`: 보스 전달·설정·설치 후보 (`apply-152.8.13-20261015`) |
| `previousSourceManifestPath` | 이전 복제의 `C:\NLL\Staging\ResourceProbeClones\<uid>\source.private.json` |
| `upstreamCommit`, `upstreamExcluded` | 적용한 upstream 버전 commit, 적용하지 않은 commit |
| `gameConfigPath`/`gameConfigSha256` | 그 commit의 `gameconfig.json`을 staging에 고정한 사본과 hash |
| `staticDataPackPath`, `serverPublishRoot`, `serverSourceRoot`, `localeStagingRoot` | 2·4·6단계 산출물 위치 |
| `installationId` | native FX 기준 등록 ID (`nll-152.8.13-20261016`) |

## 순서

명령은 pwsh 7에서 실행합니다. python·pwsh는 활성 파이프라인 설정의 `pythonPath`·`powerShellPath`(Codex runtime)를 씁니다.

1. **읽기 비교와 봉인 복제** (cold): `compare-nll-client-update.ps1 -PlanPath <plan>`이 공식 설치본 manifest를 이전 봉인본과
   대조하고 복제에 필요한 `planSha256`·실행 파일·어셈블리 hash를 출력합니다. 이어서
   `scripts/new-nll-resource-probe-clone.ps1 -Build <build> -SourceRoot E:\NIKKE -Expected... -ExecuteApprovedClone`으로 복제합니다.
   결과는 `sealed_offline_clone`, `sourceUnchanged=true`여야 합니다(152.8.13: 1,132개 파일, 약 15분).
2. **upstream 설정과 StaticData**: 공개 upstream `EpinelPS/EpinelPS`의 `EpinelPS/gameconfig.json` 이력에서 대상 버전 commit을
   찾아 그 파일을 staging에 고정합니다. `python nll-client-update-staticdata.py fetch --plan <plan>`이 그 설정이 가리키는
   pack을 1회 받아 서명·CRC·필수 표를 검증합니다. 출력의 `decodedSha256`가 5단계 허용 값입니다. 공식 client Temp의
   `StaticData.pack`은 NLL 실행이 5약점 변형 pack으로 덮어쓰므로 쓰지 않습니다(`decode`가 `outer_cbc_padding_invalid`로 거부).
3. **서버 후보**: `python prepare-nll-server-candidate.py --source .external\EpinelPS-<이전>-candidate --upstream <upstream clone>
   --target .external\EpinelPS-<build>-candidate --version-commit <commit> [--trial-commit <commit>] --deployed-manifest
   <선택 bundle>\server-source.manifest.tsv --evidence <stagingRoot>`. 버전 파일만 적용하고 기능 commit은 시험 branch로만
   보고합니다(152.8.13에서 `370b43e`는 NLL 파일 7개와 충돌해 제외). `dotnet build`·서버 테스트 뒤
   `dotnet publish EpinelPS\EpinelPS.csproj -c Release --self-contained false -p:PublishSingleFile=false -o <serverPublishRoot>`.
   `resourcehosts2`는 upstream처럼 BaseUrl/Version만 돌려줍니다.
4. **build 허용 PR**: 실행 파일과 복호 StaticData를 한 쌍으로 허용합니다. 위치는 materializer `RuntimeVersionBinding`·
   `RuntimeMigrationChecks`·`CommonDeliveryFiles`, `Nll.PhaseDRuntimeBundle.ps1`, `Nll.PhaseDRunnerContract.ps1`과 runner 테스트 4개,
   Admin API `PhaseDPreparation`, `LocalBootstrap`입니다(#58). 병합 뒤 메인 checkout을 fast-forward합니다. 152.8.13처럼
   공통 파이프라인 규칙이 바뀌어야 하면 같은 방식으로 먼저 병합합니다(#59).
5. **입력 준비**: `stage-nll-client-update-inputs.ps1 -PlanPath <plan>`이 catalog 도구를 새 서버 publish·후보 소스로 빌드하고,
   복제본 saus catalog에서 서버 locale 4개를 원본 바이트로 꺼내고, native FX 입력 계획을 씁니다.
6. **bundle 봉인** (cold, 메인 checkout): `stage-nll-client-update-bundle.ps1 -PlanPath <plan>`. materializer·bootstrap을
   빌드하고(각 도구 폴더의 `global.json`이 SDK 10을 고름), overlay 원본이 이전과 같은지 확인하고, 방화벽 대상 목록과
   core store를 고정합니다. 허용 PR이 없으면 마지막 bundle 판독에서 실패합니다. 아직 선택하지 않습니다.
7. **등록 보스 재조립**: `rebuild-nll-client-update-bosses.ps1 -PlanPath <plan>`. 각 시즌 `rebuild.receipt.json`의
   `equivalentCombatSource`는 행동 그래프·참조·QTE 등이 같은지입니다. 그래프를 담은 bundle만 바뀐 경우는 같은 입력으로 보며
   기록이 이어지고, 다르면 기록은 보존되지만 새 구성에 자동 승계되지 않습니다(152에서 S10·S26·S34, 152.8.13에서 S41·S42).
   출하 catalog(`aa/catalog.db`)와 패치 core catalog가 다른 bundle을 가리키면 출하본에만 있는 원격 bundle을 설치본이
   공급할 수 없을 때만 패치 catalog를 채택합니다(`shippedCatalogCode`). 다른 불일치는
   `inspect-nll-catalog-bundle-binding.py`로 원인을 봅니다.
8. **설치 준비** (cold, 비관리자): `prepare-nll-client-update-install.ps1 -PlanPath <plan> -ExpectedHead <HEAD>`.
   - 설정: 모든 버전 경로를 새 bundle·입력으로 옮기고, 시즌 intake는 bundle의 검증된 pack, locale·이미지·`sd.bin`은
     `E:\NIKKE`를 읽게 합니다. 모든 고정값이 실제 파일과 같아야 합니다(`check-nll-config-pins.py`).
   - 시즌 목록: 새 시즌이 있으면 기존 동기화 스크립트로, 없으면 새 pack에서 다시 도출한 행이 같을 때만 같은 목록을 새
     pack에 다시 묶습니다(작업 실행기가 `sourceStaticDataSha256`를 검사).
   - 레지스트리 후보, DB 등록 계획, 새 설정을 활성화하는 앱 배포 계획, hash 고정 관리자 실행 파일
     `<workRoot>\run-install-uac.ps1`을 만듭니다. 이후 설치 전까지 메인 checkout을 pull하지 않습니다.
9. **설치** (운영자, 관리 도구·게임 종료 상태):
   `Start-Process -Verb RunAs -FilePath <Codex pwsh> -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','<workRoot>\run-install-uac.ps1'`.
   창은 비어 있고 진행은 `<workRoot>\install-progress.json`, 결과는 `installation.receipt.json` 또는 `installation.failure.json`입니다.
   overlay → 방화벽(복제본 규칙은 새 client, 공식 규칙은 `E:\NIKKE`) → native FX 기준 → DB 등록 → 레지스트리·선택 → 앱 배포 →
   전 시즌×5약점 `ready` 순서이며 실패하면 되돌립니다(152.8.13: 약 3분 30초, 55건 ready).
10. **리소스 안내 공급**: 첫 실행은 `latest-<n>.txt` 404로 4/7(`DownloadPatch - Initialize failed`)에서 멈춥니다. 게임을 닫고
    `supply-nll-client-update-guidance.ps1 -PlanPath <plan>`(미리보기) → `-ExecuteOnce`. client가 요청한 정확한 파일을 CDN에서
    1회 받아 publication 7개가 복제본 `.patch_state.json`과 같을 때만 쓰고, 다르면 복제본에서 만든 로컬 안내를 씁니다
    (2026-10-16 운영자 결정). 안내와 catalog 14개를 bundle 캐시에 두고 bundle·선택 포인터를 다시 봉인합니다. 관리 도구를
    다시 연 뒤 실행합니다.
11. **음성**: 음성 언어·다운로드 범위는 공식 client와 같은 `HKCU\Software\com.proximabeta\NIKKE`의 `voiceLocale_*`·
    `voiceDownloadType_*`입니다. 복제본에 그 언어 그룹(예 `Ko_Required`)이 없으면 매 실행 다운로드 안내가 뜨고, NLL은 외부
    다운로드를 막아 두어 실패한 뒤 진행합니다. NLL 실행은 `en/ko/ja` × `Minimal/Full`만 받아들이므로(`Get-NllVoiceResourceSelection`)
    다른 값은 측정 후 코드에 추가해야 합니다. 음성이 필요하면 공식 client에서 받은 뒤 다시 복제합니다.
12. **이전 client 보관**: 운영자 확인 뒤 cold 상태에서 `D:\NikkeLocalLab\Backups\client-<build>-archive-<date>-01`로 복사하고 모든
    파일 hash를 대조한 뒤에만 C: 사본을 제거합니다. 이전 runtime bundle·cache·journal은 남깁니다.
13. **기록**: [경로 권위](../MICRON_CURRENT_PATHS.md), [HANDOFF](../HANDOFF.md), [DECISIONS](../DECISIONS.md)를 갱신하고 운영자 확인을
    따로 적습니다.

## 152.8.13에서 확인한 사실과 함정

- 안내 번호는 client가 정합니다. 152.8.11·152.8.13 모두 `latest-655.txt`를 요청했지만, 2026-10-15 CDN의 655는 설치본보다 오래된
  계열이었고(core 566676 대 569366), 공식 `resourcehosts2`는 EdgeOne 567로 막혀 있으며 승인받은 656~660 탐색은 모두 404였습니다.
  `global-metadata.dat`는 0바이트(GameAssembly 내장)라 정적 분석으로도 번호를 알 수 없습니다.
- 로컬 안내를 공급하자 client는 기존 리소스를 그대로 쓰고 음성 그룹만 추가 다운로드를 시도했습니다(약 2.18GB, 실패 후 진행).
- 도구 출력은 `C:\NLL` 아래에 둘 수 없습니다(행동·FX 획득 도구가 거부). 보스 작업은 메인 checkout `artifacts/<workName>`에 둡니다.
- 메인 checkout 루트 `global.json`은 SDK 8.0.407이고 materializer·bootstrap·catalog 도구는 각 폴더의 SDK 10을 씁니다.
  catalog 도구는 `.external/EpinelPS`가 없으면 `-p:EpinelSourceRoot`·`-p:EpinelRuntimeRoot`가 필요합니다.
- Codex runtime의 python이 바뀌면 활성 설정의 고정값이 어긋나 UI 보스 작업이 멈춥니다. 설치 준비가 다시 고정합니다.
- `Get-NllAppPin`은 경로 없이 hash·길이만 돌려줍니다. Win32 `-Filter '*.exe'`는 `*.exe_*` 파일도 잡습니다.
- 설치는 방화벽 규칙 21개(복제본 6, 공식 15)를 바꿨습니다. 다음 업데이트부터 공식 규칙은 이미 `E:\NIKKE`라 복제본 6개만 바뀝니다.
