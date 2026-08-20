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

런타임 데이터는 저장소 밖 `%LOCALAPPDATA%\NikkeLocalLab`에 두는 것을 기본으로 합니다.

    %LOCALAPPDATA%\NikkeLocalLab\
      data\
      database\
      vault\
      cache\
      logs\
      secrets\
      staging\
      compatibility\
        upstream\
        manifests\
        backups\
        disposable-client\
        evidence\

`C:\NIKKE` 주 설치본은 계속 read-only source입니다. 그 안의 파일, hosts/CA 상태 또는 launcher 설정을 수정·교체하지 않고 저장소 안으로 shadow copy하지 않습니다. 재현성용 local vault나 정적 검산 복제본은 저장소 밖의 `compatibility\disposable-client`에 둘 수 있지만, 실제 client 실행과 system hosts/root CA 변경은 격리 VM/별도 OS에서만 수행합니다. 두 경우 모두 원본 build/content-set hash와 접근 정책을 기록합니다.

Phase 3 modified-local 연구에서 허용되는 변경 대상은 **disposable VM/별도 OS와 그 안의 client copy**뿐입니다. 단순 디렉터리 복제본은 host system trust를 격리하지 못합니다. 다음 변경은 [PHASE3AR.md](PHASE3AR.md)에 고정된 EpinelPS commit과 exact client build를 대상으로 사전 검토한 경우에만 허용합니다.

- disposable VM/OS 안에서만 local-only hostname routing을 위한 system hosts 변경
- disposable VM/OS 안에서만 root CA trust 변경; client-local certificate bundle은 복제본에도 적용 가능
- 검토·hash 고정한 native compatibility shim 교체

각 변경은 적용 전에 원래 byte의 SHA-256과 backup 위치, 적용 byte의 SHA-256, 적용 순서와 rollback 순서를 manifest에 기록합니다. 실행 종료 또는 실패 뒤에는 rollback을 검증하고 주 설치본의 hash가 변하지 않았음을 다시 확인합니다. backup, certificate/private key, shim binary, patched output, client snapshot과 상세 original member manifest는 Git·CI·remote에 넣지 않습니다.

EpinelPS는 Local Lab repository에 vendor하지 않고 기본적으로 별도 local checkout/process로 둡니다. 검토 기준은 `28b2f5413a0a1e3521a11ae162f91851335c8b40`이며 다른 commit이나 prebuilt binary로 바뀌면 새 provenance/hash 검토가 필요합니다. 공개 source의 존재는 기술적 prior art일 뿐 Shift Up의 승인 증거가 아니며, EpinelPS source를 복사·수정·배포하는 선택은 AGPL-3.0 의무를 별도로 검토해야 합니다.

복호물, compatibility map, 런타임 DB, cache와 log는 모두 Git 외부에 둡니다. 저장소 fixture에는 자체 UUID와 합성 hash만 사용합니다.

original-client wire/presentation adapter가 client-local content reference를 요구하면 정확한 disposable client build에 결박된 Git 비추적 compatibility binding에서 실행 중에만 변환합니다. 해당 원본 reference, localized asset, icon, prefab 또는 patch output을 public domain/API, receipt, log, fixture와 Git에 복사하지 않습니다. source-free receipt에는 lab UID, controlled role, byte length와 비가역 hash만 남깁니다.

Phase 1A의 `database\` 디렉터리는 경계만 초기화하며 PostgreSQL cluster나 dump를 자동 생성하지 않습니다. `staging\`은 import 실행 중 임시 데이터용이며 source 또는 repository와 겹칠 수 없습니다. Phase 1B character reader는 archive를 메모리에서만 해석하고 decoded file을 만들지 않습니다. 향후 staging을 쓰는 importer는 성공·실패·취소 후 이를 비워야 합니다.

## Private source remote 경계

직접 작성한 source·계약·문서·합성 fixture는 사용자 소유 private GitHub repository에 저장할 수 있습니다. push 전에 working/staged/tracked 정책 검사를 통과해야 합니다.

private remote도 제3자 저장소라는 점은 변하지 않습니다. 따라서 로컬 전용 금지 데이터는 암호화 여부와 관계없이 commit, Actions artifact, cache, log, release에 올리지 않습니다. Actions runner는 `C:\NIKKE`나 로컬 runtime root에 접근하지 않습니다.

## 배포 경계

프로젝트는 개인·비상업·로컬 실험용이며 remote visibility를 public으로 바꾸거나 release/package, client image, selector, certificate 또는 patched binary를 발행하지 않습니다. 서버는 public bind, LAN 공유와 인터넷 port-forwarding을 허용하지 않습니다. 원본 및 원본을 실질적으로 재구성할 수 있는 대량 파생 데이터는 공유·호스팅·커밋하지 않습니다.

공개 EpinelPS 저장소와 유사 프로젝트의 존재는 기술적 가능성을 뒷받침하지만 저작권, 상표, 서비스 약관 또는 권리자 허가를 자동으로 해소하지 않습니다. 권리자 승인은 주장하지 않고 법적 상태는 `not_determined`로 남깁니다. 배포, 제3자 접속, 공식 계정 사용 또는 상업화로 범위가 바뀌면 이 정책 아래에서 계속하지 않고 별도 검토합니다.
