# Phase 1B — character catalog importer

> 단계별 계약·검증 기준입니다. 이 문서의 과거 실행 판정과 현재 운영 상태를 구분합니다. 현행 상태는 [인계 요약](../HANDOFF.md), 남은 작업은 [다음 작업](../NEXT_STEPS.md)을 확인합니다.

Phase 1B는 캐릭터 전투 정의를 원본 파일에서 읽어 자체 ID catalog로 게시하는 오프라인 경로입니다. 공식 인증, 네트워크, 게임 프로세스, 런처 또는 보호 기능에는 접근하지 않습니다.

## 입력과 출처

import 하나는 다음 두 read-only artifact를 같은 dataset manifest에 고정합니다.

- 캐릭터 정적 테이블을 포함하는 StaticData archive
- 설치본의 sd.bin에 있는 호감도 runtime cap

두 artifact를 읽기 전후에 각각 SHA-256과 길이로 다시 관찰합니다. 하나라도 바뀌면 source_changed_during_import로 중단합니다. ZIP은 디스크에 풀지 않고 메모리에서 읽으며 경로 탈출, 중복 entry, 암호화, 과도한 entry 수·크기·압축 비율을 거부합니다. MemoryPack은 예상 member count와 EOF를 정확히 검사합니다.

현재 설치본의 sd.bin에는 호감도 cap은 있지만 전체 캐릭터 StaticData는 없습니다. 따라서 설치본 하나만으로 현재 catalog를 완성했다고 주장하지 않습니다. 별도로 보관된 과거 StaticData와 현재 sd.bin 조합은 parser 검증용 unverified_compound이며 current-authoritative snapshot으로 승격하지 않습니다.

## 식별자 경계

- source key는 import 중에만 사용합니다.
- source key는 domain-separated HMAC-SHA256 fingerprint로 변환됩니다.
- fingerprint와 encoder key-check는 lab_private/lab_meta에만 저장됩니다.
- 캐릭터, 정의 버전, dataset, catalog snapshot은 모두 무작위 lab UUID를 사용합니다.
- HMAC secret이 바뀌면 import를 계속하지 않고 identity_key_mismatch로 중단합니다.
- 도메인, receipt, CLI 출력에는 source key, fingerprint, 경로, 파일명 또는 원문 payload가 없습니다.

## 정규화 계약

논리 캐릭터는 source name grouping key로 묶되, 그 key 자체는 domain에 전달하지 않습니다. 같은 그룹의 resource, 희귀도, 클래스, 제조사 subtype, 속성, 무기와 세 스킬 참조가 다르면 해당 그룹을 publish하지 않습니다.

정규화 대상:

- 희귀도, 전투 클래스, 무기, 속성, 제조사
- snapshot이 지원하는 최대 캐릭터 레벨
- 최대 돌파와 최대 코어
- 캐릭터 subtype과 runtime cap을 함께 적용한 최대 호감도
- 스킬 1/2/버스트 최대 레벨
- T10 장비와 T10 최대 강화 레벨
- 큐브 최대 레벨
- 무기별 소장품 최대 레벨
- 캐릭터별 애장품 최대 레벨 또는 not_applicable

ready, unresolved, not_applicable는 서로 다른 상태입니다. 결손·스키마 drift·알 수 없는 enum을 0이나 임의 기본값으로 바꾸지 않습니다. 장비 definition 선택과 제조사 일치 여부는 아직 unresolved이며 Phase 2 build write에서 명시적으로 선택합니다. 큐브는 catalog capability만 기록하고 기본 build에서는 미장착입니다.

## 도메인과 기본 build

CharacterDefinitionVersion은 dataset UID, character UID, immutable content와 content SHA-256을 고정합니다. combat-max/v1은 다음을 해소합니다.

- 캐릭터 레벨: 호출자가 명시하며 snapshot 최대값 이하
- 돌파·코어·호감도: authoritative maximum
- 장비: 네 부위 T10/+5
- 스킬: 10/10/10
- 큐브: 미장착
- 오버로드: 빈 4×3 line 구조
- 소장품·애장품: max 또는 not_applicable

필수 사실이 unresolved이면 build seed는 만들어도 전투 준비 완료로 판정하지 않습니다.

## PostgreSQL 게시

V0002__character_catalog.sql은 다음을 추가합니다.

- private source alias registry와 identity key binding
- lab-owned character entity와 immutable definition version
- 10개 scalar capability와 4개 장비 slot capability
- dataset provenance에 연결된 immutable character catalog snapshot과 membership

ledger 완료와 catalog publish는 같은 transaction입니다. 같은 source alias는 같은 character UID를 재사용하고, 내용이 달라지면 새 version을 만들며, 과거 snapshot membership은 변경하지 않습니다. 동일 request는 기존 snapshot을 재사용합니다. 추출기의 source-key 기반 candidate hash와 게시 후 lab-owned character UID로 계산한 catalog manifest hash는 서로 다른 provenance 값으로 저장하며, 후자를 전투 기록이 참조할 최종 catalog 식별자로 사용합니다.

## CLI

모든 명령은 Phase 1A와 동일하게 --config와 --repository-root를 요구합니다. 실제 secret은 설정 파일이 지정한 환경변수에 Base64로 제공하며 Git에 저장하지 않습니다.

    character-catalog-inspect --static-root <absolute-local-root> --static-file <relative-archive>
    character-catalog-import  --static-root <absolute-local-root> --static-file <relative-archive>

--game-config-file을 생략하면 configured game root 아래의 기본 설치 상대경로를 사용합니다. inspect는 aggregate count와 candidate digest만 출력합니다. 여기서 source-resolved count는 원천 데이터에서 필요한 최대치가 모두 해소된 정의 수이지, 장비 선택까지 끝난 전투 준비 캐릭터 수가 아닙니다. import는 PostgreSQL receipt의 lab-owned UUID, 최종 catalog manifest hash와 count만 출력합니다.

## 완료 검사

    pwsh -NoProfile -File scripts/verify-phase1b.ps1
    pwsh -NoProfile -File scripts/verify-phase1b.ps1 -Integration

검사는 합성 ZIP/MemoryPack, 잘못된 ZIP·schema·UTF-8, canonicalization, combat-max/v1, source 경계, migration drift, 원자적 publish, 재사용/versioning, identity key mismatch, rollback 및 DB/receipt 누출을 검증합니다. Actions는 합성 fixture와 폐기 가능한 PostgreSQL만 사용하며 실제 게임 source나 local identity secret을 받지 않습니다.
