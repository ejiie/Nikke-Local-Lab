# HTTP로 보정 FX만 공급하는 방식 조사

> 2026-09-27 보관: 작성 당시의 기록이며 현재 작업 지시가 아닙니다. 현행 문서는 [문서 색인](../../README.md)에서 찾습니다.

작성: 2026-09-15. 운영자가 대화를 포크하여 HTTP 대안을 별도로 조사하도록 요청했다.
상위 목표는 [공통 실행 계획](COMMON_BOSS_EXECUTION_PLAN.md)의 시작·종료 단축이다.
이 문서는 지속 핸들 조사와 별개인 HTTP 경로의 근거·한계·다음 판단을 기록한다.
게임 실행, 설치, CDB/catalog/음성 변경 또는 새 DLL 변경은 수행하지 않았다.

## 결론

**서버가 보정 번들을 HTTP로 보내는 기능은 이미 검증됐지만, 현재 151 게임에 서버
설정만 추가해 보정 FX를 공급하는 방식은 채택할 근거가 없다.** 이번 정적 조사에서
번들 로더의 두 분기를 가상 파일 시스템의 stream과 로컬 파일 로딩에 연결했다.
확인한 분기에 HTTP 다운로드 호출은 없었다. 파일명만 맞추거나 `no-store`를 설정하는
수정으로 이 선택을 바꿀 수 있다고 가정하면 안 된다.

이는 모든 HTTP 사용 가능성을 부정하는 증명이 아니다. 해당 루틴의 실제 FX 런타임 호출과
다른 provider/로딩 경로의 존재는 미확정이다. 다만 조사 전의 막연한 “HTTP 요청만
연결하면 될 수 있다”에서 **client 쪽 소비 경로를 먼저 입증해야 하는 대안**으로 좁혀졌다.

## 1. 기존 HTTP 작업은 어디까지 돼 있었나

- `ExecutionAssetOverlay`는 봉인된 보정 byte와 정확한 요청 경로 하나를 연결한다.
  `ExecutionAssetOverlayHttp`는 GET/HEAD/range를 처리한다. 다른 파일의 유효한 경로는
  기존 handler로 넘어가며, 닫힌 전달/잘못된 요청은 오류로 처리한다.
- `ExecutionAssetOverlayStartup`은 여섯 실행 입력으로 전달을 준비하고 middleware를
  연결한다. 그 입력들은 **Epinel 서버 설정**이다. 게임의 provider 선택을 바꾸지 않는다.
- `patches/epinel-execution-fx-mount.patch`와 `.external/EpinelPS-fx-candidate`에 실제
  source 연결이 있다. 서버 출력은 `artifacts/epinel-fx-integration/server`다.
  이전 조사에서 확인한 `.external/EpinelPS-151-candidate`와는 다른 후보이다.
- `artifacts/epinel-fx-checks/e1e2d66538cc423c8264b5503786129f/receipt.json`은 세 보정
  입력을 실제 후보 DLL의 middleware/기존 asset handler로 시험한 성공 기록이다.
  Epinel Main·게임·운영 DB를 실행한 기록은 아니다. 활성 v8의 HTTP-FX 설치 증거도 아니다.

따라서 서버 전달 코드를 새로 만드는 것이 다음 병목은 아니다. 예전 후보 서버를 그대로
활성화하면 최신 공통 실행 변경까지 포함된다는 보장도 없으므로 설치하지 않는다.

## 2. 예전 HTTP 파일명과 현재 native 입력의 차이

151 catalog와 기존 native 추출의 연결은 `AddressableFxBinding`에서 다음 순서로 확인된다.

```text
FX asset key
  → BundledAssetProvider의 dependency key
  → AssetBundleProvider의 bundle internal ID + entry_data
  → is_local=0인 정확한 번들 키는 core catalog의 files_chunktype.key와 연결
  → chunk_file_map → CIDX/CDB 조각
```

이번에는 원본 catalog의 기존 복호 scratch를 읽기 전용으로 열고, 이전 검증된 binding과
HTTP manifest를 hash로 고정해 다시 대조했다. 새로운 catalog 복호본이나 client 사본은
만들지 않았다. 아래의 이름/크기는 원본 native 번들의 것이며 새 보정 결과 hash가 아니다.

