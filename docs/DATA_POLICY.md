# Data policy

## 저장소에 들어갈 수 있는 것

- 직접 작성한 소스 코드
- DB migration과 API/도메인 계약
- 데이터 계보를 설명하는 문서
- 실제 게임 내용을 포함하지 않는 합성 fixture
- 원본 내용을 복원할 수 없는 비가역 hash와 최소 provenance

## 저장소에 들어갈 수 없는 것

- `C:\NIKKE`의 파일 복사본
- MPK, NKDB, NKAB, UnityFS, bundle, catalog, localization 원문
- 복호·디코드 JSON, StaticData ZIP, 이미지, 음성, 영상, 애니메이션
- 실제 캐릭터/몬스터/스킬 데이터 dump
- 원본 season, preset, wave, monster, spot, asset 식별자 mapping
- 실제 계정 UID, 로스터, 장비, 재화, 뽑기 기록
- 쿠키, 세션, 인증 헤더, 토큰, 비밀키
- 로컬 PostgreSQL/SQLite dump와 백업
- patched native binary, local CA/PFX/private key와 disposable client image/snapshot
- EpinelPS가 생성하거나 포함한 protobuf output, StaticData cache와 client-local compatibility binding

## 로컬 런타임 경계

현재 로컬 데이터는 다음 위치에 있습니다(2026-09-27 확인). 모두 Git·Actions·remote 대상이 아닙니다.

| 위치 | 내용 |
|---|---|
| `C:\NLL` | 봉인 client 복제본, runtime bundle, 보스·FX runtime 입력, Control Center 앱·PostgreSQL data·DPAPI 비밀, staging·evidence |
| `C:\ProgramData\NikkeLocalLab` | BattleLog 원문(`BattleLogs`), 분석 캐시(`BattleAnalysis`), 진단(`Diagnostics`). 운영자·SYSTEM·Administrators 전용 ACL |
| `D:\NikkeLocalLab\Backups` | 보관 client, DB dump, 복구 checkpoint |
| 저장소 `artifacts/` | Git 제외. 작업별 receipt·백업·private 구성. 활성 보스 pipeline 구성도 이 아래를 가리킵니다 |

정확한 경로 권위는 [MICRON_CURRENT_PATHS.md](MICRON_CURRENT_PATHS.md)입니다. Phase 1A가 기본값으로 정의한
`%LOCALAPPDATA%\NikkeLocalLab\{data,database,vault,cache,logs,secrets,staging,compatibility}` 구조는 현재 만들어져
있지 않으며 위 위치가 실제 운영 경로입니다. 원본 내용·계정 raw·비밀을 저장소 추적 경로에 두지 않는 규칙은 같습니다.

Micron `C:\NIKKE`는 공식 launcher가 설치·업데이트하는 mutable official-current source입니다. Local Lab importer는 여기에서 읽을 수 있지만 쓰기 capability를 갖지 않으며, EpinelPS/private-server 실험은 이 경로를 수정하거나 실행 대상으로 삼지 않습니다. 재현성·실험용 client는 저장소 밖의 `C:\NLL\Clients\NIKKE-<build>-*`에 별도 version/hash로 봉인합니다. 현재 실제 경로와 Samsung 배제 규칙은 [MICRON_CURRENT_PATHS.md](MICRON_CURRENT_PATHS.md)를 따릅니다.

Phase 3 modified-local 연구에서 허용되는 변경 대상은 **disposable VM/별도 OS와 그 안의 client copy**뿐입니다. 단순 디렉터리 복제본은 host system trust를 격리하지 못합니다. 다음 변경은 [PHASE3AR.md](contracts/PHASE3AR.md)에 고정된 EpinelPS commit과 exact client build를 대상으로 사전 검토한 경우에만 허용합니다.

- disposable VM/OS 안에서만 local-only hostname routing을 위한 system hosts 변경
- disposable VM/OS 안에서만 root CA trust 변경; client-local certificate bundle은 복제본에도 적용 가능
- 검토·hash 고정한 native compatibility shim 교체

각 변경은 적용 전에 frozen lane 원래 byte의 SHA-256과 backup 위치, 적용 byte의 SHA-256, 적용 순서와 rollback 순서를 manifest에 기록합니다. 실행 종료 또는 실패 뒤에는 rollback을 검증하고 공식-current `C:\NIKKE`가 Local Lab에 의해 변경되지 않았음을 다시 확인합니다. backup, certificate/private key, shim binary, patched output, client snapshot과 상세 original member manifest는 Git·CI·remote에 넣지 않습니다.

EpinelPS는 Local Lab repository에 vendor하지 않고 기본적으로 별도 local checkout/process로 둡니다. 검토 기준은 `28b2f5413a0a1e3521a11ae162f91851335c8b40`이며 다른 commit이나 prebuilt binary로 바뀌면 새 provenance/hash 검토가 필요합니다. 공개 source의 존재는 기술적 prior art일 뿐 Shift Up의 승인 증거가 아니며, EpinelPS source를 복사·수정·배포하는 선택은 AGPL-3.0 의무를 별도로 검토해야 합니다.

