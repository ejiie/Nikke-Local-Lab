# 유니온 중심 계정 관리 — 2026-09-18

## 대표 사진·착용 테두리 연결 — 2026-09-19

- 사용자 종료 확인 후 API/Persistence DLL, 공통 아바타 UI, 로컬 테두리 묶음을 설치했다. 교체 전 파일을 백업했고 설치본 해시가 준비본과 일치함을 확인했다. 설치 영수증: `artifacts/local-profile-frames-20260919/installation.receipt.json`. 사용자 재실행 후 화면 확인은 별도 인수다.

- 계정 설정의 문자 아바타와 유니온 멤버 목록은 공통 `renderAvatar`로 대표 사진 및 테두리를 표시한다.
- 정정: `GetUserGamePlayerInfo.data.avatar_frame`은 블라블라 사이트에서 프로필 통계에 사용되며 착용 게임 테두리 ID라고 해석할 근거가 없다. 이전의 착용 값이라는 설명과 직접 매핑은 잘못이었다. 원본 응답의 필드 존재와 의미 검증을 구분한다.
- 해당 조회의 식별자 오류를 수정해 실제 응답(값 0)을 받았으나 착용 값이라는 증거가 아니므로 수집 경로에서 제거했다. 현재 확인한 블라블라 계정 응답은 착용 테두리 ID를 제공하지 않는다. 수집 시 `profileFrameStatus=not_provided_by_source`로 기록하며 통계 값·0 값을 착용 ID/미착용 판정으로 사용하지 않는다.
- 로컬 `UserFrameTable`과 SD user-frame bundle에서 추출한 PNG는 유효한 착용 값이 별도로 확보됐을 때만 연결한다. 게임 ID는 private index 내부에서만 사용하고 UI에는 내용 해시 기반 로컬 이미지 URL만 전달한다.
- 원본 테이블 320종의 기본/부속 이미지를 원래 캔버스 좌표로 합성했다. 미착용 값 0은 투명 이미지로 구별한다. 프리즘 애니메이션은 재현하지 않는다.
- 버전 독립 runtime preferences의 현재 head가 가져오기보다 최근이면 그 착용 값을 표시한다. 이는 NLL 게임 내부의 선택이며 블라블라에서 가져온 실제 계정의 착용 값은 아니다. 기존 runtime 기록이 있는 두 계정의 표시와 공식 계정 테두리 동기화 성공을 혼동하면 안 된다. 현재 경로에서 동기화를 반복해도 없는 착용 값을 확보할 수 없다.
- 이 UI 투영은 gameplay DB나 암호화 프로필을 수정하지 않는다. 계정 선택을 막지 않도록 없는 이미지/손상된 선택적 artwork는 생략한다. 원본 이미지·private index·실계정 검증 자료는 커밋하지 않는다.
- 초기 확인: 합성 암호화 데이터의 계정 결합·변조 거부, 실제 로컬 DB 5계정의 표시 투영(착용 기록 2계정), 두 UI 크기의 사진/테두리 렌더링. 당시 수집 경로의 합성 검사는 잘못된 필드 의미까지 가정해 실제 착용 값 수집 성공을 입증하지 못했다.
- 사용자 동기화 실패 후 확인: 저장 raw의 오류 코드, 본인 커뮤니티 식별자를 사용하는 사이트 호출 순서, 동일 계정의 조회 성공 응답, 사이트의 avatar_frame 사용처를 대조했다. 통계 값을 착용 ID로 변환하는 경로와 불필요한 요청을 제거했으며, 값이 0이거나 로컬 테이블 키와 같아도 착용 값으로 해석하지 않는 회귀 검사를 통과했다. 수집기는 저장소 Python 파일을 직접 실행하므로 수정이 즉시 반영되고 DLL 재설치는 필요 없다. 자료는 `artifacts/local-profile-frames-20260919/`에 보관한다.

## 사용자 요구

