# 공식 152 업데이트와 NLL 151 호환성 조사

> 2026-09-27 보관: 작성 당시의 기록이며 현재 작업 지시가 아닙니다. 현행 문서는 [문서 색인](../../README.md)에서 찾습니다.

2026-09-17. 최신 상태: **152 로컬 pack decode 및 목록 해석 완료, 설치·전투 검증 미실시**.
범위: 공식 설치본과 기존 실행 입력의 읽기 조사, 독립 폴더에서의 해석·추출.
게임 실행·DB 변경·동기화 게시·클라이언트 교체는 하지 않았다.

## 결론

- 공식 `C:\NIKKE`는 **152.8.11**, NLL의 선택된 복제본은 **151.8.5**다.
- 새 리소스의 카탈로그·이름 자료·기존 보스 이미지 표본은 현재 도구로 읽힌다.
- 새 `StaticData.pack`은 기존 151 gameconfig로 실패했으나, 새 공개 152 설정으로 복호화에 성공했다.
  두 salt가 모두 바뀌었다. 활성 동기화 설정은 아직 교체하지 않았다.
- 목록 대상 캐릭터는 200→202명, 최대 시즌 번호는 40→42다. 신규 보스 이미지 두 개도 로컬에서 추출했다.
  151에서의 전투 호환성 및 152 서버/클라이언트 전환 검증은 별도다.
  그림/이름 추출 성공을 새 보스·캐릭터의 전투 실행 성공으로 해석하지 않는다.
- 기존 NLL 실행 선택은 유지된다. 이번 조사에서 기존 실게임을 재실행해 검증한 것은 아니다.

## 실제 비교

| 항목 | 관측 | 의미 |
|---|---|---|
| Unity PlayerSettings의 bundleVersion | 공식 152.8.11 / NLL 151.8.5 | 실행 파일의 Windows 버전 정보는 Unity 엔진 버전이므로 게임 버전 대신 사용하지 않음 |
| UnityPlayer.dll | 양쪽 SHA-256 동일 | 엔진 바이너리 동일. 게임 코드 호환성을 보장하지 않음 |
| nikke.exe / GameAssembly.dll / nikkeBase.dll | 모두 길이·SHA-256 다름 | 콘텐츠 데이터만 바뀐 업데이트가 아님. NLL 복제본은 파생 설치본이므로 해시 차이 전체를 업데이트 변경으로 단정하지 않음 |
| global-metadata.dat | 양쪽 모두 0바이트 | 이 파일만으로 게임 타입/프로토콜 변경을 비교할 수 없음 |
| StreamingAssets/sd.bin | JSON 표 5개 중 ConfigGameTable만 변경 | 나머지 4개 표의 바이트 동일 |
| ConfigGameTable | 설정 키 2개 추가, 기존 키 삭제/값 변경 없음 | 장비 옵션 재료 관련 설정 증가. 이것만으로 해당 기능의 서버/전투 지원을 확정하지 않음 |
| 기본 Addressables catalog.db | 해시 변경, 기존 해석기로 테이블 8개 읽음 | 카탈로그 해석 가능. 모든 신규 번들의 151 로더 호환성은 미검증 |
| patch dp / saus catalog.ndb | 해시 변경, 각각 기존 해석기로 테이블 7개 읽음 | 현재 카탈로그 해석 경로 재사용 가능 |
| 새 saus 이름 자료 | 기존 추출 도구 통과 | 기존 151 데이터와 조합한 대조 검사에서 시즌 40개 모두 이름 해소 |
| 새 dp 이미지 | S26 이미지 한 개의 번들→Texture2D→PNG 추출 통과 | 이미지 추출 형식의 표본 호환. 신규 보스 이미지 연결이나 모든 이미지 인수는 아님 |

추가된 설정 키는 `MaterialEquipmentOptionDisposableFixID`, `MaterialEquipmentOptionID`다.
원본 값과 상세 자료는 문서에 포함하지 않는다.

## StaticData에서 확인한 차단 지점

아래는 새 upstream 설정 공개 전 조사 이력이다. 현재 해소 결과는 문서 마지막 절을 따른다.

실제 동기화 입력은 다음 파일이다.

`C:\Users\nlloperator\AppData\Local\Temp\com_proximabeta\NIKKE\StaticData.pack`

- 수정 시각: 2026-09-17 12:08:19 KST. 크기: 17,491,568바이트.
- SHA-256: `a119492898e5e5aec9e07ae9e52e88f0b483a5f595c9728dcc19a4ef9ccd36f0`.
- 게시된 기존 목록의 sourceStaticDataSha256와 다르며 조사 전후 해시는 동일하다.
- 설치된 시즌 해석기의 `--export-local-boss-season-catalog`에 새 pack과 기존
  `PhaseD151-v9/server/gameconfig.json`을 입력하면 `CryptographicException` /
  `System.Security.Cryptography.SymmetricPadding`에서 실패한다.
- 같은 해석기와 gameconfig에 기존 봉인된 151 pack을 입력하면 시즌 40개를 정상 해석한다.
  여기에 새 152에서 추출한 locale을 사용해도 시즌 40개 모두 이름이 해소된다.

즉, 실패는 새 시즌의 패턴·보스 속성 조립 이전인 **pack 복호화 단계**다.
버전별 암호화 설정 불일치 가능성이 높지만, 152용 설정을 확보·대조하지 않았으므로
어떤 salt/계층/포맷이 달라졌는지와 pack 자체의 유효성은 아직 확정하지 않는다.
소금값을 추정하거나 padding 오류를 무시해 진행하지 않는다.

캐릭터 동기화도 같은 `ReadLocalArchive`와 기존 gameconfig를 사용하므로 동일한 차단 조건을 갖는다.
실제 UI 버튼을 누르거나 활성 목록을 교체하지 않고 해석 단계만 독립 실행했다.
이번 40개 결과는 **기존 151 자료의 대조 결과**이며 새 자료의 최대 시즌 번호가 아니다.

또한 `.lcv.dat`는 수정 시각과 내장 참조가 오래된 150 자료였다.
이 파일을 현재 리소스 버전의 권위로 사용하지 않는다. 이번 조사에서 152의 공식 리소스
버전 번호는 확정하지 않았으며 기존 Epinel 설정의 `653`을 새 버전 값으로 재사용하지 않는다.

## 다음 작업 순서

