# GitHub Actions automation

## 비공개 전환과 게시 차단 해제 — 2026-09-12

안정화 직후 원격이 `public`으로 관측되어 push를 보류했으나, 운영자가
"private으로 돌리고 push"를 명시 승인했다. 지정 저장소 `ejiie/Nikke-Local-Lab`
(repository ID `1338065668`)의 기존 소유자 인증으로 visibility만 변경했고 GitHub API에서
`private=true`, `visibility=private`를 재확인했다. 다른 권한·설정은 변경하지 않았다.
비공개 게시 전제가 회복됐으므로 아래 경계 검사 후 `agent/**` push 경로를 사용한다.
실제 Actions 결과는 해당 push SHA의 run/PR에서 확인하며, 이 기록만으로 merge 성공을 주장하지 않는다.

## 2026-09-12 Linux S-08 후속 수정

실패 run `34649202768`은 Windows 검증에 통과했으나 Linux의 DB-free cold-child
검사(`s08_assertion_line_63`)에서 중단되어 PostgreSQL gate와 게시가 완료되지 않았다.
.NET 8 Linux는 `Process.StartTime`의 부팅 기준 시각을 프로세스별로 계산·cache한다.
부모/자식의 표시용 UTC 시각을 exact identity로 비교하지 않고, Linux에서는 같은
boot ID와 `/proc/<owned-child>/stat`의 kernel start tick을 PID와 함께 대조한다.
Windows는 기존 kernel 시작 시각을 사용한다. 시작 시각의 허용 오차를 넓히거나
실패 사례·timeout·정리 검사를 생략하지 않는다.