- 계정 가져오기 탭 제거. 홈에 계정 만들기와 유니온 목록을 제공한다.
- 생성 확인 → 닉네임·관리용 이름 입력 → 완료 알림. 완료 알림에는 다시 보지 않기를 제공한다.
- 신규 계정은 기본 육성 상태, NLL 소속이다. 기존 계정의 스펙을 복제하지 않는다.
- 유니온 카드에는 엠블럼·이름·ID·레벨을 표시한다. 구성원 팝업은 사용자가 첨부한 블라블라 화면의 배치·간격·흰색 목록·원형 대표 사진·오른쪽 싱크로 배지를 따른다.
- 계정 설정의 지휘관 레벨 옆에서 가져오기/동기화를 제공한다. 덮어쓰기 주의 확인과 다시 보지 않기를 제공하며 성공한 가져오기만 버튼 상태를 바꾼다.
- 가져온 유니온 소속을 우선한다. 기존 저장본을 변경하지 않고 새 revision으로 적용한다.

## 참고와 구현 경계

사용자가 지정한 `ejiie/Nikke-Simul`의 참고 revision은 `e9d7410a92a8b38619c0a8c4fe4f4f4c5133d004`이다. `tools/data-pipeline/collector.py`의 사용자가 직접 로그인하는 브라우저와 DPAPI 세션, 서버 선택, 프로필·로스터·상세·전초기지 조회 흐름을 연결한다. NLL의 기존 sanitizer 및 저장 계층을 유지한다. 사용자 요청은 이 계정 가져오기 기능의 구현 승인이며, 에이전트가 임의로 로그인하거나 계정을 수집하는 지시는 아니다.

구현, 합성/DB/브라우저 검사, 설치, 사용자 실계정 가져오기 확인은 각각 기록한다. 기존 게임 실행·음성·FX·종료 경로의 변경은 이 UI 작업의 요구가 아니다.

## 진행

2026-09-19: 계정 설정의 고정 `C` 아바타를 등록 계정의 `portraitPath`에 연결했다. 유니온 멤버 목록과 같은 렌더러를 사용하며 계정 선택/목록 갱신 때 갱신한다. 사진 결손은 기본 사진, 제공된 `framePath`는 오버레이하고 이미지 로드 실패 시 제거한다. 착용 테두리의 수집·이미지 대응은 여전히 미구현이다(`nll.py`에서 수집하지 않음). 정적 파일 4개 설치 및 기존 계정 디렉터리 브라우저 검사 통과. `artifacts/account-summary-avatar-20260919/installation.receipt.json`.

후속 로컬 테두리 조사: 공식 현재 설치본의 dp 카탈로그에 user-frame 전용 SD/HD 번들이 있다. SD는 필요한 53개 chunk가 모두 설치돼 있고, HD는 189개 chunk 모두 결손이다. SD 번들을 읽기 전용 추출해 Sprite 246개 디코딩 및 PNG 표본 3개 생성에 성공했다. 이는 장식 조각을 포함한 Sprite 수이며 테두리 종류 수가 아니다. `UserFrameTable`의 ResourceId/SubResourceId 구조와 계정 ProfileFrame 저장 필드는 존재한다. 실제 착용값의 정확한 테이블/이미지 대응 및 UI 수집 연결은 다음 단계다. 결손 원인은 로컬 이미지 부재가 아니라 구현 시 이 공급 경로를 연결하지 않은 것이었다. 증거와 원본 파생물은 Git 제외 `artifacts/local-profile-frames-20260919/`에 보존하며 외부 요청·공식 설치본 수정은 없었다.

참고 코드 및 기존 계정/유니온 저장 구조 확인 완료. 구현 중.

표시 대상은 **관리도구에 등록된 계정만**이다(운영자 추가 답변). 외부 유니온 구성원을 자동 생성하거나 전체 명단을 수집하지 않는다. 무소속 계정은 별도 ‘소속 없음’ 그룹에 표시한다. 생성 기본값은 지휘관/싱크로 1, 콘솔 0, 보유 니케 없음, 재화 0이며 현재 카탈로그에 바인딩한다. 가져오기는 관리용 이름과 기존 저장본을 유지한 채 현재 선택 계정에 새 revision을 적용한다.

## 구현·검사 기록

