# Identity and provenance

## 자체 ID

도메인 관계는 다음 두 ID를 사용합니다.

- `entity_id BIGINT`: DB 내부 조인용
- `entity_uid UUID`: API, 로그, fixture, 전투 기록용

캐릭터, 장비, 큐브, boss variant, raid encounter, asset artifact, runtime build를 포함한 모든 도메인 개체가 이 원칙을 따릅니다. 원본 게임 ID는 도메인 PK/FK로 사용하지 않습니다.

## Import alias

원본 테이블 간 관계를 해석할 때만 staging에서 원본 식별자를 읽습니다. 영구 alias는 로컬 비밀값을 사용하는 HMAC 지문으로 저장합니다.

    alias_fingerprint = HMAC-SHA256(
      LOCAL_ID_SECRET,
      domain_tag + length_prefixed(source_namespace, entity_kind, source_identifier)
    )

- 단순 SHA-256은 작은 숫자 ID 공간을 추측할 수 있어 사용하지 않습니다.
- 문자열은 strict UTF-8로 인코딩하고 각 조각을 big-endian 길이로 구분해 tuple ambiguity를 거부합니다.
- HMAC fingerprint는 entity UID가 아닙니다. private alias registry가 무작위 lab UUID에 연결합니다.
- secret 자체 대신 domain-separated key-check digest와 encoder version만 고정하며 불일치 시 import를 중단합니다.
- API 역할은 alias 테이블을 읽을 수 없습니다.
- staging 원본 식별자는 import 트랜잭션 종료 후 폐기합니다.
- 원본 season, preset, wave, monster, spot, asset 식별자는 Git 비추적 compatibility map 또는 ephemeral staging에만 존재합니다.
- 원본 ID가 바뀐 개체를 이름만으로 자동 병합하지 않습니다.
- 병합 후보는 asset provenance와 관계 증거를 검수한 뒤 명시적으로 연결합니다.

## Versioning

identity와 내용을 분리합니다.

- `entity`: 지속되는 논리 개체
- `entity_version`: 불변 내용 버전
- `dataset_snapshot`: 한 번의 데이터 입력 집합
- `snapshot_entity`: snapshot에서 사용된 entity version
- `source_artifact`: 원천 파일 bytes의 hash와 길이
- `import_run`: extractor identity/version, semantic options와 request/output hash

검증을 통과한 snapshot만 publish하며, API는 published snapshot만 기본 조회합니다.