1. **152용 데이터 해석 설정 확보·대조**
   완료: 아래 12:32 KST upstream 공개 후 decode 결과 참조.
   공개 upstream 설정 또는 승인된 로컬 정적 자료에서 근거를 확보한다.
   공식 로그인·토큰·통신 가로채기나 메모리 주입을 사용하지 않는다.
   기존 151 설정은 유지하고 조사 후보에서 새 pack의 정상 해석을 먼저 확인한다.
2. **신규 콘텐츠와 데이터 형식 비교**
   캐릭터·스킬·시즌·보스 행동/속성/QTE/FX 참조의 추가·변경 및 필드 호환성을 비교한다.
   목록·이름·이미지 공급 가능 여부와 실제 전투 실행 가능 여부를 각각 판정한다.
3. **151 재사용 또는 152 실행 환경 전환 선택**
   기존 코드로 해석되는 기존 형식 콘텐츠만 자산 참조와 실행 구성을 확인하여 후보로 만든다.
   새 클라이언트 코드/메시지/전투 기능을 요구하면 별도 152 복제본과 서버 호환성 작업이 필요하다.
   버전 문자열만 바꿔 통과시키거나 공식 설치본을 NLL 실행 대상으로 삼지 않는다.
4. **독립 후보 검증 후 설치·사용자 실게임 인수**
   공통 파이프라인으로 처리하고, 기존 계정 revision·실행 bundle을 보존한다.
   정적 해석 결과만으로 설치 완료나 실게임 성공을 선언하지 않는다.

Epinel 업데이트는 새 설정·호환성 수정의 공급원이 될 수 있지만,
기존 151 실행을 유지하는 데 필요한 선행 조건은 아니다.

## 증거와 제한

로컬 상세 근거: `artifacts/update-compatibility-20260917/`.

- `metadata.private.json`: 두 설치본 버전, 선택 파일 해시, sd.bin 표 비교, pack 변경.
- `boss-discovery.log`: 새 pack의 복호화 실패.
- `baseline-control/catalog.json`: 기존 pack + 새 locale 대조 결과.
- `locales.log`, `dp-schema.json`, `saus-schema.json`, `*-addressable-schema.json`: 리소스 해석 결과.
- `image-sample/receipt.json`: 기존 보스 이미지 표본 1개 추출 성공.
- `receipt.json`: pack 안정성·활성 구성 해시 및 조사 범위.

해석·이미지 추출 결과는 Git 제외된 로컬 폴더에만 남긴다.
첫 시도의 sandbox 읽기 제한과 이미지 검사 입력 폴더 배치 오류는 조사 도구 실행 조건을
바로잡아 재실행했다. 제품 결함이나 152 형식 비호환으로 집계하지 않는다.
전체 대용량 store 검산·DB 기동·실게임·새 콘텐츠 게시·설치 변경은 수행하지 않았다.

## 152 decode 후속 — 2026-09-17

당시 상태: **152 decode 미완료 — 새 pack에 맞는 메타데이터 미확보**. 아래 upstream 공개 후 해소됐다.
독립 해석기는 준비됐지만 개별 승인된 익명 요청 3회 모두 메타데이터를 받지 못했다.
추가 요청 승인은 남아 있지 않으며 자동 재시도·설치 변경을 하지 않는다.

- 공개 Epinel main을 재확인했으며 여전히 151.8.5 설정이었다.
- 설치된 151/152 정적 파일의 기존 salt 표현 및 설정 자산을 대조했지만 152용 값을 확보하지 못했다.
  기존 Player 로그에서도 salt 필드 라벨은 없었다. 로그 원문·계정 정보를 복사하지 않았다.
- Epinel의 `AdminCommands.UpdateResources`에서 salt 공급원이
  `https://global-lobby.nikke-kr.com/v1/get-static-data-pack-info-mpk`임을 확인했다.
  공식 API 자동 요청은 현재 보안 경계에서 제외하므로 자동으로 호출하지 않았다.
- 독립 오프라인 해석기로 기존 151 pack의 AES-CBC → 서명 확인 → AES-CTR → ZIP CRC 검사를 통과했다.
  ZIP 항목 9,442개이며, 새 pack은 **outer AES-CBC padding**에서 실패한다.
  따라서 MemoryPack 표 해석 이전의 바깥 암호화 계층부터 설정이 맞지 않는다.
- 단일 익명 POST 수집 후보를 준비했다. 쿠키·인증·프록시·리디렉션·TLS 검증 우회를 사용하지 않고,
  응답 크기를 제한하며 메타데이터의 파일 크기/해시가 로컬 pack과 같아야 다음 단계로 진행한다.
  운영자가 이번 메타데이터 요청 1회를 명시적으로 승인했고 실행했으나 HTTP 오류로 실패했다.
  최초 오류 처리기가 상태 번호를 누락했으므로 번호 기록을 보완했다. 자동 재시도하지 않았다.
  공식 hostname의 DNS는 외부 주소이며 해당 hosts 매핑은 없는 것을 확인했다.
- 합성 메타데이터 정상 해석과 중복 필드·잘린 응답·다른 host·인증 정보 포함 URL 거절 검사를 수행했다.

독립 도구·검사·151 대조 결과는 Git 제외 경로 `artifacts/decode-152-20260917/`에 있다.
152 설정을 확보한 뒤에도 정상 서명과 ZIP CRC 확인을 통과해야 decode 완료로 기록한다.

승인은 로그인·세션·다른 API·CDN 자동 취득·runtime outbound 허용으로 확대하지 않는다.
첫 요청의 승인 범위는 소비됐으며 상세는 `first-request.receipt.json`에 기록했다.
추가 승인된 동일 요청도 HTTP 406으로 실패했다. 이후 원본 Epinel의 정적 초기화까지 대조하여
초기 수집기에 `Accept: application/octet-stream+protobuf`가 빠졌고 TLS 선택도 다름을 확인했다.
어느 차이가 실패 원인인지는 미확정이다. Epinel처럼 Accept와 TLS 1.1을 명시하되 인증서/hostname
검증을 유지하는 후보를 준비했다. 운영자가 이 방식의 요청 1회를 추가 승인하여 실행했으며
HTTP **567**을 받았다. 메타데이터는 저장되지 않았다. 시스템 TLS 정책은 변경하지 않았다.

최종 요청 이력:

| 요청 | 개별 승인 | 결과 |
|---|---|---|
| 첫 익명 POST | 승인 | HTTP 오류. 초기 오류 처리에서 상태 번호 누락 |
| 동일 POST, 오류 기록 보완 | 승인 | HTTP 406 |
| protobuf Accept + TLS 1.1, 인증서 검증 유지 | 승인 | HTTP 567 |

