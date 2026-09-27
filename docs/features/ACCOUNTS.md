# 계정·니케 관리와 가져오기

기준: 2026-09-27 `main`, 운영 DB schema V0028. 과거 구현·결함 기록은 [보관 기록](#보관-기록)에 있습니다.

## 저장 원칙

- 계정·빌드·스쿼드·프로필은 자체 UUID와 immutable revision을 사용합니다. 원본 게임 ID는 PK/FK·API·로그에
  쓰지 않습니다([식별자 계약](../contracts/IDENTITY.md)).
- 빌드 수정은 기존 row를 덮어쓰지 않고 새 revision을 만듭니다. 기본값은 생성 시점 snapshot에서 실제 값으로
  해소해 저장하며, 이후 데이터 업데이트가 과거 revision을 바꾸지 않습니다([빌드 계약](../contracts/DOMAIN.md)).
- `Save`는 선택 계정에 새 revision을 쓰고, `Save As`는 새 계정을 만듭니다. 계정별 workspace 저장 경합은 DB에서
  거절하며, 응답 유실 시 원래 요청을 보존해 같은 창에서는 재전송, 새 창에서는 조회 후 명시적으로 복구합니다
  (V0018, `AccountWorkspaceSaveCoordinator.cs`, `PostgreSqlAccountWorkspaceSaveStore*.cs`).

## 화면과 API

| 기능 | 동작 | API·코드 |
|---|---|---|
| 계정 만들기 | 확인 → 닉네임·관리명 입력 → 완료 알림. 지휘관/싱크로 1, 보유 니케 없음, 재화 0, NLL 유니온 소속 | `POST /admin-api/v1/accounts/create`, `AccountDirectoryEndpoints.cs`, V0026 |
| 유니온 목록 | 홈에 유니온 카드(엠블럼·이름·ID·레벨)와 **관리도구에 등록된 계정만** 보이는 멤버 팝업 | `GET /admin-api/v1/unions`, `wwwroot/editor/account-directory.js` |
| 계정 편집 | 니케·장비·큐브·스쿼드·로비·재화 편집, Save/Save As, 저장 이력 | `AdminApiEndpoints.cs`의 `/accounts/{accountUid}/workspace` 계열 |
| 가져오기/동기화 | 계정 설정의 지휘관 레벨 옆 버튼. 덮어쓰기 경고 후 실행 | `POST /admin-api/v1/accounts/{accountUid}/connection`, `/synchronize`, `AccountConnection.cs` |
| 캐릭터 목록 동기화 | 니케 도감의 버튼. 로컬 `StaticData.pack`으로 새 불변 catalog를 만들고 신규 니케는 미보유로 추가 | `POST /admin-api/v1/characters/sync`, `CharacterCatalogSynchronization.cs`, `scripts/sync-nll-character-catalog.ps1` |
| 모두 보유로 설정 | 미보유 니케만 편집 대기에 추가(레벨·스킬 1, 돌파·코어 0, 적용 가능한 호감도 1, 미착용). Save로 저장 | `wwwroot/editor/editor.js` |

## 계정 가져오기 경계

- 운영자가 직접 여는 블라블라 로그인 브라우저와 `tools/AccountCollector`의 DPAPI 세션으로 프로필·로스터·
  상세·전초기지·소속 유니온을 읽습니다. 에이전트가 임의로 로그인하거나 실계정을 수집하지 않습니다
  ([보안 경계](../SECURITY_BOUNDARY.md) 2026-09-18 승인).
- 수집 원문은 sanitizer를 거쳐 선택 계정의 **새 revision**으로 적용합니다. `full_profile` 가져오기는 들어온
  draft의 catalog로 전체 계정 상태를 교체하고, 부분 가져오기는 기존처럼 catalog rebase를 요구합니다
  (`PostgreSqlProfileManagementService.cs`). 계정 ID·관리명·과거 revision은 유지합니다.
- 가져온 유니온 소속을 우선하며, 외부 유니온 ID는 HMAC으로 대응하고 UI에 노출하지 않습니다.
- API는 저장소 빌드 산출물 `src/NikkeLocalLab.Import.Cli/bin/Release/net8.0`의 Import CLI를 실행합니다.
  설치 API와 이 CLI의 Persistence DLL이 다르면 migration checksum 불일치로
  `account_import_schema_mismatch`가 납니다. 전체 설치 스크립트
  `scripts/deploy-nll-phase-d-control-center-offline.ps1`이 CLI를 다시 빌드하고 두 DLL hash의 일치를 확인합니다.
  Persistence만 바꾸는 부분 설치 때도 CLI를 같은 소스로 다시 빌드해야 합니다.

## 이미지

- 대표 사진은 등록 계정의 `portraitPath`를 사용하며, 원본 그림은 Git에 넣지 않습니다.
- 착용 프로필 테두리는 연결하지 않았습니다. 블라블라 응답의 `avatar_frame`은 착용 ID 근거가 없어 수집에서
  제외했고 `profileFrameStatus=not_provided_by_source`로 기록합니다(`tools/AccountCollector/collector.py`).
- 기록 화면의 정사각 얼굴 초상화는 `tools/AccountCollector/raid_portrait_assets.py`로 만듭니다. 캐릭터 목록
  동기화가 이 도구를 자동 실행하지 않으므로 신규 캐릭터가 생기면 따로 실행해야 합니다.

## 남은 확인

- 운영자 실계정 가져오기/동기화 저장 완료(카탈로그 전환 수정 이후 기록 없음).
- Import CLI 교체(2026-09-19) 이후 관리도구의 캐릭터 목록 동기화 사용자 확인.

## 보관 기록

- [계정 workspace·Save 설계](../archive/accounts/PHASE_B_ACCOUNT_WORKSPACE.md)
- [캐릭터 목록 동기화](../archive/accounts/CHARACTER_CATALOG_SYNC.md)
- [유니온 중심 계정 UI·가져오기 실패 수정](../archive/union/UNION_ACCOUNT_WORKSPACE.md)
- [관리도구 백엔드](../archive/stabilization/CONTROL_CENTER_BACKEND_DEFECTS.md)·[프런트엔드](../archive/stabilization/CONTROL_CENTER_FRONTEND_DEFECTS.md) 결함 이력
