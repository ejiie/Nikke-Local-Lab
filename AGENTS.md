# AGENTS.md

이 저장소에서 작업하기 전에 다음 문서를 순서대로 읽습니다.

1. `docs/SCOPE.md`
2. `docs/DATA_POLICY.md`
3. `docs/SECURITY_BOUNDARY.md`
4. `docs/FEASIBILITY_GATES.md`
5. `docs/DOMAIN.md`
6. `docs/RAID_DOMAIN.md`
7. `docs/PROFILE_EXECUTION_DOMAIN.md`
8. `docs/IDENTITY.md`
9. `docs/DECISIONS.md`
10. `docs/IMPLEMENTATION_PLAN.md`
11. `docs/NEXT_STEPS.md`
12. `docs/GITHUB_AUTOMATION.md`
13. `docs/ARCHITECTURE.md`

## 불변 규칙

- 최종 목표는 허용된 로컬 backend에 연결된 원본 NIKKE UI와 실제 전투 runtime으로 검증하는 것입니다.
- lab-owned harness는 계약·데이터 검사용 보조 도구이며 최종 인수 조건을 대체하지 않습니다.
- 공식 로그인, 계정 토큰, 패킷 가로채기, 게임 프로세스 주입, 안티치트 우회를 사용하지 않습니다.
- 원본 리테일 클라이언트 연결은 `docs/FEASIBILITY_GATES.md`의 조건을 모두 충족하기 전까지 차단합니다.
- 원본·복호물·번들·이미지·음성·DB·실계정 데이터는 커밋하지 않습니다.
- private GitHub remote에는 source, 계약, migration, 직접 만든 합성 fixture만 push합니다.
- 원본 게임 ID를 도메인 PK/FK, API, 로그에 노출하지 않습니다.
- 미지값과 결손 참조는 임의 추정하지 않고 `unresolved` 또는 `not_applicable`로 보존합니다.
- 캐릭터 빌드 수정은 기존 row 덮어쓰기가 아니라 새 revision 생성으로 처리합니다.
- 기본값은 생성 시점 데이터 snapshot에서 실제 값으로 해소하여 저장합니다. 데이터 업데이트가 과거 revision을 자동 변경하면 안 됩니다.
- Solo Raid는 Challenge만 지원하고 `challenge-boss-support/v1` admission policy를 통과한 보스만 publish합니다.
- 일반 1~7단계와 Union Raid 전투 세션을 만들지 않습니다.
- 변경은 `agent/**` branch에 commit하고 Actions가 검증·PR·squash merge하도록 합니다.
- 작업 전후 repository, Phase 0, 현재 구현 단계(최소 Phase 1C), Actions contract 검사를 모두 실행합니다.