HTTP 오류만으로 계정 인증이 필수라거나 API가 폐기됐다고 단정하지 않는다.
마지막으로 사용자 레지스트리의 StaticData/pack-info/salt/resource-host/game-config 관련
이름만 조회했으나 해당 후보를 찾지 못했다. 레지스트리 값·계정 인증 캐시는 읽거나 변경하지 않았다.

남은 입력은 새 pack의 크기·SHA-256과 일치하는 StaticData 메타데이터다.
공개 Epinel 152 설정 또는 별도로 승인된 경로에서 그 입력을 확보하면 준비한 해석기로
서명·CRC·필수 표 존재를 확인하고, 그다음 MemoryPack 표 구조·신규 콘텐츠 비교를 진행한다.
이번 요청 3회를 새로운 공식 API 요청·다른 endpoint·로그인·TLS 검증 우회 허가로 재사용하지 않는다.

최종 로컬 기록은 `artifacts/decode-152-20260917/decode-status.json`,
`epinel-style-request.receipt.json`, `baseline-decoded/receipt.json`을 따른다.

## 로컬 메타데이터 재조사 — 2026-09-17

운영자의 로컬 메타데이터 확인 요청에 따라 숨김 경로·사용자 hive·중첩 라우팅 캐시까지 범위를 넓혔다.
당시 결론: **로컬 메타데이터 파일은 존재한다. 그러나 확인한 항목에서 152 StaticData의 salt 쌍과
pack 크기/해시를 묶은 안내 정보는 아직 확보하지 못했다.** 모든 로컬 파일에 없다는 판정은 아니다.

| 대상 | 이번 관측 |
|---|---|
| `nikke_Data/il2cpp_data/Metadata/global-metadata.dat` | 0바이트. StaticData 안내 응답과는 다른 종류의 메타데이터 |
| `StreamingAssets/aa/catalog.db`, patch `catalog.ndb` | 리소스/번들 연결용 카탈로그. 앞선 해석 검사 통과 |
| `Unity/com_proximabeta_NIKKE/.lcv.dat` | 기존 150 참조가 남은 버전 관리 자료. StaticData/salt 라벨 없음 |
| 사용자 `.patch_state.json` | coreRevision·subEntryRevisions·existingGroups의 설치 상태 구조 |
| `com.shiftup.addressables` | 이전 core/dp/fd 카탈로그 캐시. 관측한 파일 이름/시각은 150 자료 |
| 152 bg-downloader 로그 | StaticData/PackInfo/salt 라벨 없음. 로그 원문을 산출물에 복사하지 않음 |
| `StreamingAssets/lss/AppInfo.lsc` | 기존 NKDB 도구로 해석. AppInfo 표에 Key와 언어별 열이 있는 구조 |
| 실제 사용자 HKCU | NIKKE 설정 키 존재, 값 이름 112개. StaticData/pack-info/salt 이름 후보 없음 |
| HKCU의 중첩 RouteConfigJsonDictionary | 150/151 route_config 캐시 2개. 중첩 JSON의 필드 이름을 확인했으나 StaticData/PackInfo/salt 필드 없음 |
| 숨김 `.tiny_cache/Game_16601.local` | 약 1.58MB 비JSON 바이너리. 평문/UTF-16 라벨 검사에는 해당 정보 없음. **형식 미해석이므로 내용 부재를 입증하지 못함** |

앞선 HKCU 조사는 sandbox 환경에서 대상 키가 보이지 않은 것을 메타데이터 후보 없음으로
기록한 한계가 있었다. 이번에는 실제 프로젝트 사용자 컨텍스트의 읽기 전용 조회로 정정했다.
혼합 설정의 전체 값은 출력/복사하지 않았고, 라우팅 하위 필드만 구조를 조사했다.
인증·계정 필드 값은 사용하지 않았으며 레지스트리·설치 파일·DB를 변경하지 않았다.
이번 재조사에서는 외부 요청을 수행하지 않았다.

근거: 같은 decode 폴더의 `appinfo-schema.json`, `local-cache-scan.private.json`,
`route-cache-schema.json`, `route-cache-fields.json`, `local-metadata-status.json`.

## Upstream 152 공개 후 로컬 decode 완료 — 2026-09-17