- `account-directory.js`: 생성 확인/입력/완료, 다시 보지 않기, 유니온 카드·등록 멤버 팝업. 구성원 선택으로 기존 계정 편집 경로를 사용한다.
- `AccountDirectoryStore`, migration 26: 기본 계정 생성, 소속/이미지 보관. 같은 생성 요청의 닉네임·관리명 변경 재사용을 거부한다. 그림 경로는 로컬 account-art URL만 DB CHECK로 허용한다.
- `AccountConnectionService`, `tools/AccountCollector`: 사용자가 연결한 블라블라 서버 선택 → sanitizer → 선택 계정의 새 revision → 소속/이미지 반영. DPAPI 세션을 재사용하며 인증 만료 시 재연결한다. 관리용 계정 이름은 유지한다.
- 기본 NLL 및 신규 계정 그림은 원본 대응표로 해소했다. 기존 등록 계정 3개의 대표 사진은 로컬 runtime preferences에서 선택값을 읽어 준비했다. 해당 공개 이미지 요청은 자동 승인 검토 거부 후 운영자가 명시 허용했다. 계정 ID/이름/인증정보를 이미지 서버로 전달하지 않는다.
- 가져온 유니온의 진행도는 membership의 local union ID로 분리한다. NLL의 기존 레이드 기록은 유지한다. 가입 레벨 1도 유니온 표시는 가능하며 레이드 개방 레벨 조건은 유지한다.
- 소속 유니온 ID 표시는 로컬 ID다. 외부 유니온 ID는 HMAC으로 대응하며 UI에 노출하지 않는다.
- 실제 대표 사진은 표시한다. 착용 테두리는 검증된 이미지 대응 정보가 없어 이번에는 반영하지 않는다.

합성 브라우저: 생성 취소/확인/완료 알림 설정, 유니온별 등록 멤버·사진·싱크로, 멤버 선택, 가져오기 경고 취소/기억, CSRF, 성공 후 소속 및 동기화 버튼 전환 통과. 기존 자동 시작/유니온 시즌 UI도 통과했다. Python 브리지 2개, native 유니온/개방 검사 24개, 별도 PostgreSQL 유니온 분리·동시 결과·rollback·재시작 검사 통과. 전체 PostgreSQL 회귀와 설치는 진행 중이다.

실계정 로그인/가져오기와 설치 후 실게임 검증은 이 자동 검사에 포함하지 않는다.

## 설치 완료

`artifacts/union-account-ui-20260918/installation.receipt.json`: 2026-09-18 설치 완료, schema 26, 파일 18개 교체/추가. DB 및 파일 백업 후 기존 테이블 값의 fingerprint 불변 확인(유니온 테이블의 신규 표시 열 제외). Migration 재실행 추가 적용 0건. 기존 계정 3개의 대표 사진 설치 완료.

필수 gate 8개 통과. 전체 PostgreSQL 121개 중 120개 통과 후 새 이미지 경로 열을 금지 열 검사에서 잘못 잡던 1개를 수정했으며 해당 검사와 계정/소속/외부 URL 거부 검사 2개 재실행 통과. 이를 단일 전수 실행 전부 통과로 표현하지 않는다. Browser·native·유니온 DB 분리 검사는 위 기록과 같다. 실제 블라블라 로그인·가져오기 성공 여부는 사용자가 새 버튼에서 확인해야 한다.

설치 후 관리도구 재개 성공: `desktop-reopen.receipt.json`, session 생성 및 editor HTTP 200, 새 `account-directory.js` HTTP 200. 게임은 실행하지 않았다. 실제 계정 가져오기 및 테두리 표시는 위 제한을 유지한다.

## 사용자 가져오기 실패 조사 — 2026-09-18

19:33 수집에서 서버 선택 및 프로필 수집·이미지 준비는 완료됐으나 `AccountImports` 작업 폴더에 draft가 생성되지 않았다. 저장된 원본에 `profile-source-inspect`를 읽기 전용 실행한 결과 roster/detail 각각 193건, 장비 772좌표로 형식 검사가 통과했다. 외부 재수집은 하지 않았다.

직접 원인은 보조 Import CLI의 오래된 Persistence DLL이다. API가 저장소의 `src/NikkeLocalLab.Import.Cli/bin/Release/net8.0`을 실행하는데, 해당 DLL은 18:24 빌드이고 설치 API의 DLL은 18:53 빌드다. 두 DLL에 내장된 V0026 SQL의 SHA-256은 각각 `85dd0248fe6a5003e72b341ee0070464094ddb6f555a27d43f5b57ec51f80f8b`, `6ac70ef2ee0f440f7d1ed54d720b3abd99becf1b87228aac086b6e31d6e2f462`로 다르다. 운영 DB를 READ ONLY 트랜잭션으로 조회한 V26 체크섬은 설치 API와 일치한다. CLI의 migration 검사에서 `migration_checksum_mismatch`로 거절되는 상태다. 계정 revision 적용보다 앞선 단계다.

