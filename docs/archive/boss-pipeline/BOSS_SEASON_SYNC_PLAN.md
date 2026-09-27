# 시즌 목록 동기화

> 2026-09-27 보관: 작성 당시의 기록이며 현재 작업 지시가 아닙니다. 현행 문서는 [문서 색인](../../README.md)에서 찾습니다.

2026-09-16. 상태: 임시 캐시 직접 읽기 구현·자동 검사·설치 및 설치된 서비스 검증 완료.
운영자는 동기화 버튼을 누르면 발견한 캐시를 읽도록 확정했다.
갱신 주체 추적이나 공식 실행 여부 판별은 선행 조건이 아니다.

## 사용자 요구

시즌 선택 화면에서 동기화를 요청하면 업데이트로 추가된 시즌을 발견하고 목록에 표시한다.
예를 들어 원본 자료에 시즌 41이 추가되면 해당 카드를 통해 기존 공통 보스 가져오기를
실행할 수 있어야 한다. 목록 재조회만 하는 버튼은 이 요구를 충족하지 않는다.
속성 필터는 카드의 기본 약점 기준이며 기존 필터·정렬을 유지한다.

## 확인한 현재 구조

- `BossSeasonCatalog.Build`는 원본 manager의 최대 시즌 번호까지 목록을 만든다.
  40이라는 상한이 코드에 고정되어 있지는 않다.
- API의 `FilesystemBossSeasonCatalogService`는 시작 시 지정한 목록 파일과 해시를
  계속 읽는다. UI의 `refreshCatalog`에는 새 원본 수집이나 목록 재생성 기능이 없다.
- `BossOnboardingComposition`은 목록과 가져오기 작업자를 같은 configuration으로 묶는다.
  `invoke-nll-boss-onboarding-job.ps1`은 요청 목록 해시와 원본 StaticData 해시를 확인한다.
  따라서 목록만 교체하고 작업자가 예전 원본을 읽게 두면 새 시즌을 가져올 수 없다.
- `BossCatalogLocales.Stage`와 materializer의 `--export-boss-season-catalog`를 재사용할 수 있다.
  전자는 로컬 리소스에서 이름 자료를 읽고 후자는 시즌·이름·기본 약점 목록을 생성한다.
- 공식 설치 경로의 파일명 조사에서는 독립된 `StaticData.pack`을 찾지 못했다.
  실제 저장 형태와 업데이트 자료 출처를 먼저 확인해야 한다. 파일이 없다는 이유로
  계정 수집이나 공식 로그인 절차를 시즌 동기화에 끌어오지 않는다.

## 구현 순서와 완료 조건

1. 시즌 표는 `%LOCALAPPDATA%\Temp\com_proximabeta\NIKKE\StaticData.pack`에서 읽는다.
   이름 자료는 `C:\NIKKE`의 saus 리소스에서 읽는다. 두 원본에는 쓰지 않는다.
2. 동기화 요청에서 변경 여부를 확인한다. 같은 자료면 기존 결과를 재사용하고,
   변경됐으면 새 목록과 해당 목록을 사용할 가져오기 입력을 함께 준비한다.
3. 준비 성공 후 목록과 가져오기 입력을 한 번에 선택한다. 진행 중인 가져오기 작업은
   시작 때 선택한 입력을 끝까지 사용한다. 실패하면 기존 목록·입력을 유지한다.
   이미 게시된 보스와 실행 구성, 계정, 음성 설정을 동기화가 덮어쓰지 않는다.
4. 시즌 선택 제목 옆에 `시즌 목록 동기화` 버튼을 배치한다. 진행 중 중복 클릭을 막고
   `새 시즌 N개 추가`, `추가된 시즌이 없습니다`, 실패 이유를 표시한다.
   새 시즌이 현재 필터에 가려진 경우 추가 사실을 알리되 필터를 임의로 바꾸지 않는다.
5. 합성 40→41 자료에서 목록 추가와 동일 입력의 공통 가져오기 연결을 검사한다.
   변경 없는 반복 동기화, 실패 후 기존 목록 보존, 진행 중 가져오기, 필터 유지도 확인한다.
   실제 설치 자료 검증과 새 버전 클라이언트의 실게임 호환성 확인은 구분해 기록한다.

새 버전의 보스가 발견됐다는 사실만으로 현재 고정 클라이언트에서 실행된다고 표시하지 않는다.
필요한 자산·형식이 호환되는지는 기존 공통 조립/준비 경로의 결과로 판단한다.

## 구현·검사 결과