한국 시간 **12:32:11**에 공개된
[Epinel 152.8.11 커밋](https://github.com/EpinelPS/EpinelPS/commit/61f052830f31443e3cf78917d292a93950e69ec1)의
gameconfig를 해당 commit SHA로 고정하여 독립 조사 폴더에 저장했다.
실제 데이터는 이미 로컬에 있던 pack을 그대로 사용했다. 공식 API 추가 요청은 하지 않았다.

### 검증 결과

- 새 설정의 salt1·salt2 모두 기존 151과 다르다. 새 값으로 AES-CBC, 기존 공개키를 이용한
  서명 검사, AES-CTR, 모든 ZIP 항목의 CRC, 필수 표 존재 검사를 통과했다.
- pack SHA-256은 앞서 확인한 `a119492898e5e5aec9e07ae9e52e88f0b483a5f595c9728dcc19a4ef9ccd36f0`과 같다.
- decoded ZIP SHA-256은 `42611495f81734528e8d9f3b4286ed2f8531ad0d75be087a1fb8ef39f9c32367`이다.
- ZIP 항목은 9,442→9,580개: 추가 138, 삭제 0, 공통 항목 중 변경 170, 동일 9,272개다.
  ZIP 항목 수를 캐릭터 수나 서로 다른 표 종류 수로 해석하지 않는다.
- 기존 목록 해석기에서 새 보스 관련 표 해석과 시즌 42개 모두의 이름·기본 약점 해소가 통과했다.
- 같은 임시 합성 식별 키로 151/152 캐릭터 후보를 각각 해석했다. 도감 대상 필터 기준
  200→202명, 추가 2명, 제거 0명이다. 실제 계정 식별 비밀·운영 DB는 사용하지 않았다.

| 추가 목록 | 해석 결과 |
|---|---|
| 니케 | 길티 : 마이티 바니, 신 : 스위프트 바니 |
| 시즌 41 | 리버렐리오 바디 [H.S.T.A.] — 기본 약점 수냉 |
| 시즌 42 | 앨트루이아 [P.S.I.D.] — 기본 약점 전격 |

시즌 번호는 **로컬 자료에 수록된 번호**이며, 현재 공식 서비스에서 두 시즌 모두 개방됐다는 뜻이 아니다.
41/42 이미지의 원본 참조를 새 dp 카탈로그에서 연결하고 두 PNG 모두 오프라인 추출했다.
신규 니케 이미지 추출과 실제 전투는 이번 결과에 포함하지 않는다.

### 변경 범위와 남은 일

- 공개 152 설정의 ResourceDataPackVersion 값은 여전히 `653`이다. 이는 확인한 upstream 설정값이지
  앞서 오래된 `.lcv.dat`에서 읽은 숫자나 별도 공식 리소스 응답을 검증한 값이 아니다.
- upstream은 gameconfig 외 데이터 모델·protobuf와 장비 옵션 endpoint도 변경했다.
  데이터 모델에는 새 이벤트 표와 `DmgReductionDebuffDecrease` 함수 종류가 추가됐다.
  목록 해석 성공만으로 모든 새 스킬을 151 client가 실행할 수 있다고 판정하지 않는다.
- 활성 gameconfig·목록·DB·실행 bundle·공식 설치본은 변경하지 않았다. Git commit/push도 하지 않았다.
- 후속은 별도 후보의 동기화 입력 연결, 스킬/보스 전투 참조 및 필요한 runtime 호환성 확인이다.
  공통 파이프라인을 유지하고 새 시즌/캐릭터를 운영 목록에 자동 게시하지 않는다.
- 숨김 `Game_16601.local`의 형식은 여전히 미해석이다. 이번에는 그 캐시에서 salt를 찾은 것이 아니라
  **공개 설정과 로컬 pack의 조합**으로 목적을 달성했다.

최신 근거는 `artifacts/decode-152-20260917/`의 `upstream-152.provenance.json`,
`decoded-152/receipt.json`, `content-diff.private.json`, `bosses-152/catalog.json`,
`characters-151/metadata.private.json`, `characters-152/metadata.private.json`,
`boss-images-152/receipt.json`, `decode-status.json`이다.
이전 `decode-status.before-upstream.json`은 해소 전 실패 이력으로 보존한다.

## 프로젝트 152 적용 준비 — 2026-09-17

### 요구와 현재 선택

운영자는 관리도구 목록뿐 아니라 **NLL 프로젝트의 152 적용**을 요청했고 공식 런처를 종료했다.
공식 설치본 `C:\NIKKE`는 읽기 입력으로만 사용한다. 기존 151은 **152 배치 후 D:에 보관**한다.
현재 활성 선택은 여전히 `PhaseD151-v10`이며, 152의 설치·실게임 완료를 주장하지 않는다.

### 준비 및 검증 완료

| 항목 | 결과와 범위 |
|---|---|
| 152 독립 사본 | `C:\NLL\Clients\NIKKE-152.8.11-ResourceProbe`, 1,082파일 / 20,890,819,394바이트. 복사 전 manifest와 사후 source/copy 모두 동일. 공식 설치본 변경 없음 |
| 복사 확인서 복구 | 첫 시도는 모든 파일 복사 후 최종 단계에서 실패했으며 사본을 보존했다. 원인 코드가 일반화되어 정확한 실패 지점은 미확정이다. 재복사 없이 전체 대조를 다시 통과하여 별도 확인서를 생성했고 실패 기록은 유지했다 |
| 서버 | 기존 NLL 변경을 보존한 별도 `.external/EpinelPS-152-candidate`에 upstream `61f0528` 버전 변경 7파일을 적용. build 및 서버 테스트 142개 통과 |
| 실행 버전 연결 | 152 exe와 decoded archive를 한 쌍으로 추가. 버전/진행도 합성 검사 15개 통과. bootstrap은 manifest의 빌드/실행 파일 hash를 읽으며 151·152 모두 inspect-only 통과 |
| 공통 FX 입력 | 새 사본의 embedded/inner/outer catalog 및 chunk index로 입력 계획 생성. 152는 별도 baseline 저장 경로를 사용하도록 준비; 기존 151 journal을 변경하거나 초기화하지 않음 |
| 서버 locale | 새 사본에서 필요한 4개 원본을 별도 staging으로 추출·검증. 음성 설정 변경 없음 |
| 시즌 목록 | 42개 이름·기본 약점·로컬 이미지 해소. 기존 40개 값 유지, 반복 동기화 unchanged. 활성 catalog pointer는 변경하지 않음 |
| 캐릭터 목록 | 202명 후보. 기존 UID 유지, 추가 2명, 반복 추가 0명. 운영 DB 사전 dump 후 정상 importer로 불변 catalog snapshot 추가. 계정 소유/육성 revision 변경 없음. 활성 presentation 교체 전이며 신규 portrait 2개는 미확보 |
| 필수 회귀 | 변경 전/후 저장소·Phase 0·Phase 2B(2A1/2A2 포함, unit 모드)·3A·3B0·3B1·3B2·Actions의 8개 gate 모두 통과. 실제 PostgreSQL 통합은 별도 lifecycle 검사와 구분 |
| PostgreSQL 통합 | 별도 폐기 DB에서 117/117 통과. 새 materializer의 capture/persist/restore 41개 검사, DB 재시작 checkpoint 및 종료/정리 확인. 운영 DB·게임을 사용하지 않음 |
| 기존 실행 보존 | 공통 bundle reader로 활성 151의 선택 및 파일 pin 일치 확인. 게임 실행은 하지 않음 |

사본 manifest SHA-256은
`abeeb019c10bbf1c03c10d64888d3d09207a02739319f88882dbbb223e5ddb88`이다.
준비 산출물과 원본·복호물은 Git 제외 경로에만 둔다. commit/push는 수행하지 않았다.

DB 통합 첫 실행에서 기존 합성 catalog helper에 추가된 선택 인수 `characterSnapshotTag`를
reflection 호출부가 빠뜨려 74개가 `TargetParameterCountException`으로 실패했다.
`PostgreSqlLocalGameStateTests` 호출에 `Type.Missing`을 전달하여 원래 기본값을 사용하도록 수정했다.
이는 fixture 호출 수정이며 제품 계정/저장 코드 변경이 아니다. 첫 실행의 DB 종료는 30초를 넘겼지만
finally의 정상 중지와 정리가 완료됐다. 재검사는 종료 대기 상한을 60초로 두고 전체 통과했다.
실패 기록 `490d1f9165b541f8b575ec30fb6148dd`와 성공 기록 `d7cc2dfd134d4ef0b1b5ea42df7a84ca`를
`artifacts/stabilization/lifecycle-postgresql/`에 구분해 보존한다.

### 실제 데이터 변경: 시즌 34

등록된 S7·9·10·25·26·27·29는 새 데이터에서도 기존 target observation과 정확히 1개가 일치했다.
S34는 일치 0개였다. 같은 공통 discovery를 151/152에 적용하여 다음 변경을 확인했다.

- 대상 projection의 monster 역할 행은 129→130, 전체 행은 183→184로 증가했다.
- skill 12의 hurt 연결 1개가 추가되어 root function은 24→25, 전체 function closure는 33→34다.
- 연결된 QTE 2개의 monster 참조 집합이 각각 3→6개로 늘었다.
- 속성·속성 쉴드 discovery는 동일하다. 이는 부팅/음성의 시즌 예외를 추가할 이유가 아니다.

151의 trusted hash를 임의 갱신하지 않고 **기존 공통 조립기로 새 후보를 생성**했다.
`season34-candidate-2/onboarding-verified-candidate.receipt.json`에서 5속성 변환이 모두 통과했다.
새 profile hash는 `6afc3d848dd49e5e46f99e9fa2aa7cc07c07c2118408387854395cd4c50ed051`이다.
이후 공통 native 조립기로 **152 저장소용 FX chunk 3개**를 준비했고, 5속성 delivery 검사를 통과했다.
원본 chunk index·압축 길이 round trip·원본 비변경을 확인했다. 클라이언트 store에는 쓰지 않았다.
결과는 `season34-delivery/delivery-preparation.receipt.json`이며 DB 등록·runtime 활성화와는 구분한다.
활성 registry·151 전달 구성·계정 DB binding은 교체하지 않았다.
앞선 입력/출력 폴더 겹침으로 실패한 `season34-candidate`는 실패 이력이며 사용할 후보가 아니다.

### 과거 조사: 152 리소스 버전 안내 — 필수 입력 판단 철회

운영자가 승인한 정확한 공개 URL
`https://cloud.nikke-kr.com/prdenv/152-b29f01fccd/StandaloneWindows64/pck/latest-653.txt`를
익명 GET 1회 요청했고 **HTTP 404**였다. redirect/retry/쿠키/로그인을 사용하지 않았다.
이는 pack 복호화 실패가 아니라 **실행 리소스 버전 안내의 결손**이다.

공개 HEAD `81aef73e426e9b42820016317bba66ff27579ad4`까지 재확인했지만 152 gameconfig는
`61f0528`과 같았고 ResourceDataPackVersion은 여전히 653이었다. 새 commit의 인터넷 연결 실패 처리
수정은 이 URL을 해소하지 않는다. 로컬 `.patch_state.json`에는 설치 revision이 있지만 안내 파일에
필요한 모든 version tag/aggregate 값은 없다. 오래된 `.lcv.dat`는 150 자료다.
core catalog의 내부 경로·TableVersion, AppInfo의 7개 표시/권한 키, 확인한 로컬 패치 로그에서도
현재 안내 값을 확보하지 못했다. 모든 로컬 파일에 부재한다는 결론은 아니다.

다른 버전의 안내 파일이나 추정한 버전 번호를 152 입력으로 사용하지 않는다.
아래 순서는 이 문단 작성 당시 계획이며, 안내 파일 확보 선행 조건은 아래 정정으로 대체한다.

1. 152 서버의 resource header/core version과 cache를 연결하고 새 bundle을 봉인한다.
2. 기존 보스들의 152 asset/FX 전달과 불변 DB binding을 구성한다. 특히 S34는 위 새 후보를 사용한다.
   `ClassicSoloRaidRuntimeState`의 현행 완료 기록 상속은 150→151만 처리하므로,
   151→152 전환의 기존 완료 기록 보존도 구현·검증해야 한다. active run을 옮기거나 과거 revision을
   덮어쓰지 않는다. 이 단계까지 끝내기 전에 bundle 선택만 152로 바꾸지 않는다.
3. 관리도구 package·목록·공통 실행 설정을 함께 적용하고 DB 연결/실행 준비를 확인한다.
4. 152 배치 완료 후 151의 참조를 점검하고 D: 복사 검증·원본 정리를 수행한다.
5. 사용자가 게임을 실행하여 검증한다. 준비/자동 검사/설치/실게임 상태를 구분한다.

운영자 요청에 따라 `SECURITY_BOUNDARY.md`의 151 한정 정적 수집 규칙을 정정했다.
과거 작업의 제한을 향후 모든 버전의 반복 승인 요건으로 취급하지 않는다.
공식 로그인·계정 API 또는 runtime 중 외부 통신으로 확대하지 않는다.

근거: `artifacts/apply-152-20260917/`의 `clone-recovery.receipt.json`,
`server-preparation.receipt.json`, `server-tests.log`, `bootstrap-binding-checks.json`,
`catalog-preparation.receipt.json`, `character-preparation.receipt.json`,
`existing-boss-observations.receipt.json`, `season34-discovery*.json`,
`locales-stage.receipt.json`, `resource-header-http.json`,
`active-151-preservation.receipt.json`, `after-gates/required-gates.receipt.json`,
`postgresql-integration.receipt.json`, `application-status.json`.

### Epinel 실행 방식 대조와 정정 — 2026-09-17

사용자는 Epinel과 다른 구현을 사용하는 이유를 물었다. 공개 upstream
`81aef73e426e9b42820016317bba66ff27579ad4`의 `GetResourceHosts2`는
`BaseUrl`과 요청의 `Version`만 반환한다. NLL의 과거 150 대응 코드가 추가한
`CoreVersionMap`·`DataPackVersionMap`을 152에서도 필수로 간주한 것은 잘못된 전제였다.
152 후보 응답은 upstream과 동일하게 정정했으며 `ResourceCoreVersion` 설정을 넣지 않는다.
`latest-653.txt`의 404는 관측 사실이지만 **152 설치를 막는 근거로 사용하지 않는다**.
실제 게임 기동 성공은 이 코드 대조만으로 판정할 수 없으며 설치 후 사용자 확인이 필요하다.

승인된 익명 `resourcehosts2` 조사에서는 일반 요청과 Epinel TLS/DNS 처리 재현 모두
HTTP 567/EdgeOne 응답으로 메타데이터를 얻지 못했다. 추가 요청을 계속할 필요가 없어 중단했다.
반복 승인 범위는 `SECURITY_BOUNDARY.md`에 반영했으며 계정·로그인 접근으로 확대하지 않았다.

- 현재 설치본의 별도 빌드에 있던 공통 profile v4 지원을 152 소스에도 연결했다.
  resource 응답과 profile v1~v4 지원을 포함한 SelectedManager 검사 **147개 통과**.
- 등록된 8개 시즌을 공통 조립기로 다시 생성하고 각 5속성 delivery 검사를 통과했다.
  S10은 target observation은 같아도 QTE 참조가 6→7로 바뀌었다. S34도 실제 전투 입력이 바뀌었다.
  S26은 기존 profile v1에 skill/behavior 근거가 없어 새 profile과 같은 기록 집합이라고 추정하지 않는다.
- S7·9·25·27·29는 전체 archive 출처 hash를 제외한 전투 입력 동일성을 확인하고,
  새 불변 profile binding을 기존 raid snapshot에 연결하도록 했다. 과거 row를 덮어쓰지 않는다.
- 151→152 완료 기록 상속은 정확한 이전 빌드·exe와 같은 계정/raid snapshot/약점에만 적용한다.
  진행 중 run은 이관하지 않으며 152의 명시적 기록이 이미 있으면 그것을 우선한다.
  S10·26·34의 이전 기록은 DB에 보존하지만 새 구성으로 자동 상속하지 않는다.
- `PhaseD152-v1`은 아직 선택 전 후보다. 안내 파일 수집 대신 로컬 152 자산, 정상 DB 연결,
  공통 실행 준비와 설치를 완료하는 데 집중한다. 향후 업데이트 자동화는 이번 작업 범위 밖이다.

이 단계의 근거는 `server-final-tests.log`, `remaining-boss-deliveries.receipt.json`,
`registration-plan.private.json`, `bundle-final.receipt.json`이다. DB 통합과 실제 설치 결과는
후속 확인서로 구분하여 기록한다.

### 152 설치 완료 — 2026-09-17 14:53 KST

- 활성 runtime은 `C:\NLL\Runtime\PhaseD152-v1\bundle.private.json`이다.
  SHA-256 `48be798b05bcfe3b5f9326516e14742ba287a9bdc1126d57958994900652f2b1`.
- 기존 승인된 Epinel DLL과 client-local 인증서 overlay를 **152 복제본에만** 적용했다.
  방화벽 22개 중 복제본 실행 파일 6개의 경로만 152로 바꿨으며 공식/공유 프로그램 16개는
  cold 상태에서 계속 비활성이다. 게임 실행 수명주기에서만 기존대로 활성·복구한다.
- 152 FX 원본 저장소를 설치 시 한 번 검증하여 별도 baseline/journal에 등록했다.
  정상 실행의 전체 6.6 GiB 재검사나 구버전 journal 초기화를 추가하지 않았다.
- 기존 8개 보스의 새 불변 DB binding을 등록하고 registry를 함께 전환했다.
  실제 설치본에서 **8개 × 5속성 = 40개** 실행 준비·DB binding 검사가 통과했다.
- 운영 계정 입력으로 S26·S34를 `ValidateOnly` 실행하여 `validated_not_started`와
  progression 보존을 확인했다. 게임·Epinel 서버 실행과 실게임 성공을 의미하지 않는다.
- 관리도구 API/의존 파일, 니케 presentation 202명, 시즌 catalog 42개를 설치했다.
  이전 catalog revision과 이미지 조회를 유지했고 19·41·42 이미지 조회를 확인했다.
  신규 니케 portrait 2개는 아직 미확보이며 목록/이름/속성 데이터와 구분한다.
- 운영 DB 사전 dump와 변경 전 파일을 `installation-backup/`에 보관했다.
  새 runtime snapshot/binding 외 계정·육성·진행도 등 기존 테이블의 행 수/내용 digest는
  설치 전후 동일했다. DB는 정상 종료했고 관리도구는 닫힌 상태로 두었다.
- 서버 147개, 저장/복원 58개, 실제 폐기 PostgreSQL 통합 117개 및 재시작/정리,
  필수 8개 source gate를 통과했다. package publish가 만든 RID lock 차이는 일반 restore로
  해소했으며 NuGet 취약성 서버 연결 실패 때문에 마지막 gate 프로세스에서만
  `NuGetAudit=false`를 적용했다. 영속 설정을 바꾸거나 취약성 조회 성공을 주장하지 않는다.

이 설치 시점의 pipeline configuration은 `artifacts/apply-152-20260917/final-configuration.private.json`,
SHA-256 `f8e914d3c6048b3436449ca9e004deffed711101eade7e4ac87068c46a7a74a1`이다.
설치 근거는 `installation.receipt.json`, `installed-preparation.receipt.json`,
`installed-rehearsal.receipt.json`, `database-bindings.receipt.json`,
`data-after-install.json`, `postgresql-migration-success.receipt.json`,
`final-gates/required-gates.receipt.json`이다. **사용자 실게임 검증은 남아 있다.**

### 151 보관 완료

152 설치 후 구버전 클라이언트 1,244파일 / 20,430,992,968바이트를
`D:\NikkeLocalLab\Backups\client-151-archive-20260917-01\NIKKE-151.8.5-ResourceProbe`로 복사했다.
모든 파일의 크기·SHA-256 대조, 현재 runtime/pipeline/firewall의 구버전 참조 부재,
cold 상태와 정확한 양쪽 경로를 확인한 뒤 C:의 151 사본을 제거했다. 약 19.03 GiB를 확보했다.
151 runtime v9/v10과 cache·journal·원래 profile·계정 DB 이력은 그대로 보관한다.
복구 시 D:에서 직접 실행하지 않고 원래 C: 경로로 복원한 뒤 서로 맞는 선택을 적용해야 한다.
확인서는 `archive-151.receipt.json`, 전체 파일 manifest와 복원 안내는 D:의 해당 부모 폴더에 있다.

### 설치 후 시즌 41 불러오기 실패 — 2026-09-17

사용자가 관리도구에서 시작한 리버렐리오 바디 [H.S.T.A.] 불러오기는
15:11 KST `boss_behavior_graph_not_unique`로 실패했다. 이름·수냉 약점·이미지와
152 StaticData 대상 해석은 완료됐지만 행동 트리 검사에서 멈춰 registry에는 등록되지 않았다.

읽기 조사 결과, 새 152 server cache에 보존했던 **150.6.b15 외부 행동 번들 한 개**에
행동 트리는 567개 있지만 시즌 41이 요구하는 트리는 **일치 0개**였다. 이 오류 코드는
중복뿐 아니라 0개에도 사용되어 이름만으로는 원인을 구분할 수 없었다.
`invoke-nll-boss-onboarding.ps1`은 캐시의 행동 번들만 순회하며, FX와 달리
현재 클라이언트의 행동 번들을 취득하는 경로가 없다. 기존 8개 시즌의 준비 검사 통과는
신규 시즌 41의 불러오기 성공을 보장하지 않는다. 152 배치에 구버전 행동 입력을 남긴 것이
이번 실패 원인이다. 현재 152 행동 입력 연결을 보완해야 하며 이번 상태 조회에서는 운영 구성을 변경하지 않았다.

근거: `artifacts/apply-152-20260917/season41-status/cached-behavior.receipt.json`,
해당 UI 작업의 `job.json`·`failure-code.txt`. 실제 전투 모델 로딩/실게임 성공은 미검증이다.

### 시즌 41 행동 입력 수정 — 2026-09-17

`NativeBehaviorExport`는 봉인된 현재 embedded/inner catalog가 가리키는 외부 행동 번들을
유일하게 선택하고 연결된 outer catalog와 native chunk index로 필요한 청크만 읽는다.
`acquire-nll-boss-behavior.py`는 native input plan hash별 캐시를 사용한다. 현재 입력이
없거나 변하면 과거 server cache로 우회하지 않는다. 후보에는 원본 번들과 취득 확인서를
함께 봉인하고, 공통 실행기는 전달 seal에서 행동/FX 원본을 각각 확인한다.
시즌·프로필 버전별 예외, 원본 행동 트리 수정, 공식 설치본 변경은 추가하지 않았다.

현재 152 번들에서 행동 트리 574개, S41 일치 1개·노드 371개(비활성 25개)를 확인했다.
S41 5속성 후보 생성과 S26 동일 경로의 5속성 생성이 통과했으며 S26에서는 캐시를 재사용했다.
관리도구에 설치된 백엔드 서비스로 새 S41 작업을 요청해 정상 완료했다. 기존 실패 이력은
보존했다. DB의 불변 콘텐츠 binding과 공통 profile을 등록했으며 기존 계정·육성·진행도
테이블의 행 수·내용 digest는 전후 동일하다. 등록 후 5속성 준비 상태는 모두 `ready`다.

카탈로그 도구 281개, 취득 cold/warm·변조·구버전 대체 방지 4개, 후보 13개,
coordinator 행동/FX closure 17개 및 필수 8개 source gate를 통과했다.
NuGet 취약성 서버 연결 문제는 이전과 같아 gate 프로세스에만 `NuGetAudit=false`를
적용했다. TLS 인증서 검사는 sandbox 권한으로 실패한 2건을 실제 운영자 환경에서 다시
실행하여 전체 281개 통과를 확인했다. 게임 실행·실제 전투 모델 표시의 성공을 뜻하지 않는다.

근거는 `artifacts/apply-152-20260917/behavior-fix/` 아래
`current-behavior.receipt.json`, `season41-candidate/`, `season26-candidate/`,
`ui-service-job.receipt.json`, `ui-service-result.json`, `installed-preparation.receipt.json`,
`data-before.json`, `data-after.json`, `catalog-tests.log`, `gates/required-gates.receipt.json`이다.

수냉(원본 약점)·철갑(보정 FX)의 실제 계정 `ValidateOnly`도 `validated_not_started`,
`progressionPreserved=true`로 통과했다. 수정 설정을 활성화했고 UI catalog는 S41을
`processed`로 표시한다. 현재 활성 설정은 `behavior-fix/configuration.private.json`,
SHA-256 `c4c5337787974fb01f0d7c10a03d5efa0c0390e99b8a0e4de0a06a762df8a1d8`이다.
`installed-rehearsals.receipt.json`, `publication.receipt.json`, `installation.receipt.json`을
추가 근거로 보관한다. DB는 정상 종료했고 관리도구는 닫힌 상태다. 게임은 실행하지 않았다.

### 사용자 실행 4/7 실패: 리소스 안내 파일 공급 누락 — 2026-09-17

S41 등록 후 사용자 실행에서 `Catalogue resource patch upgrade` 4/7에
`System Error`가 나타났다. 보존한 Player 로그의 인과 순서는 다음과 같다.

1. `ResGetResourceHosts2` 응답 `Success`.
2. `GetVersionAsync`가 현재 응답 BaseUrl 아래 `pck/latest-655.txt` 요청.
3. `HttpRequestException: 404 (Not Found)`.
4. `DownloadPatch - Initialize failed`로 초기화 중단.

따라서 이번 직접 실패 지점은 보스 행동/전투 로딩 전에 수행하는 리소스 버전 안내 조회다.
실행 cache의 정확한 요청 파일은 없고 해당 디렉터리만 존재한다. 설치 서버의
`GetResourceHosts`는 `BaseUrl=GameConfig.Root.ResourceBaseURL`, `Version=req.Version`만
반환한다. 설정에는 data-pack `653`이 남아 있지만 현재 이 응답 메서드는 그 값을 사용하지
않으며 실제 클라이언트는 `655`를 요청했다. `653`을 `655`로 숫자만 바꿔서는 이 요청 파일의
부재가 해결되지 않는다. StaticData와 core 리소스의 URL prefix가 다르다는 사실만으로
어느 한 주소가 틀렸다고 판정하지 않는다.

Epinel의 자산 공급기는 외부 다운로드를 허용할 때 cache miss를 내려받지만 NLL은
`officialOutboundEnabled=false`다. 이 모드에서는 누락 자산을 가져오지 않고 404를 반환한다.
이 실행의 시작 관찰에서도 외부 연결 성공 0건, 공식 outbound fallback 미사용이다.
로그만으로 공식 CDN의 현재 해당 URL 응답을 판정하지 않았으며 이번 조사에서 외부 요청은 없다.

**앞선 “안내 파일 404를 설치 차단 근거로 삼지 않는다”는 판단을 정정한다.**
upstream과 응답 형태가 같다는 사실은 NLL의 로컬 자산 공급 완료를 보장하지 않는다.
152 배치에서 실제 클라이언트가 요청할 안내 메타데이터와 그 후속 catalog 공급 연결을
확인하지 못한 채 설치한 것이 누락이다. `ValidateOnly`와 보스 후보 검사는 이 게임 내
HTTP 초기화 단계를 실행하지 않으므로 이를 검출하지 못했다.

수정 대상은 152 클라이언트와 일치하는 안내 메타데이터 및 연결된 catalog의 로컬 공급이다.
정확한 데이터 근거 없이 번호를 치환하거나 과거 version map을 복원하지 않는다.
이번 요청은 원인 조사로, 런타임/클라이언트/음성 설정은 변경하지 않았다.
근거: `artifacts/apply-152-20260917/startup-4of7-investigation/Player.private.log`
121행부터, `diagnosis.private.json` 및 해당 실행의 `derived-start.stdout.log`.

### 4/7 수정 후보: 안내·native catalog 확보 및 HTTP 검증 (1~3단계) — 2026-09-17

운영자 승인 범위인 1~3단계를 별도 후보에서 수행했다. 실제 실패 요청인
`latest-655.txt`는 공개 CDN에서 HTTP 200이며 core는 `152.8.c12`다.
원본 안내 파일 139바이트의 SHA-256은
`ae8349c395511b8d2e2bf5ab1b21d27baab77a5f20758350f424f705f01c6432`다.
core/dp/en/ja/ko/fd/saus의 publication은 현재 로컬 `.patch_state.json` 7개와 모두 일치한다.

현재 후속 카탈로그는 `pck/<role>/<revision>/catalog.ndb`와 `catalog.ndb.nds`다.
7개 원본 body와 7개 동반 서명을 해당 CDN 주소에서 취득했고 모두 200이었다.
**CDN 취득본·공식 설치본·NLL 복제본의 14개 파일 SHA-256이 모두 일치**한다.
안내 파일과 함께 15개, 67,153,804바이트를 별도 후보 캐시에 봉인했다.
`catalog.ndb`는 NKDB 원본 바이트 그대로 공급한다. 구형 `catalog.db` 경로에
내부 카탈로그를 복사하거나 SQLite transport로 변환하는 방법은 채택하지 않았다.
그 경로를 검토하다 core URL 404를 확인했으며 해당 초안은 설치 대상에서 제외했다.

설치된 서버와 SHA-256이 같은 EpinelPS 어셈블리의 `AssetDownloadUtil.HandleReq`를
분리된 loopback HTTP 호스트에서 직접 호출했다. 15개 파일 전체 GET을 2회씩 보내
30개 응답이 200 및 원본 바이트 일치를 보였고, 15개 Range GET은 206 및 부분 바이트가
일치했다. 결손 요청은 외부 다운로드 없이 404다. 기존 `MapGet`의 HEAD 응답은
405이며 그대로 기록했다. 게임에서 HEAD를 사용한다는 근거는 없고 라우트는 변경하지 않았다.
이 검사는 실제 HTTP와 동일 자산 핸들러의 검증이며 전체 게임 시작/TLS 경로 인수는 아니다.

선택된 한국어 Minimal·SD 설치 인덱스 및 raw 파일의 결손/길이 불일치는 0이었다.
6.6GB 본문의 전수 재검증이나 매 실행 검사 추가는 하지 않았다. catalog 해시 대조와
SQLite 구조 검사는 수행했지만 `.nds` 암호학적 인증을 독립 검증한 것으로 표현하지 않는다.

후보 설정에서는 근거가 확보된 안내 selector만 `653`에서 `655`로 맞췄다.
현재 `GetResourceHosts`가 이 설정값을 사용하지 않으므로 **실제 수정의 핵심은 15개 파일 공급**이다.
후보 외의 런타임·선택 포인터·게임 설치본·계정 DB·음성 설정은 변경하지 않았다.
설치 및 사용자 실게임 확인은 다음 4단계로 남긴다. 신규 공용 업데이트 파이프라인 작업은 아니다.

근거: `artifacts/apply-152-20260917/resource-delivery-fix/`의
`resource-header-http.json`, `cdn-native-catalog-pairs/acquisition.private.json`,
`installed-catalogs.private.json`, `candidate-resources.private.json`,
`http-verification.private.json`, `delivery-candidate.private.json`.
마지막 파일의 정확한 15개 member만 후속 bundle 재봉인 대상이며 HTTP 시험 실행 파일은 설치하지 않는다.

저장소 필수 8개 gate도 모두 통과했다. Phase 2B의 포함 경로로 Phase 2A1·2A2를
검사했으며, 이번 DB 무변경 작업에서 live PostgreSQL integration은 재실행하지 않았다.
확인서는 같은 디렉터리의 `gates/required-gates.receipt.json`이다.

### 리소스 공급 후보 운영 설치 — 2026-09-17

후속 운영자 설치 승인으로 검증된 15개 리소스를 현재 152 서버에 설치했다.
`ResourceDataPackVersion=655` 설정과 runtime bundle 파일 목록·해시,
runtime selection 및 boss pipeline 설정 핀을 함께 갱신했다.
실행 때 파생 서버를 만드는 기존 경로가 이 15개 member를 모두 복사하도록 등록했다.
서버 실행 파일이나 게임 파일은 교체하지 않았다.

첫 설치 시도는 설치 스크립트의 경로 구분자 비교 차이로 설정 파일의 새 해시가
bundle에 반영되지 않아 검사가 중단됐다. 자동 복원 후 기존 4개 활성 입력의 해시 일치를
확인했으며, 해당 비교를 수정한 두 번째 설치가 정상 완료됐다. 첫 시도와 복원 증거는
`installation-backup/`에 보존했고 최종 설치 직전 백업은 `installation-backup-2/`다.

최종 설치 bundle SHA-256:
`d85b3356935b56a29dfa6394bfd85855f0c430858209a99de2c58c76c1ec5009`.
활성 pipeline 설정은 `resource-delivery-fix/configuration.installed.private.json`, SHA-256
`b6cbed108bb74cde4f49ad49c653b7e49d13103a80c1026fe058b8db6005736e`다.
설치 후 15개 리소스 해시·활성 포인터를 재확인했고 S41 수냉/철갑 및 S26 수냉의
게임 실행 없는 준비 검사가 모두 `ready`였다. 유지보수 잠금은 해제했다.
계정 DB를 열지 않았고 공식 설치본·음성 설정 변경 및 게임 실행은 없었다.
설치 후 운영자가 후속 실행의 **통과를 확인**했다. 이는 이번 4/7 리소스 공급 수정의
사용자 확인이며, 이후 요청된 DB 영속성과 로비 Quit 수정의 실게임 인수를 대신하지 않는다.
근거: 같은 작업 디렉터리의 `installation.receipt.json`,
`installed-preparation.receipt.json`, `installed-final-verification.json`.