| 보스 속성 | 현재 native 키의 catalog 일치 | 예전 HTTP 파일명 일치 | URL scheme | is_local | native 원본 크기 / 로컬 의존 번들 |
| --- | ---: | ---: | --- | ---: | --- |
| 작열 | 1 | 0 | 없음 | 0 | 1,215,712B / 2개 |
| 풍압 | 1 | 0 | 없음 | 0 | 1,217,520B / 3개 |
| 철갑 | 1 | 0 | 없음 | 0 | 1,216,544B / 2개 |

예전 HTTP manifest의 leaf는 세 경우 모두 native 키와 다르다. 과거 HTTP byte 전달
검사를 현재 native 보정 byte의 로딩 증거로 재사용할 수 없다. `is_local=0`도 여기서는
“현재 HTTP에서 받아야 함”의 증거가 아니다. 이미 설치된 chunk 데이터에 정확히 연결된다.

## 3. 이번에 찾은 원본 로더 분기

검사 대상은 151 ResourceProbe의 고정 `GameAssembly.dll`이다. 게임/대상 DLL을
로드하지 않고 디스크 byte와 Microsoft disassembler 출력만 읽었다. SHA-256은
`23b64ef22957356bfb3f02096a8fd59c5e2b6426bafb44520acd7fcd12a060ed`다.

| 연결 | 관측 사실 | 확정 범위 |
| --- | --- | --- |
| catalog 옵션 생성 → 로더의 옵션 형식 검사 | 같은 type 참조를 쓰며, 생성 측에서 읽은 열 ordinal 8의 값을 객체 +0x10 byte에 저장 | 기계어의 type/field 연결 확인 |
| 로더의 +0x10 값이 0 | 가상 파일 시스템 open helper의 반환 stream을 `LoadFromStreamAsyncInternal`에 전달 | 두 로더 루틴에서 같은 분기 확인 |
| 로더의 +0x10 값이 0이 아님 | 기준 경로와 bundle ID를 경로 helper에 넘긴 뒤 `LoadFromFileAsync_Internal` 호출 | 같은 두 루틴에서 확인 |
| stream 쪽 helper | 파일 조회, chunk 존재 검사와 stream 생성 경로로 연결 | 중간 helper의 직접 call/tail jump 확인 |
| HTTP 선택 | 확인한 두 분기에 URL 검사/HTTP 다운로드 호출 없음 | 이 분기에 한정. 모든 게임 네트워크 코드의 부재를 뜻하지 않음 |

API 이름은 단순 문자열 검색만으로 정하지 않았다. 각각의 internal-call wrapper가
해당 Unity API 문자열을 resolver에 전달하고 그 반환 함수를 호출하는 위치까지 연결했다.
8개 함수의 41개 instruction 확인을 재현 helper로 고정했다.

**추론과 미확정:** catalog의 `entry_data`는 `type_rowid,is_local`이고 그 타입은
`AssetBundleRequestOptions`다. 위 객체의 bool이 `is_local`이라는 해석은 이 schema와
deserializer/loader 연결에 근거한 강한 정적 추론이다. 원본 SQL query text/전체 심볼을
복원하지 않았으므로 열 ordinal 8의 이름까지 확정했다고 표시하지 않는다. 해당 루틴이
운영자의 쉴드 렌더링 때 실제 호출됐다는 동적 증거도 이번 조사에는 없다.