복호물, compatibility map, 런타임 DB, cache와 log는 모두 Git 외부에 둡니다. 저장소 fixture에는 자체 UUID와 합성 hash만 사용합니다.

운영자가 승인한 Phase 3B-2 정적 catalog 수집 예외로 얻은 `core`/`dp`/`fd`의 여섯 catalog byte도 원본 game content로 분류합니다. 여섯 catalog를 Epinel 자체 NKDB parser로 해석해 도출한 **native cache materialization closure**의 bundle byte도 같은 분류와 보관 경계를 적용합니다. 이 closure는 catalog의 role host token과 32-hex bundle identity가 정확히 하나의 CDN 상대 경로를 만드는 row만 포함합니다. provider metadata와 `{UnityEngine.AddressableAssets.Addressables.RuntimePath}` 항목은 원격 객체로 취급하지 않습니다.

요청 manifest, raw URL, relative path, catalog와 bundle byte는 Git-external protected root에만 보관하고(수집 당시 Samsung, 이관 후 Micron `C:\NLL`) Git/Actions/remote로 복사하지 않습니다. 저장소에는 host·method·count·byte limit를 제한하는 범용 수집기, source-free receipt 계약과 비가역 digest만 둘 수 있습니다. Micron 복제본의 `naps`에서 identity와 catalog-declared byte length가 모두 같은 member는 read-only source로 재사용하고, 결손 또는 size mismatch member만 정적 CDN에서 획득합니다. 각 최종 member는 catalog-declared length와 별도 SHA-256 manifest로 봉인합니다. 수집 실패는 resumable `Pending`, 검산 성공은 `Sealed`, rollback은 별도 Git-external `Quarantine`으로 이동하여 복구 가능성을 보존합니다. Micron runtime cache에는 전체 closure를 offline 검증하고 별도 staging gate를 통과하기 전까지 복사하지 않습니다.

original-client wire/presentation adapter가 client-local content reference를 요구하면 정확한 disposable client build에 결박된 Git 비추적 compatibility binding에서 실행 중에만 변환합니다. 해당 원본 reference, localized asset, icon, prefab 또는 patch output을 public domain/API, receipt, log, fixture와 Git에 복사하지 않습니다. source-free receipt에는 lab UID, controlled role, byte length와 비가역 hash만 남깁니다.

Phase 1A의 `database\` 디렉터리는 경계만 초기화하며 PostgreSQL cluster나 dump를 자동 생성하지 않습니다. `staging\`은 import 실행 중 임시 데이터용이며 source 또는 repository와 겹칠 수 없습니다. Phase 1B character reader는 archive를 메모리에서만 해석하고 decoded file을 만들지 않습니다. 향후 staging을 쓰는 importer는 성공·실패·취소 후 이를 비워야 합니다.

## 2026-09-05 Micron 151 입력 보관

`SECURITY_BOUNDARY.md`의 추가 운영자 승인에 따라 취득하는 151 static pack과
버전 metadata도 원본 game content입니다. 정확한 URL·private 요청/취득 manifest와
파일 byte는 `C:\NLL\Staging`의 신규 assessment에만 보관합니다. 기존 설치본,
runtime cache 또는 DB를 덮어쓰지 않습니다. 저장소에는 역할·길이·비가역 SHA-256과
검증 상태만 기록합니다. 실패한 partial은 성공 입력으로 사용하지 않고 보존합니다.
수집 성공은 pack 해석, resource closure 또는 native 실행 성공을 뜻하지 않습니다.

## Private source remote 경계

직접 작성한 source·계약·문서·합성 fixture는 사용자 소유 private GitHub repository에 저장할 수 있습니다. push 전에 working/staged/tracked 정책 검사를 통과해야 합니다.

private remote도 제3자 저장소라는 점은 변하지 않습니다. 따라서 로컬 전용 금지 데이터는 암호화 여부와 관계없이 commit, Actions artifact, cache, log, release에 올리지 않습니다. Actions runner는 `C:\NIKKE`나 로컬 runtime root에 접근하지 않습니다.

## 배포 경계

프로젝트는 개인·비상업·로컬 실험용이며 remote visibility를 public으로 바꾸거나 release/package, client image, selector, certificate 또는 patched binary를 발행하지 않습니다. 서버는 public bind, LAN 공유와 인터넷 port-forwarding을 허용하지 않습니다. 원본 및 원본을 실질적으로 재구성할 수 있는 대량 파생 데이터는 공유·호스팅·커밋하지 않습니다.

공개 EpinelPS 저장소와 유사 프로젝트의 존재는 기술적 가능성을 뒷받침하지만 저작권, 상표, 서비스 약관 또는 권리자 허가를 자동으로 해소하지 않습니다. 권리자 승인은 주장하지 않고 법적 상태는 `not_determined`로 남깁니다. 배포, 제3자 접속, 공식 계정 사용 또는 상업화로 범위가 바뀌면 이 정책 아래에서 계속하지 않고 별도 검토합니다.
