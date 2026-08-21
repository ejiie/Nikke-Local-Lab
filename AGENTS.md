# AGENTS.md

이 저장소에서 작업하기 전에 다음 문서를 순서대로 읽습니다.

1. `docs/SCOPE.md`
2. `docs/DATA_POLICY.md`
3. `docs/SECURITY_BOUNDARY.md`
4. `docs/FEASIBILITY_GATES.md`
5. `docs/DOMAIN.md`
6. `docs/RAID_DOMAIN.md`
7. `docs/PROFILE_EXECUTION_DOMAIN.md`
8. `docs/PRIVATE_SERVER_UI.md`
9. `docs/IDENTITY.md`
10. `docs/DECISIONS.md`
11. `docs/IMPLEMENTATION_PLAN.md`
12. `docs/NEXT_STEPS.md`
13. `docs/GITHUB_AUTOMATION.md`
14. `docs/ARCHITECTURE.md`
15. `docs/PHASE1D.md`
16. `docs/PHASE2A1.md`
17. `docs/PHASE2A2.md`
18. `docs/PHASE2B.md`
19. `docs/PHASE3.md`
20. `docs/PHASE3A.md`
21. `docs/PHASE3AR.md`
22. `docs/PHASE3B0.md`
23. `docs/PHASE3B1.md`
24. `docs/HANDOFF.md`

## 불변 규칙

- 최종 목표는 운영자가 승인한 비배포·로컬 전용 compatibility 환경의 원본 NIKKE UI와 실제 전투 runtime으로 검증하는 것입니다.
- 제품은 원본 client에 일부 기능만 공급하는 제한된 local private server이며 별도 게임 UI나 simulator runtime이 아닙니다.
- lab-owned harness는 계약·데이터 검사용 보조 도구이며 최종 인수 조건을 대체하지 않습니다.
- 공식 로그인·계정·session·token, live 공식 traffic 가로채기/replay, 게임 프로세스 주입·후킹·memory patch를 사용하지 않습니다.
- `C:\NIKKE` 주 설치본은 계속 read-only입니다. 실제 원본 client 실험은 exact build/hash를 고정한 snapshot 가능한 disposable VM/별도 OS에서만 수행합니다. 단순 디렉터리 복제본은 정적 검산용입니다.
- system hosts/root CA 변경은 disposable VM/OS에서만, client-local certificate bundle과 pinned native compatibility shim 변경은 사전 hash·backup·rollback manifest가 있을 때만 허용합니다. 이 예외를 주 설치본이나 공식 서비스 접속에 사용하지 않습니다.
- Phase 3A의 `blocked_insufficient_evidence`는 과거의 rights-holder-approval prerequisite 판정으로 보존합니다. 운영자가 승인한 modified-local 연구 lane의 현재 권위와 진입 조건은 `docs/PHASE3AR.md`입니다.
- 공개 EpinelPS 구현은 기술적 실행 가능성의 prior art일 뿐 Shift Up의 승인 증거가 아닙니다. 권리자 승인은 주장하지 않고 법적 상태도 확정하지 않습니다.
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
- 작업 전후 repository, Phase 0, 완료된 Phase 2A1·Phase 2A2·Phase 2B, Phase 3A 역사 contract, Phase 3B-0 source-free closure, Phase 3B-1 selected-manager receipt와 Actions contract 검사를 모두 실행합니다. Phase 2B 완료 이력은 `scripts/verify-phase2b.ps1`의 단위 및 live PostgreSQL integration gate가 모두 통과한 revision을 기준으로 합니다. `scripts/verify-phase3a.ps1`은 과거 source-free evidence shape와 blocked verdict를, `scripts/verify-phase3b0.ps1`은 별도 시즌 26 closure assessment를, `scripts/verify-phase3b1.ps1`은 외부 통합 patch와 focused test의 source-free receipt를 검증합니다. 어느 script도 original-client adapter/UI/runtime actual-play를 대신 판정하지 않습니다.
