# GitHub Actions automation

## 현재 게시 차단 — 2026-09-12

이번 안정화 작업에서 GitHub repository metadata를 읽었을 때
`ejiie/Nikke-Local-Lab`의 visibility는 `public`이었다. 아래 `private`는 이 워크플로의
필수 보안 전제이지 현재 관측값이 아니다. 비공개 원격이라는 전제가 다시 확인되기 전에는
push·PR·merge를 진행하지 않는다. 이 작업에서 visibility나 권한을 변경하지 않았다.
로컬 `agent/**` commit과 검증·설치 인수는 별도로 진행할 수 있다.

## 목적

소스 코드와 계약만 비공개 GitHub 저장소에 보관하고, 소유자가 `agent/**` 브랜치를 push하면 검증부터 PR 생성과 squash merge까지 GitHub Actions가 처리합니다.

게임 파일, 복호물, compatibility map, 런타임 DB, 계정 데이터는 이 자동화의 입력이나 artifact가 아닙니다. 3A-R이 고정한 외부 EpinelPS checkout/build, generated protocol source, certificate, native compatibility shim과 disposable client 환경도 Actions에서 내려받거나 실행·보관하지 않습니다.

## 실행 흐름

    local agent/** branch push
              |
              v
    repository boundary check
              |
              v
    Phase 0 schema/fixture check
              |
              v
    Phase 2B Windows build/unit check
              |
              +---- PostgreSQL integration check
              |
              v
    workflow self-contract check
              |
              v
    create or reuse PR -> squash merge -> delete remote branch

검증 job이 실패하거나 취소되면 publish job은 실행되지 않습니다.

현재 workflow는 Windows에서 `scripts/verify-phase3b1.ps1`을 실행합니다. 이 gate는 3B-0→3A→완료된 Phase 2B baseline chain을 먼저 보존한 뒤, source-free selected-manager receipt와 최종 `7/10/2` route policy를 검증합니다. 이어 `scripts/verify-phase3b2.ps1 -ContractOnly`으로 Wave 0 assessment schema와 Wave 1 observation-set schema·합성 fixture를 검증하고, `scripts/verify-automation-boss-weakness-variant.ps1`로 Control Center 약점 선택 5종, 공식 아이콘 매핑, 실행별 파생 StaticData, 부모 runtime·공식 설치본 비변경, server/source manifest 및 receipt 결박을 검사합니다. 외부 EpinelPS checkout이 없는 Actions에서는 source-free manifest 형식과 연결 계약까지만 검사하며, checkout이 있는 로컬 gate에서는 manifest의 25개 source 길이·SHA-256까지 대조합니다. 어느 경우에도 파생 pack이나 원본 게임 asset을 업로드하지 않습니다. 이 단계에는 local assessment path를 전달하지 않으며 disposable environment, measured preflight 또는 actual-client live proof를 재현·주장하지 않습니다. pinned PostgreSQL service에서는 `scripts/verify-phase2b.ps1 -Integration`을 실행합니다. Phase 3A script의 checked-in verdict `blocked_insufficient_evidence`는 **승인 우선 정책의 역사적 계약**으로 계속 유지됩니다. 3B-1의 `ready_for_isolated_season26_reference_run`도 이 fixture를 성공으로 바꾸거나 original-client adapter를 활성화하지 않습니다. Phase 2B script는 완료된 Phase 2A2 gate를 먼저 호출한 뒤 permanent six-season directory, 05:00 KST boundary, Normal/Quick Battle unsupported, policy/profile과 1~5팀 Challenge contract를 추가로 검증합니다. 두 host `Program.cs`가 config policy를 source-free domain policy로 materialize하여 runtime의 initial policy로 전달하는 composition과, `MigrateAsync` integration test가 `lab_private_server` schema를 누락 없이 reset하는지를 static guard로 고정합니다.

credential-bearing raw profile, original client와 실제 game asset은 Actions 입력이 아닙니다. CI가 보는 result는 `lab_harness_observation/v1` backend 계약이며 `original_client_runtime` damage/HUD/result, wire/presentation adapter와 Phase 3·4 증거를 대신하지 않습니다. 시즌 26 classic Solo Raid compatibility spike는 disposable local 환경의 수동·로컬 gate이며 GitHub Actions green으로 실행 성공을 주장하지 않습니다. 새 경로의 정책과 exact upstream pin은 [PHASE3AR.md](../contracts/PHASE3AR.md)를 따릅니다.

## 보안 경계

- 저장소 visibility는 `private`입니다.
- workflow는 `agent/**` push만 자동 publish합니다.
- push actor가 repository owner와 같은 경우에만 실행합니다.
- 기본 `GITHUB_TOKEN`만 사용하고 PAT·repository secret을 두지 않습니다.
- validate job은 `contents: read`만 받고, checkout이 없는 publish job만 `contents: write`와 `pull-requests: write`를 받습니다.
- `pull_request_target`, `--admin`, branch-protection bypass를 사용하지 않습니다.
- 외부 action은 공식 `actions/checkout`의 검토된 commit SHA에 고정합니다.
- workflow는 게임 경로에 접근하지 않고 repository checkout만 검사합니다.
- workflow는 EpinelPS checkout, client build, hosts/CA/native shim과 local evidence vault에도 접근하지 않습니다.
- merge는 `--match-head-commit`으로 검증한 event SHA와 PR head가 다르면 실패합니다.
- 모든 agent publish run은 main 기준으로 직렬화합니다.
- 검증 job은 feature branch와 당시 `origin/main`의 merge result를 검사하고 base SHA를 기록합니다.
- Windows와 PostgreSQL 검증 job이 각각 같은 `origin/main` merge result를 검사합니다.
- .NET SDK, setup action, PostgreSQL service image를 고정된 version/SHA/digest로 사용합니다.
- publish 전에 remote main SHA가 달라졌으면 병합하지 않고 다음 push/retry를 요구합니다.

GitHub가 `GITHUB_TOKEN`으로 만든 PR 이벤트를 별도 승인 대상으로 만들 수 있으므로, 이 설계는 **push workflow 자체에서 검증을 먼저 완료**한 뒤 PR을 만들고 merge합니다. 별도 PR-triggered 검증에 의존하지 않습니다.

## 사용법

2026-09-08 소스 게시 기준: S-04/S-05에서 분리한 준비·실행 template 소스도 약점 계약
검사에 포함합니다. 등록된 S26은 다섯 약점 모두 source preparation이 ready이고,
S29 v3 초안은 기존 v2 registry pin과 달라 다섯 약점 모두 `profile_drifted`로 차단되어야
합니다. 이는 보류 상태를 검증하는 회귀 검사이며 S29 pin 변경·v3 실행 허용·실게임 성공이 아닙니다.
UI 이미지 내보내기 검사는 합성 PNG와 임시 폴더만 사용하며 실제 이미지는 CI 입력이 아닙니다.

    git switch -c agent/<short-description>
    # 변경, 로컬 검사, commit
    git push -u origin agent/<short-description>

push 이후에는 Actions run이 PR과 merge를 담당합니다. 실패 시 원격 branch와 로그를 남기므로 원인을 고친 새 commit을 같은 branch에 push합니다.

`main` 직접 push는 최초 private remote bootstrap에만 사용합니다. 이후 변경은 `agent/**` 경로를 사용합니다.

## 로컬 검사

S-06부터 Phase 2A2는 원본 데이터·외부 DLL 참조가 없는 materializer 행동 검사기의
locked restore/build/format도 수행합니다. **CI에서는 실제 materializer 출력 검사와
151 bootstrap/desktop 빌드를 실행하지 않습니다.** 배포 후보는 별도
`scripts/test-nll-materializer-behavior.ps1`에 검토된 bundle 경로·SHA-256을 명시해 로컬
검증해야 합니다. 합성 입력 21개, negative control과 별도 빌드의 범위·명령은
[S-06](../STABILIZATION_PLAN.md#s-06--높음--회귀-검사의-일부가-동작-대신-구현-문자열에-결박됨)을 따릅니다.
이 gate의 산출물·외부 DLL·receipt는 ignored artifacts에만 두고 Actions에 업로드하지 않습니다.

    pwsh -NoProfile -File scripts/verify-repository.ps1 -Mode working -AllowRemote
    pwsh -NoProfile -File scripts/verify-phase0-contract.ps1
    pwsh -NoProfile -File scripts/verify-phase3a.ps1
    pwsh -NoProfile -File scripts/verify-phase3b0.ps1
    pwsh -NoProfile -File scripts/verify-phase3b1.ps1
    pwsh -NoProfile -File scripts/verify-phase3b2.ps1 -ContractOnly
    pwsh -NoProfile -File scripts/verify-automation-boss-weakness-variant.ps1
    pwsh -NoProfile -File scripts/verify-actions-contract.ps1

live PostgreSQL까지 같은 gate로 검증할 때는 폐기 가능한 DB의 `NIKKE_LAB_TEST_DB`와 reviewed reset token을 설정한 뒤 다음을 실행합니다.

    pwsh -NoProfile -File scripts/verify-phase2b.ps1 -Integration

GitHub 저장소 설정 변경이나 workflow 수정 후에는 실제 synthetic branch로 end-to-end push→PR→merge를 다시 검증합니다.

이 검사 목록은 현재 code/config의 fail-closed 상태를 검증합니다. 완료된 3B-1 source-free receipt도 compatibility route를 CI 또는 production composition에서 자동 시작하지 않습니다. 3B-2의 blocked/not-executed 합성 fixture도 실행 증거가 아닙니다. External selected-manager patch 결과는 [PHASE3B1.md](../contracts/PHASE3B1.md), Wave 0 계약과 disposable client proof는 [PHASE3B2.md](../contracts/PHASE3B2.md)의 별도 gate를 따릅니다.