근거 구현은 [.NET 8.0.14 Process.Linux](https://github.com/dotnet/runtime/blob/v8.0.14/src/libraries/System.Diagnostics.Process/src/System/Diagnostics/Process.Linux.cs)와
[native boot-clock 변환](https://github.com/dotnet/runtime/blob/v8.0.14/src/native/libs/System.Native/pal_time.c)이다.
표시용 UTC는 관측 값으로 보존한다. 새 parser는 합성 괄호/공백·잘못된 PID/boot/tick을
검사하며, subprocess 실패 로그에는 controlled mode/status/stage만 남긴다.
수정 `46b2d84`의 [Actions run 34666698710](https://github.com/ejiie/Nikke-Local-Lab/actions/runs/34666698710)은
Windows 전체 검증, Linux S-08 12개 subprocess 사례, PostgreSQL **114/114**와
자동 게시를 모두 통과했다. [PR #13](https://github.com/ejiie/Nikke-Local-Lab/pull/13)은
2026-09-12 11:13 KST에 `7e59e06`으로 squash merge됐다. 앞서 완료한 영속화 소스도
함께 반영됐다. remote는 private이며 권한·브랜치 보호를 완화하지 않았다.

## 목적과 실행 경계

2026-09-27 게시에서 PR #31의 squash 결과와 동일한 파일 트리를 가진 원래 커밋의
후속 브랜치를 그대로 push해 `main` 결합 시 25개 파일이 충돌했다. 원격 `main`의
트리가 로컬 조상 `f7de7f6`과 정확히 같음을 확인하고, 파일 변경 없이 두 이력을
연결했다. 이후 CI는 병합 준비를 통과했다. 앞으로 push 전 현재 브랜치뿐 아니라
최신 `origin/main`과 결합한 결과도 확인한다.

후속 Windows CI는 합성 격리 검사에서 실제 ACE 파일을 읽으려다 실패했다.
PowerShell 5.1의 Utility 모듈 자동 로드가 `Get-FileHash` mock을 덮어쓴 것이
원인이다. 테스트에서 모듈을 먼저 로드하고, 실제 해시는 생성한 임시 fixture에만
허용한다. 임시 파일 해시 후에도 서비스 해시 mock이 유지되는지와 기록된 합성
해시·호출 횟수를 검사한다. 제품의 서비스/파일 처리 코드는 변경하지 않는다.

소스 코드와 계약만 비공개 GitHub 저장소에 보관하고, 소유자가 `agent/**` 브랜치를 push하면 검증부터 PR 생성과 squash merge까지 GitHub Actions가 처리합니다.

게임 파일, 복호물, compatibility map, 런타임 DB, 계정 데이터는 이 자동화의 입력이나 artifact가 아닙니다. 3A-R이 고정한 외부 EpinelPS checkout/build, generated protocol source, certificate, native compatibility shim과 disposable client 환경도 Actions에서 내려받거나 실행·보관하지 않습니다.

## 실행 흐름

    local agent/** branch push (owner only)
              |
              +-- validate (windows-latest, 15분 제한)
              |     tested merge with origin/main
              |     -> verify-all.ps1 -SkipIntegration (현행 검사 각 1회)
              |
              +-- postgres (ubuntu-latest + PostgreSQL 17.6 service, 15분 제한)
              |     tested merge with origin/main
              |     -> verify-all.ps1 (현행 검사 + live PostgreSQL 통합)
              |
              v
    publish (ubuntu-latest): create or reuse PR -> squash merge (--match-head-commit) -> delete remote branch

두 검증 job 중 하나라도 실패하거나 취소되면 publish job은 실행되지 않습니다. 정확한 단계는
`.github/workflows/agent-branch-automerge.yml`이 권위입니다. 2026-09-27 run `36324475337`에서 validate job은 약 12분이
걸렸으므로 검사를 추가할 때 15분 제한과의 여유를 확인합니다.

`scripts/verify-all.ps1`은 repository/Phase 0/Actions 계약, SDK pin과 solution locked restore/build/format,
10개 단위 테스트 project, editor/도구 검사, 별도 7개 project build/format, PowerShell/Python 합성 행동 검사와
보스 약점 계약을 각각 한 번 실행합니다. Windows에서는 PowerShell 5.1의 Job·준비·실행·원복 검사와 FX 퇴역 검사도
실행합니다. Linux에서는 Windows 전용 검사를 명시적으로 건너뛰고 live PostgreSQL 통합을 추가합니다.
두 host의 configured policy composition과 migration 테스트의 private-server schema reset guard도 유지합니다.

2026-09-30 D2에 따라 Phase 3A blocked verdict, 3B-0 closure, 3B-1 selected-manager receipt, 3B-2 Wave 0/VM
판정 모양 검사는 동결했습니다. 역사 문서 `docs/contracts/PHASE*.md`는 보존하고 당시 스크립트·schema·fixture는
tag `scripts-history-20260930`에서 조회합니다. 이력 문서의 옛 검사 명령은 현재 실행 지시가 아닙니다.
현행 managed FX service/driver, 사용자 검증 controller와 Job/FX 퇴역 검사는 새 진입점으로 옮겼습니다.

보스 약점 검사는 기존과 같이 외부 checkout이 없으면 source-free manifest 형식과 연결 계약을 검사하고,
있으면 25개 source 길이·SHA-256도 대조합니다. 원본 게임 asset과 파생 pack은 업로드하지 않습니다.
pre-commit은 staged repository, Phase 0, 보스 약점, Actions 계약과 editor 구문/행동 검사만 실행합니다.
전체 검사는 커밋 전에 별도로 실행하며 hook 성공으로 전체·PG 통합 검증을 대체하지 않습니다.

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

2026-09-12 `8427082` 실행은 두 OS 모두 테스트 전에 임시 non-fast-forward merge의 Git
identity 결손으로 실패했다. `--no-commit`에도 identity가 필요하므로 두 merge 명령에만
`git -c user.name=... -c user.email=...`의 bot identity를 지정한다. global/local 설정을
남기거나 commit/보호 규칙을 우회하지 않는다. source-only Python QTE/격리 FX/Git merge
합성 검사를 양쪽 validation job에 추가하며 실제 FX/UnityPy/151 원본은 CI에서 읽지 않는다.

`main` 직접 push는 최초 private remote bootstrap에만 사용합니다. 이후 변경은 `agent/**` 경로를 사용합니다.

## 로컬 검사

S-06에서 도입하여 현행 진입점이 유지하는 검사는 원본 데이터·외부 DLL 참조가 없는 materializer 행동 검사기의
locked restore/build/format도 수행합니다. **CI에서는 실제 materializer 출력 검사와
151 bootstrap/desktop 빌드를 실행하지 않습니다.** 배포 후보는 별도
`scripts/test-nll-materializer-behavior.ps1`에 검토된 bundle 경로·SHA-256을 명시해 로컬
검증해야 합니다. 합성 입력 21개, negative control과 별도 빌드의 범위·명령은
[S-06](../archive/stabilization/STABILIZATION_PLAN.md#s-06--높음--회귀-검사의-일부가-동작-대신-구현-문자열에-결박됨)을 따릅니다.
이 gate의 산출물·외부 DLL·receipt는 ignored artifacts에만 두고 Actions에 업로드하지 않습니다.

작업 전후 로컬 현행 검사(각 1회):

    pwsh -NoProfile -File scripts/verify-all.ps1 -SkipIntegration

`-SkipIntegration`은 유일한 빠른 로컬 스위치이며 PostgreSQL 통합만 생략합니다. Windows 전용 검사까지
통과하려면 Windows에서 실행해야 합니다. repository는 로컬에서 `-Mode working`, Actions에서는
`-Mode tracked`로 검사하며 모두 `-AllowRemote`를 지정합니다.

필요한 도구: PowerShell 7(`pwsh`), Node.js, Python, `global.json`의 .NET SDK 8.0.407,
Windows 전용 검사에는 Windows PowerShell 5.1. NuGet locked restore와 취약성 조회에 네트워크가 필요합니다.

live PostgreSQL 통합까지 검증할 때는 **폐기 가능한 테스트 DB**의 `NIKKE_LAB_TEST_DB`와
`NIKKE_LAB_TEST_RESET_TOKEN=allow-phase1a-disposable-schema-reset`을 설정하고 실행합니다.
운영 DB를 사용하지 않습니다. 둘 중 하나라도 없거나 token이 다르면 검사 시작 전에 실패합니다.

    pwsh -NoProfile -File scripts/verify-all.ps1

기존 Phase 2B 완료 이력의 단위·live PostgreSQL 통합 기준은 그대로 유지합니다.
`-SkipIntegration` 결과만으로 통합 완료를 주장하지 않습니다. workflow 변경의 실제 Windows/Linux job 시간과
push→PR→merge 결과는 디렉터가 해당 SHA의 Actions에서 확인합니다.

이 검사는 현재 code/config와 합성 입력의 동작을 검증하며 original-client UI/runtime actual-play를 대신하지 않습니다.
