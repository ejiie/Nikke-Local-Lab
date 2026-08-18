# AGENTS.md

이 저장소에서 작업하기 전에 다음 문서를 순서대로 읽습니다.

1. `docs/SCOPE.md`
2. `docs/DATA_POLICY.md`
3. `docs/SECURITY_BOUNDARY.md`
4. `docs/DOMAIN.md`
5. `docs/IDENTITY.md`
6. `docs/DECISIONS.md`

## 불변 규칙

- 목적은 개인 로컬 전투·검증이며 공식 서비스 접속을 모사하는 것이 아닙니다.
- 공식 로그인, 계정 토큰, 패킷 가로채기, 게임 프로세스 주입, 안티치트 우회를 사용하지 않습니다.
- 원본·복호물·번들·이미지·음성·DB·실계정 데이터는 커밋하지 않습니다.
- 저장소에는 코드, 계약, migration, 직접 만든 합성 fixture만 둡니다.
- 원본 게임 ID를 도메인 PK/FK, API, 로그에 노출하지 않습니다.
- 미지값과 결손 참조는 임의 추정하지 않고 `unresolved` 또는 `not_applicable`로 보존합니다.
- 캐릭터 빌드 수정은 기존 row 덮어쓰기가 아니라 새 revision 생성으로 처리합니다.
- 기본값은 생성 시점 데이터 snapshot에서 실제 값으로 해소하여 저장합니다. 데이터 업데이트가 과거 revision을 자동 변경하면 안 됩니다.
- 작업 전후 `scripts/verify-repository.ps1`을 실행합니다.