- `sync-nll-boss-season-catalog.ps1`이 클릭 시 캐시의 안정된 복사본을 읽는다.
  기존 시즌 카드는 유지하고 새 번호의 시즌만 추가한다. 같은 자료나 새 시즌이 없는 경우
  복사한 pack을 남기지 않는다. 이름 자료도 처리 후 임시 복사본을 제거한다.
- catalog 전용 로컬 해석기는 선택된 캐시의 내용만 해석하며 출처/공식 서명 인증을 주장하지
  않는다. 기존 가져오기·실행 검사와 기존 원본 해석기의 정책을 바꾸지 않았다.
- 목록과 가져오기 configuration을 함께 선택한다. 이미 수락한 작업은 기존 목록 revision을
  사용하며 재시작 뒤에도 동일하다. 게시된 보스·DB·실행 bundle·음성 설정은 변경하지 않는다.
- 합성 40→41 추가, 신규 보스 가져오기 입력 전달, 이전 대기 작업과 재시작,
  실패/변경 없음 시 보존, 중복 클릭 검사를 통과했다. API 집중 검사 22개와 JS 검사 9개 통과.
- 실제 캐시로 `unchanged`를 확인했다. 별도 후보 폴더에서 목록의 마지막 시즌을 제외한
  이전 목록을 만들어 39→40 추가 분기도 검증했다. 이름·이미지와 pack/config 연결이 통과했다.
  이는 실제 시즌 41 존재나 새 클라이언트 버전의 실게임 호환성 확인을 뜻하지 않는다.
- 근거: `artifacts/season-sync-20260916/`의 `rehearsal.receipt.json`,
  `addition-rehearsal.receipt.json`, `test-api.log`, `test-ui.log`.
- 필수 회귀 gate 8개와 패키지 적용·반복 적용·복원 검사가 통과했다.
  설치된 서비스에서도 두 차례 동기화가 `unchanged`, 최대 시즌 40으로 완료됐다.
  설치 과정의 관리도구 시작은 UAC 단계에서 완료되지 않아 최초 적용을 복원한 뒤,
  앱 시작을 분리해 파일 설치를 완료했다. 관리도구를 다시 열어 사용한다.
  실제 설치 화면에서 버튼을 클릭한 검증과 새 시즌 실게임 검증은 아직 수행하지 않았다.
  근거: 같은 폴더의 `installation.receipt.json`, `installed-service.receipt.json`,
  `post-code-gates/required-gates.receipt.json`, `app-package/receipt.json`.

## 동기화 버튼 HTTP 요청 누락 수정 (2026-09-16)

설치 후 사용자가 버튼에서 `동기화 결과를 확인하지 못했습니다`를 관측했다.
`syncCatalog`가 본문 없는 POST를 보냈고, 공통 `api` 함수는 본문이 있을 때만 JSON
Content-Type과 CSRF 헤더를 추가한다. 따라서 서버가 동기화 서비스 진입 전에
`415 / json_content_type_required`로 거절한다. 서비스 직접 호출과 대체 API를 쓰는
UI 검사만으로는 실제 통신 연결의 이 결함을 발견하지 못했다.

다른 명령과 동일하게 빈 JSON 객체를 보내도록 수정하고 UI 파일 한 개를 백업 후 설치했다.
실제 editor 통신 함수 검사에서 설치 전 파일은 실패, 설치 후 파일은 통과했다.
HTTP 서버 검사에서도 기존 요청의 415, CSRF 누락의 403, 정상 요청 두 번의 200을 확인했다.
HTTP 검사는 합성 동기화 서비스로 실행했으며, 설치된 관리도구 화면 클릭의 결과를
대신 주장하지 않는다. UI 관련 검사 22개가 통과했고 원본 pack·DB·서버 코드는 변경하지 않았다.
수정 후 필수 회귀 gate 8개도 모두 통과했다.
근거: `artifacts/season-sync-20260916/http-fix/`의 `installation.receipt.json`,
`installed-transport.receipt.json`, `http-test.log`, `ui-tests.log`, `required-gates.receipt.json`.

## 초기 설치본 읽기 조사와 후속 정정

- `Unity/com_proximabeta_NIKKE/.lcv.dat`는 리소스 버전과 하위 리소스 항목을 보관한다.
  확인한 최상위 필드에는 StaticData 경로나 시즌 표가 없다.
- `com.shiftup.patch`의 core/dp/fd/saus 카탈로그에서 raw 항목과 관련 chunk 이름을 조사했다.
  독립된 `StaticData.pack` 및 솔로레이드 manager/preset 표 참조를 찾지 못했다.
