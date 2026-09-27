# AGENTS.md

문서 위치와 용도는 [문서 색인](docs/README.md)에서 찾습니다. 아래 필수 읽기 순서와 불변 규칙은 유지하며, `docs/archive/`의 과거 실행 지시는 현재 작업 지시와 구분합니다.

이 저장소에서 작업하기 전에 다음 문서를 순서대로 읽습니다.

1. `docs/SCOPE.md`
2. `docs/MICRON_CURRENT_PATHS.md`
3. `docs/DATA_POLICY.md`
4. `docs/SECURITY_BOUNDARY.md`
5. `docs/contracts/FEASIBILITY_GATES.md`
6. `docs/contracts/DOMAIN.md`
7. `docs/contracts/RAID_DOMAIN.md`
8. `docs/contracts/PROFILE_EXECUTION_DOMAIN.md`
9. `docs/contracts/PRIVATE_SERVER_UI.md`
10. `docs/contracts/IDENTITY.md`
11. `docs/DECISIONS.md`
12. `docs/archive/IMPLEMENTATION_PLAN.md`
13. `docs/NEXT_STEPS.md`
14. `docs/operations/GITHUB_AUTOMATION.md`
15. `docs/ARCHITECTURE.md`
16. `docs/contracts/PHASE1D.md`
17. `docs/contracts/PHASE2A1.md`
18. `docs/contracts/PHASE2A2.md`
19. `docs/contracts/PHASE2B.md`
20. `docs/contracts/PHASE3.md`
21. `docs/contracts/PHASE3A.md`
22. `docs/contracts/PHASE3AR.md`
23. `docs/contracts/PHASE3B0.md`
24. `docs/contracts/PHASE3B1.md`
25. `docs/contracts/PHASE3B2.md`
26. `docs/HANDOFF.md`

## 불변 규칙

