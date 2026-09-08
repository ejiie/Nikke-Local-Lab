# Samsung → Micron 프로젝트 상태 이관

> 보관 기록: 2026-09-06 문서 정리 때 이동했습니다. 본문의 ‘현재·다음·미완료’는 작성 당시 기준입니다. 현행 안내는 [문서 색인](../README.md)과 [현재 경로](../MICRON_CURRENT_PATHS.md)를 따릅니다.

## 목적

Samsung OS에 흩어진 Nikke Local Lab의 코드, 산출물, raw data, 민감 자료와 Codex 대화 상태를
Micron 물리 OS에서 계속 사용할 수 있도록 옮긴다. D:는 복구용 백업 역할을 유지한다.

Migration UID는 `265861b9-9ff0-4e01-b409-7ce97c53aad1`이다.

## 저장 경계

| 역할 | Samsung source | staging / backup target |
|---|---|---|
| Micron 시스템 이미지 | `C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\WindowsImageBackup` | `D:\NikkeLocalLab\Backups\SystemImage\Micron-PrePhysicalLane-20260823\WindowsImageBackup` |
| 코드 작업공간 | `C:\Users\zih44\Documents\Github` (`Nikke-Local-Lab`, `EpinelPS`, `RP`) | `E:\NLL\Migrations\SamsungToMicron\v1\<uid>\Operational\Github` |
| 보호 증거 | `C:\Recovered_OldSSD\NLL_PreWipe_20260822` | `<migration>\Protected\NLL_PreWipe_20260822` |
| Codex home | `C:\Users\zih44\.codex` | `<migration>\Codex\CODEX_HOME` |
| Codex app 상태 | Samsung Local/Roaming/Documents Codex 경로 | `<migration>\Codex\*` |
| 개발자 민감 상태 | PowerShell command history, NuGet config | `<migration>\Sensitive\DeveloperProfile` |
| 보조 profile 파일 | Samsung Desktop | `<migration>\AuxiliaryProfile\Desktop` |
| raw 입력 | `nikke_full_scroll_result.json`, `getFromBlaLink.py` | `<migration>\RawInputs` |
| 임시 NLL 산출물 | Samsung `%TEMP%`의 `NLL*`/`nikke*` | `<migration>\TempNLL` |
| Samsung 주 설치본 | `C:\NIKKE` | `<migration>\ReadOnlyMainInstall\NIKKE` 읽기 전용 복제 |

보호 증거를 Micron으로 복사할 때 `WindowsImageBackup`은 제외한다. 이 194 GB 시스템 이미지를
복구 대상인 Micron 자체에 보관하면 재해복구 기능이 사라지고 Micron 용량도 부족해지므로 D:에
독립 보존한다.

## Codex 상태 경계

공식 Codex 설정에서 `CODEX_HOME`은 config, auth, logs, sessions, skills와 standalone package
metadata의 root이고, `CODEX_SQLITE_HOME`은 SQLite-backed state 위치다. Micron materialization은
두 값을 모두 `C:\Users\nlloperator\.codex`로 설정한다.

Samsung에서 Codex가 실행 중인 동안에는 session JSONL과 SQLite/WAL이 계속 변경된다. 따라서
live staging은 완성본이 아니다. ChatGPT/Codex 관련 process가 모두 종료된 뒤 final delta를
실행하고, active mapping의 모든 파일을 source/target SHA-256으로 대조해야 cold copy로 인정한다.

Samsung의 Local/Roaming web 상태는 DPAPI·앱 버전 차이 가능성이 있어 migration에 보존하되 Micron
live profile에는 자동 주입하지 않는다. `CODEX_HOME`은 복원하지만 Micron에서 공식 재로그인이 필요할
수 있다.

## 단계

1. D:로 `WindowsImageBackup`을 복사하고 기존 16-member SHA-256 manifest로 검증한다.
2. Micron migration root를 `SYSTEM`, `Administrators`, Samsung `zih44`만 접근하도록 제한한다.
3. 코드, 보호 증거, raw data, Codex 상태와 Samsung 주 설치본 복제본을 Micron에 live-stage한다.
4. 고정 자료인 보호 증거, 주 설치본 복제, LocalLow와 raw 입력을 source/target 전 파일
   SHA-256 manifest로 검증한다.
5. Samsung에서 Codex를 완전히 종료한 뒤
   `scripts/finalize-samsung-project-state-to-micron.ps1`을 관리자 PowerShell로 실행한다.
6. Micron으로 부팅한 뒤 staging 저장소의
   `scripts/materialize-samsung-project-state-on-micron.ps1`을 관리자 PowerShell로 실행한다.