- `nikke_Data/StreamingAssets/sd.bin`은 ZIP이며 초기 구동용 JSON 표 5개만 있다.
  솔로레이드 manager/preset/wave/monster/element 표는 포함하지 않는다.
- `nikke_Data`의 Unity `.assets` 18개에 있는 TextAsset 9개를 확인했지만
  전체 StaticData 및 솔로레이드 표는 찾지 못했다. 모든 바이너리 내부에 데이터가
  없음을 증명한 것은 아니다. 후속 조사에서 설치 폴더 밖 임시 캐시 경로를 찾았다.
- 현재 보스 목록과 가져오기는 별도로 확보한 151 StaticData와 gameconfig를 쓴다.
  기존 `invoke-nll-version-input-acquisition.ps1`은 정확한 gameconfig를 입력받는
  별도 수집기다. 설치본을 갱신하면 새 gameconfig가 자동 생성되는 기능은 없다.
  현재 기능은 별도 수집기를 호출하지 않고 운영자가 지정한 임시 캐시를 읽는다.

초기 읽기 조사에서는 공식 설치본·관리도구·실행 구성·사용자 설정을 변경하지 않았다.
로컬 근거는 `artifacts/season-sync-20260916/`의 두 읽기 조사 프로그램과 private 결과다.
원본 이름/참조가 포함된 상세 결과는 커밋하지 않는다.

## 보스 이미지 공급원을 로컬 설치본으로 전환 (2026-09-16)

운영자 요청으로 보스 이미지의 enikk.app 다운로드를 제거했다. 캐릭터 이미지 공급은 이 변경의 대상이 아니다.

- `bossImageExtraction.sourceRoot`는 공식 설치본의 `com.shiftup.patch/dp`를 읽기 전용으로 지정한다.
  ResourceCatalogPreflight의 `export-boss-image-bundles`가 시즌별 MonsterImage의 정확한
  Addressables 별칭 → 의존 번들 → patch catalog → chunk index 관계로 필요한 범위만 추출한다.
- 설치된 HD를 우선하고, HD가 없으면 설치된 SD를 사용한다. 동일 품질에서 여러 번들이 충돌하면
  추측하지 않는다. Python은 정확한 이름의 Texture2D를 PNG로 변환하여 투명 여백과 원래 캔버스를 보존한다.
- 추출 번들은 임시 폴더에서 처리 후 삭제한다. PNG는 기존 UI image cache 형식으로 보관한다.
  전체 store 복사·전체 store 해시·인터넷 요청·게임 실행·음성 설정 변경은 하지 않는다.
- 기존 시즌도 최초 1회 로컬 이미지로 전환한다. 새 이미지가 없으면 기존 PNG와 이미지 hash를 유지한다.
  기존 시즌의 이름·약점·discovery 정보는 보존한다. 새 시즌의 결손 이미지는 unresolved다.
- pack과 로컬 이미지 catalog/index가 같으면 반복 동기화는 재추출 없이 unchanged다.
  로컬 다운로드가 추가되어 index가 바뀌면 결손 이미지도 다시 시도한다.
- 실제 자료에서 39개 시즌 이미지를 추출했다. 시즌 범위는 1~40이며 기존에 원본 참조가 없는
  시즌 19는 성공 개수에 포함하지 않는다. 실제 39→40 추가 분기, 로컬 원본 결손 시 이전 이미지
  보존, 반복 unchanged를 별도 후보로 확인했다. 신규 시즌 실게임 실행 검증을 의미하지 않는다.

근거: `artifacts/local-boss-images-20260916/`. 설치 시 이전 catalog revision도 유지하여
이전에 수락한 가져오기 작업과 이미지 URL이 이전 revision을 계속 해소할 수 있게 한다.

설치 완료: 활성 구성을 로컬 이미지 catalog로 전환했고, 설치된 API 서비스에서 현재/이전
catalog 이미지 조회와 동기화 unchanged를 확인했다. 앱 바이너리는 교체하지 않았고 관리도구는
운영자가 닫은 상태로 유지했다. 이미지 전환만 있는 경우 전투용 StaticData 입력 경로는 유지한다.
Python 집중 검사 12개, 번들 해소 C# 검사 2개, 필수 gate 8개가 통과했다.
Phase 2B gate는 unit 모드이며 이번 변경에서 별도 live PostgreSQL integration을 실행하지 않았다.
설치 화면의 직접 클릭 검증은 수행하지 않았다. `installation.receipt.json`, `sync-cases.receipt.json`,
`gates/required-gates.receipt.json`이 구분된 근거다.

## 동일 내용의 manager 중복과 기존 미확인 시즌 복구 (2026-09-16)