오류 은폐도 있다. `AccountImportExecution.RunAsync`가 CLI stderr를 버리고 단계 오류로 바꾸며, 새 `/synchronize` 경로는 기존 가져오기 endpoint의 `AccountImportException` 변환을 사용하지 않아 공통 middleware에서 `internal_error`가 된다. 보조 CLI를 최종 스키마와 함께 빌드·배포하고, 새 endpoint에도 안전한 오류 코드 전달을 적용해야 한다. 이번은 원인 조사이며 코드·설치본·운영 계정 데이터는 변경하지 않았다.

## 가져오기 실패 수정·재설치 — 2026-09-18

운영자 후속 요청으로 Import CLI를 최종 소스에서 다시 빌드했다. 설치 API와 CLI의 Persistence DLL 해시가 일치한다. 공통 API 예외 처리에 `AccountImportException`을 연결하고, CLI의 알려진 migration 오류만 `account_import_schema_mismatch`로 전달한다. 그 외 stderr 원문·계정 정보는 전달하지 않는다. 전체 설치 스크립트에도 준비된 CLI/API Persistence DLL 불일치 거절 검사를 추가했다.

새 오류 회귀 6개와 기존 API 보안 검사 포함 38개 통과. 운영 DB 연결을 `default_transaction_read_only=on`으로 제한해 스키마 체크섬 26개 일치 및 기존 수집 데이터의 실제 카탈로그 기반 sanitizer 성공을 확인했다. 외부 재수집·계정 적용·스키마 변경은 하지 않았다. 필수 회귀의 첫 실행은 NuGet 접근 실패, 재실행은 기존 테스트의 임시 `.ui-action.lock` 정리 실패 1건으로 중단됐고 제품 변경 없이 재실행한 Admin API 검사 585개는 통과했다.

`artifacts/account-import-repair-20260918/installation.receipt.json`: API DLL 백업 후 교체 및 CLI 일치 확인 완료. `desktop-reopen.receipt.json`: 관리도구 재개·세션 생성·기본 화면 HTTP 200 확인. 게임은 실행하지 않았다. 실제 가져오기 저장 완료는 사용자 인수와 구분한다.

### 후속 카탈로그 불일치 수정

첫 수정 후 사용자의 실제 시도는 `sanitized_profile_catalog_rebase_required`로 실패했다. 앞선 읽기 전용 sanitizer 검사만으로 기존 계정에 적용하는 경계를 확인하지 못했다. 전체 계정 가져오기도 과거 계정의 카탈로그와 일치해야 한다는 기존 제한이 원인이었다.

`MaterializeImportProfile`은 `full_profile`일 때 incoming draft의 캐릭터·지원 카탈로그로 **새 revision**을 작성한다. 전체 계정 상태·build를 함께 교체하며, 기존 계정 ID·관리명·과거 revision은 유지한다. 기존 큐브는 대상 카탈로그의 구성원/레벨 검사를 유지하고, 부분 가져오기는 기존의 rebase 요구를 유지한다. 데이터 업데이트 자체가 기존 revision을 변경하는 처리는 없다.

검사: 폐기 PostgreSQL에서 전체 가져오기 카탈로그 전환·동일 요청 replay·과거 revision 보존·부분 가져오기 거절 및 기존 authority/review 관련 3개 통과. **운영 DB를 별도 임시 DB로 복제**해 이미 수집된 파일로 `ImportPreparedAsync` 전체 경로(변환·snapshot·preview·apply·등록·로비 반영·재조회)를 등록 계정 3개에 실행해 모두 성공했다. 관리용 이름·계정 ID 및 계정 수 불변을 확인했다. 운영 계정에는 적용하지 않았고 외부 재수집도 없으며 검사 후 임시 DB와 복제 파일을 삭제했다.

`catalog-installation.receipt.json`: API/Persistence DLL 백업·교체 완료, CLI와 같은 Persistence 빌드임을 확인했다. 첫 수정의 필수 Phase 2B 단위/연계 검사는 `phase2b-retry.log`에서 최종 통과했고, 이번 추가 persistence 수정은 위 실제 복제본 재현 및 집중 DB 검사로 검증했다. UI에서의 실제 가져오기 완료는 여전히 사용자 인수다.