7. Micron에서 저장소, Codex 대화/첨부, 로그인을 검증한다.
8. 위 검증 뒤에만 Samsung source cleanup을 별도 승인·실행한다.

## 불변 사항

- 이관 검증 전에는 Samsung source를 삭제하지 않는다.
- Samsung `C:\NIKKE`는 기존 read-only 규칙에 따라 복제만 하고 이 작업에서 삭제하지 않는다.
- Micron의 기존 `E:\NIKKE`, `E:\NLL` runtime과 D: Golden/checkpoint 백업은 덮어쓰지 않는다.
- migration staging은 기존 runtime preflight나 Golden binding에 사용하지 않는다.
- Codex 임시 `codex-index-*` 검색 cache는 대화 권위 자료가 아니므로 이관하지 않는다.

## 2026-08-28 실행 상태

- D: 시스템 이미지 사본은 16개 member, `194,298,688,392` bytes 전부 기존 manifest와
  SHA-256 일치했다. staging receipt SHA-256은
  `70767ee2c35eadcf5da2566802f0f6041afa8ab1a8b74d4d8170bbfb66d51636`이다.
- E: live staging에는 85개 mapping, `223,051` files,
  `129,735,904,775` bytes가 들어갔다. receipt SHA-256은
  `ef041d66e443a0e8bff35c3ab90b162497a006011f92f1e715899558d7244f4c`다.
  stable mapping 실패는 0이다. 실행 중 잠긴 `AppData\Roaming\Codex` 한 mapping만
  Robocopy exit 11로 남았으며 cold final delta 대상이다.
- 고정 자료 source/target 전수 검증은 `165,716` files,
  `105,280,684,732` bytes 모두 통과했다. stable receipt SHA-256은
  `a63a52af4e010492029073032d1fc6acea6631e85ede8f7486c257283b383c4b`,
  manifest SHA-256은
  `936e76f4cd69fbb1ee57c6734c691bdc5220e60b995ab5079bdd6f5c848cde33`이다.
- Samsung source 삭제는 0이다. 다음 필수 단계는 Codex 완전 종료 뒤 final delta를
  관리자 PowerShell 7로 실행하는 것이다. Samsung 바탕화면의
  `NLL-Finalize-Samsung-To-Micron.cmd`가 UAC launcher이며 SHA-256은
  `9a9544413353694452c86a6565c12ac08a68b15405f944e7dbcc224c55e32d09`다.
- Micron 오프라인 바탕화면에도 `NLL-Materialize-On-Micron.cmd`를 배치했다.
  SHA-256은 `19498bc4371d618be97148712790448de6a76fea7a4422476aca06bfc88c6d85`이며,
  같은 바탕화면의 `NLL-Samsung-To-Micron-Materializer` 폴더에서 UAC materializer를
  실행한다.
- 이관용 PowerShell 8개는 parse error 0이고 전체 `git diff --check`가 통과했다.
  Phase 3A/3B-0/3B-1/3B-2 contract-only gate도 통과했다. 전체 Phase 2/repository
  gate는 이관 전부터 존재한 dirty 상태인 Automation CLI whitespace, `origin` remote,
  automation fixture allowlist 미반영과 과거 `.trn` telemetry 때문에 실패했다. 이관
  과정에서는 해당 사용자 변경을 수정하거나 삭제하지 않았다.

## 2026-08-29 완료 및 현재 권위

- Samsung cold final delta와 Micron live materialization은 완료됐다. 위의 "다음 필수 단계"는
  당시 staging receipt의 역사 기록이며 더 이상 실행 지시가 아니다.
- 활성 repository는 `C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab`, Codex home은
  `C:\Users\nlloperator\.codex`, runtime/evidence/tools는 `C:\NLL`이다.
- `C:\NIKKE`는 Micron 공식 launcher가 소유하는 mutable official-current 설치본이다.
  `C:\NLL\Clients\NIKKE-150.6.9-Physical`은 별도의 Phase3B2 파생 frozen lane이며 둘은 같은
  tree가 아니다.
- D:는 Golden/checkpoint/system-image 복구 경계로 유지한다. Micron에서 Samsung의
  `E:\NIKKE` 또는 과거 `E:\NLL\Migrations` staging을 current runtime input으로 사용하지 않는다.
- Samsung의 `C:\Recovered_OldSSD\NLL_PreWipe_20260822`는 이관 검증 뒤 운영자가 제거했다.
  이는 Samsung의 다른 game/application 또는 `E:\NIKKE`를 제거하라는 뜻이 아니다.
- 현재 경로와 공식 업데이트 절차의 단일 권위는
  [MICRON_CURRENT_PATHS.md](../MICRON_CURRENT_PATHS.md)다.