시즌 19의 manager는 결손이 아니라 2개였다. 고정 원본과 동기화 캐시의 원본 MemoryPack을
대조한 결과 레코드의 전체 필드는 Id, MonsterPreset, RankingGroupId이고 Id만 달랐다.
당시 장애/재개 이력이 중복 생성 원인인지는 자료만으로 확정하지 않는다.

- `SoloRaidManagerSelection`을 목록 생성과 공통 보스 가져오기에서 함께 사용한다.
  ID 이외 필드가 같으면 하나로 취급하고 가장 작은 ID를 대표로 선택한다.
  보스 구성 참조가 다르면 여전히 충돌이며, 원본 필드가 늘어나면 동등성 규칙 재검토 전까지 거부한다.
  특정 시즌 번호나 프로필 버전 예외는 없다.
- 해석기 변경 시 pack이 같아도 재검토한다. 기존 unresolved 항목이 resolved가 되는 경우
  새 시즌 추가 없이 이름·약점·이미지를 갱신할 수 있다. 이미 해소된 시즌의 메타데이터 보존은 유지한다.
- 실제 현재 고정 원본에서 시즌 19는 `베히모스 [P.S.I.D.]`, 기본 약점 `electric`으로 해소됐고
  로컬 이미지도 연결됐다. 다른 39개 시즌과 전투용 StaticData 경로는 그대로 유지했다.
- 동등 중복·입력 순서 독립·다른 구성 충돌을 포함한 materializer 합성 검사 20개와
  기존 미확인 항목 복구·이전 revision 유지 등을 포함한 동기화 API 검사 5개가 통과했다.
- 운영자가 관리도구를 닫은 뒤 API DLL/PDB를 백업·설치하고 새 목록 및 해석기로 전환했다.
  설치된 서비스에서 시즌 19 이름/약점/이미지 조회와 반복 unchanged, 이전 목록 참조를 확인했다.
  관리도구는 닫은 상태로 유지했다. 시즌 19 실게임 실행을 검증한 것은 아니다.

근거: `artifacts/season19-investigation-20260916/result.jsonl`,
`artifacts/season19-fix-20260916/{rehearsal,installation}.receipt.json`.

필수 회귀 gate 8개도 통과했다(Phase 2B는 unit 모드). 해석기 갱신 감지는 내용이 고정된
.NET apphost EXE가 아니라 실제 구현 DLL의 SHA-256을 사용한다.

## 에닉 우선 이미지 공급과 최신순 기본 정렬 (2026-09-19)

운영자 요청으로 2026-09-16의 로컬 전용 공급 순서를 변경했다. 현재 순서는
정확한 MonsterImage 이름의 `enikk.app/bosses/<name>.png` → 에닉에 없거나 유효한
PNG를 받지 못한 항목만 공식 설치본의 로컬 번들 추출이다. 캐릭터 이미지 경로는
이 변경의 대상이 아니다. 보스별 이름 추정이나 다른 보스 이미지 대체는 하지 않는다.

공개 GET은 인증·쿠키·프록시·리디렉션 없이 크기·시간을 제한하고 최대 네 개만
동시에 요청한다. 모든 결과는 기존 로컬 PNG 캐시에 저장하고 UI는 인증된 로컬
endpoint만 사용한다. 원격 성공 시 번들을 열지 않으며, 결손 이름만 묶어 번들을
추출한다. 양쪽 모두 실패하면 기존 시즌 이미지를 유지하고 신규 결손은 unresolved다.
원격 실패와 최종 공급원은 이미지별 receipt에 구분한다. 공급 정책의 변경은 이미지
입력 identity에 반영하여 기존 로컬 전용 캐시도 한 번 갱신한다. 동일 입력 반복은
기존과 같이 재다운로드·재추출 없이 unchanged다.

현재 42개 시즌 모두 에닉에서 확보했다(내용 hash 기준 40개). 이번 실제 갱신에서는
로컬 보충이 필요하지 않았다. 합성 검사 16건에서 에닉 우선, 결손/잘못된 PNG/접속
실패의 정확한 로컬 fallback, 양쪽 결손을 확인했고, UI 검사 10건이 통과했다.
솔로 레이드의 기본 정렬은 최신순이며 오래된 순도 선택할 수 있다.
실제 반복 동기화 unchanged, 기존 이름·약점·전투 입력 보존, 설치 파일·카탈로그
hash를 확인했다. 설치본은 다음 관리도구 실행부터 새 설정을 사용한다.
근거: `artifacts/boss-art-priority-20260919/`.
