# Decisions

## 확정

- 별도 신규 저장소이며 기존 Git history를 상속하지 않는다.
- 최종 목표는 자체 local backend에 연결된 원본 NIKKE UI와 실제 전투 runtime으로 검증하는 것이다.
- lab-owned harness는 개발·계약 검증 도구이며 최종 인수 조건을 대체하지 않는다.
- 실제 계정이 아닌 자체 계정·자체 ID만 사용한다.
- 캐릭터 빌드는 revision 기반이며 과거 revision은 불변이다.
- 생성 기본 프리셋은 `combat-max/v1`이다.
- 캐릭터 레벨은 사용자 명시값으로 자유 설정한다.
- 장비 기본값은 네 부위 모두 Tier 10, 강화 Level 5다.
- 큐브는 자유 장착·해제하며, 장착 시 기본 Level 15다. 큐브 종류는 추측하지 않는다.
- 스킬은 기본 10/10/10이다.
- 오버로드는 `research` 모드에서 exact 값 자유 write를 지원한다.
- 원본 데이터와 런타임 DB는 저장소 밖에 둔다.
- Solo Raid는 Challenge만 지원한다.
- 보스 admission은 `challenge-boss-support/v1`을 따른다.
- 현재 지원 시즌은 `7, 13, 26, 29, 34, 40`이다.
- 시즌 14와 39는 전격·철갑 조건을 만족해도 명시적으로 제외한다.
- 일반 1~7단계는 `lastClearLevel=7` 해금 stub이며 전투 구현 대상이 아니다.
- Union Raid는 비활성 확장 지점이다.
- 원본 리테일 클라이언트 연결은 `docs/FEASIBILITY_GATES.md`가 해제될 때까지 blocked다.
- raid 호환성 tier는 `static_exact`, `behavior_exact`, `asset_exact_runtime_current`, `historical_runtime_exact` 네 단계다.
- published raid snapshot 계약은 v2이며 `ready` 상태와 non-null compatibility map을 강제한다. 불완전 후보는 import diagnostic으로 분리한다.
- 현재 시즌 목록은 dataset에서 정책으로 파생한 문서화 결과이지 config에 고정된 두 번째 allowlist가 아니다.
- 공개 제재가 보이지 않는다는 정황은 permission 또는 gate 해제 근거로 사용하지 않는다.
- Phase 1A source 보호는 importer capability 수준의 read-only 보장이다. OS 전체 쓰기 방지로 표현하지 않는다.
- source path, file name, raw ID, decoded payload, exception text는 import ledger schema에 두지 않는다.
- dataset snapshot은 경로가 없는 canonical source manifest hash로 식별하고, 동일 입력은 기존 snapshot을 재사용한다.
- PostgreSQL은 loopback 연결만 허용하며 migration history는 embedded SQL checksum으로 잠근다.
- source alias HMAC fingerprint는 entity UID로 재사용하지 않고 private registry에서 무작위 lab UUID에 연결한다.
- 캐릭터 catalog의 ledger 완료와 snapshot publish는 한 PostgreSQL transaction에서 원자적으로 처리한다.
- 캐릭터 subtype과 sd.bin runtime cap을 함께 사용해 호감도 최대값을 해소한다.
- 현재 설치본만으로 전체 캐릭터 StaticData를 구성할 수 없으므로 보관된 pack과의 혼합 입력은 검증 전용이며 current-authoritative로 게시하지 않는다.

## 남은 미정사항

- 돌파 최대가 일반 한계돌파와 코어 강화 중 어디까지를 뜻하는지에 대한 데이터별 해소 규칙
- 기업 일치 장비를 기본으로 적용할지
- Tier 10과 오버로드 장비 상태의 정확한 관계
- 소장품·애장품의 단계/레벨 표현과 스킬 변형 모델
- 콘솔, 리사이클 룸 등 추가 전투 스탯 축
- 각 지원 시즌의 runtime exact 증거 확보 범위
- 원본 client gate를 충족할 수 있는 권리자 지원 interface의 존재 여부

미정값은 임의 기본값으로 채우지 않고 contract에서 `unresolved`로 표현합니다.