- 보스 추가·실행 정비는 [공통 실행 계획](docs/operations/COMMON_BOSS_EXECUTION_PLAN.md)을 따른다. UI 요청부터 패턴·속성·필요한 QTE/FX 조립과 실행 구성 생성까지 공통 파이프라인으로 처리하고, 시즌/프로필 버전별 부팅·음성·종료 예외를 추가하지 않는다. 버전 해석 뒤 실제 전투 입력과 필요한 변환으로 동작을 선택한다.
- 기존 구현을 사용자 요구로 간주하지 않는다. 변경의 요구 근거·관측 사실·가정을 구분하고 정상 공통 경로를 먼저 대조한다. 새 보스 전용 수작업 없이 같은 경로가 적용되는 증거를 남기며, 구현·자동 검사·설치·사용자 실게임 완료를 구분한다.
- 최종 목표는 운영자가 승인한 비배포·로컬 전용 compatibility 환경의 원본 NIKKE UI와 실제 전투 runtime으로 검증하는 것입니다.
- 제품은 원본 client에 일부 기능만 공급하는 제한된 local private server이며 별도 게임 UI나 simulator runtime이 아닙니다.
- lab-owned harness는 계약·데이터 검사용 보조 도구이며 최종 인수 조건을 대체하지 않습니다.
- 공식 로그인·계정·session·token, live 공식 traffic 가로채기/replay, 게임 프로세스 주입·후킹·memory patch를 사용하지 않습니다.
- 2026-09-06 운영자는 위 memory patch 문구로 기존 Epinel 제공 DLL 사용을 막는 것을 명시적으로 철회했습니다. SHA-256 `54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662`인 DLL 자체의 내장 동작을 포함해 격리된 151 복제본 실험에 사용할 수 있습니다. 별도 주입·패치 구현, 공식 설치본 변경 또는 외부 통신 허가는 아닙니다. 상세는 `docs/SECURITY_BOUNDARY.md`의 동일 날짜 승인을 따릅니다.
- Micron의 `C:\NIKKE`는 공식 launcher가 소유하는 mutable official-current 설치 경로입니다. 공식 설치·업데이트·fresh capture에만 사용하고 Local Lab/EpinelPS 도구가 수정하거나 private-server 실행 대상으로 삼지 않습니다. Local compatibility의 불변 기준은 별도 version/hash로 봉인한 `C:\NLL\Clients\NIKKE-<build>-*` lane입니다. 현재 경로 권위는 `docs/MICRON_CURRENT_PATHS.md`를 따르며 Micron에서 `E:\NIKKE`를 참조하지 않습니다.
- system hosts/root CA 변경은 disposable VM/OS에서만, client-local certificate bundle과 pinned native compatibility shim 변경은 사전 hash·backup·rollback manifest가 있을 때만 허용합니다. 이 예외를 주 설치본이나 공식 서비스 접속에 사용하지 않습니다.
- Phase 3A의 `blocked_insufficient_evidence`는 과거의 rights-holder-approval prerequisite 판정으로 보존합니다. 운영자가 승인한 modified-local 연구 lane의 현재 권위와 진입 조건은 `docs/contracts/PHASE3AR.md`입니다.
- original/classic Solo Raid Challenge만 목표로 합니다. 결과에 별도 공식 buff가 적용되는 Solo Raid Museum은 구현·검증·fallback 대상이 아닙니다.
- 첫 live compatibility test는 시즌 26으로 하며 exact manager→preset→Challenge wave→monster/stat→client asset closure가 확인될 때만 실행합니다.
- 원본·복호물·번들·이미지·음성·DB·실계정 데이터·patched binary·인증서 private key는 커밋하지 않습니다.
- private GitHub remote에는 source, 계약, migration, 직접 만든 합성 fixture만 push합니다.
- 원본 게임 ID를 도메인 PK/FK, API, 로그에 노출하지 않습니다.
- 미지값과 결손 참조는 임의 추정하지 않고 `unresolved` 또는 `not_applicable`로 보존합니다.
- 캐릭터 빌드 수정은 기존 row 덮어쓰기가 아니라 새 revision 생성으로 처리합니다.
- 기본값은 생성 시점 데이터 snapshot에서 실제 값으로 해소하여 저장합니다. 데이터 업데이트가 과거 revision을 자동 변경하면 안 됩니다.
- Solo Raid는 Challenge만 지원하고 `challenge-boss-support/v1` admission policy를 통과한 보스만 publish합니다.
- Normal I~VII는 기본 clear(`lastClearLevel=7`)이고 Challenge는 기본 개방합니다. Normal과 Union Raid 전투 세션을 만들지 않습니다.
- 지원 시즌은 만료되지 않으며 Quick Battle을 구현하지 않습니다. daily state는 `Asia/Seoul`의 05:00에 초기화합니다.
- Challenge unlock UI state와 run admission을 구분합니다. checked-in 기본 `challenge-operational-policy/unresolved/v1`에서도 Challenge는 open이지만 새 run은 fail closed하며, configured policy는 여섯 운영 축을 모두 명시한 새 non-reserved versioned ID를 사용해야 합니다. 초기 빈 DB policy는 현재 raid day에 효력을 가질 수 있고 이후 admin 전환은 다음 raid day로만 예약합니다.
- Phase 2B는 `lab_harness_observation/v1`만 수락하며 최종 damage/HUD/result 권위는 `original_client_runtime`에 남습니다. harness receipt를 original-runtime 증거로 승격하지 않습니다.
- private-server access token 서명 key는 process-local입니다. 같은 process의 같은 Open operation replay만 exact token byte를 재사용하고, restart 뒤에는 영속 session/context/time을 복원해도 token은 재서명될 수 있습니다.
- 변경은 `agent/**` branch에 commit하고 Actions가 검증·PR·squash merge하도록 합니다.
- 작업 전후 repository, Phase 0, 완료된 Phase 2A1·Phase 2A2·Phase 2B, Phase 3A 역사 contract, Phase 3B-0 source-free closure, Phase 3B-1 selected-manager receipt, Phase 3B-2 contract scaffold와 Actions contract 검사를 모두 실행합니다. Phase 2B 완료 이력은 `scripts/verify-phase2b.ps1`의 단위 및 live PostgreSQL integration gate가 모두 통과한 revision을 기준으로 합니다. `scripts/verify-phase3a.ps1`은 과거 source-free evidence shape와 blocked verdict를, `scripts/verify-phase3b0.ps1`은 별도 시즌 26 closure assessment를, `scripts/verify-phase3b1.ps1`은 외부 통합 patch와 focused test의 source-free receipt를 검증합니다. `scripts/verify-phase3b2.ps1`의 현행 Wave 0은 blocked preflight와 not-executed 합성 fixture만 검증하며 measured ready receipt나 actual-play 성공을 주장하지 않습니다. 어느 script도 original-client adapter/UI/runtime actual-play를 대신 판정하지 않습니다.