일반 Unity Addressables 문서는 internal ID가 HTTP URL이면 웹 요청, 아니면 파일 로딩을
설명한다. 이 문서는 비교 기준일 뿐, 같은 provider 타입명을 쓰는 151 구현이 동일하다는
증거가 아니다. 이번에 관측한 것은 위의 bool/stream/file 분기다.
[Unity AssetBundleProvider 문서](https://docs.unity3d.com/Packages/com.unity.addressables@1.20/api/UnityEngine.ResourceManagement.ResourceProviders.AssetBundleProvider.html).

일반 Addressables의 `InternalIdTransformFunc`도 게임 코드에서 등록하는 기능이다.
서버의 FX 환경 변수나 HTTP header로 원격 설정되는 기능으로 취급하지 않는다.
[Unity ID 변환 문서](https://docs.unity3d.com/Packages/com.unity.addressables@1.21/manual/TransformInternalId.html).

## 4. 가능한 변경과 해결되지 않는 변경

| 제안 | 현재 판단 |
| --- | --- |
| Epinel에 기존 FX middleware만 활성화 | 서버 준비는 가능. 게임 요청 발생/소비 경로를 해결하지 못함 |
| HTTP URL의 파일명만 151 native 키로 바꿈 | 예전 이름 불일치 하나만 해결. native 키를 HTTP 요청으로 전환한다는 증거 없음 |
| `Cache-Control: no-store` 추가 | 이미 있음. HTTP 요청 이전의 stream/file 선택에는 적용되지 않음 |
| internal ID를 HTTP URL로 교체 | 일반 Unity 문서만으로 채택 불가. 확인한 분기에서는 VFS lookup key/파일 경로로 쓰일 수 있으며 catalog 수락도 미확정 |
| is_local을 바꿈 | 확인한 bool 분기가 해당 값이라면 stream/file 선택을 바꾸는 것이며 HTTP 선택 근거는 아님 |
| CDB의 기존 조각을 없애 다시 다운로드시킴 | 작은 FX만 독립 공급하는 경로로 입증되지 않음. 조각 결손·검증·재설치/공유 cache 변경 문제가 추가되므로 실행하지 않음 |
| HTTP로 작은 파일을 미리 받은 뒤 로컬 파일 분기에서 사용 | native HTTP 로딩과 다른 설계. CDB 수정을 피할 잠재 대안이지만 정확한 로컬 경로·catalog 변경 수락·회복을 별도로 검증해야 함 |

과거 plain SQLite 투영 실패는 `malformed database` 관측이다. 그 시험의 형식과 outer
catalog digest가 정상 수락됐다는 증거는 없으며, 모든 변경 catalog나 HTTP를 불가능하게
하는 서명 실패 증거로 일반화할 수 없다. 보정 catalog를 시도하려면 native 포맷과
선택 우선순위부터 확인해야 한다. 기존 승인 DLL의 사용 여부와도 구분한다.

## 5. 후속 조사와 종료 기준

1. **서버만 바꾸는 직접 HTTP 전달은 지금 구현·설치하지 않는다.** 현재 분기를 그대로
   두고 될 것이라는 근거가 없으므로 서버 복제/반복 HTTP 단위 검사에 시간을 쓰지 않는다.
2. 직접 HTTP 대안을 더 진행하려면 변경 가능한 기존 설정/데이터가 다른 HTTP 소비
   경로를 선택한다는 근거를 먼저 찾는다. 그러한 지점을 찾지 못하면 이 대안은
   `client_route_unresolved`로 남긴다. 새 게임 후킹/DLL 패치로 경로를 만들지 않는다.
3. CDB 변경 제거라는 목표에는 **작은 로컬 파일 분기**가 더 직접적인 후보로 드러났다.
   이를 선택한다면 local root와 catalog→옵션→로더 연결을 마저 닫고, 원본 형식을 유지한
   최소 catalog 변경의 수락 가능성을 확인한다. HTTP 가능성으로 이름을 바꿔 완료 처리하지 않는다.
4. 어느 경로든 동적 시험에 들어가기 전 원본/보정/native dependency pin, 실행 소유권,
   종료·원복과 A→B→A 간 잔존 방지를 준비한다. 게임 실행은 운영자가 한다.
   HTTP GET 성공만으로 소비/렌더링 성공 또는 전체 파일 검산 제거를 선언하지 않는다.

## 재현·기록

- helper: `artifacts/http-fx-investigation-20260915/inspect-http-provider.py`
- 결과: `artifacts/http-fx-investigation-20260915/provider.receipt.json`
- 참조: 과거 native binding, catalog format projection receipt, 외부 Epinel FX 검사 receipt.
- helper는 정해진 입력 pin을 전후 대조하고, 새 작은 조사 receipt만 기록한다.
  원본 bundle/key·디스어셈블리·복호 DB는 Git/CI 입력으로 추가하지 않는다.
- 결과는 정적 조사 성공이다. 최적화 구현·설치·실게임 HTTP 인수는 모두 미완료다.
