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

## 로컬 런타임 경계

런타임 데이터는 저장소 밖 `%LOCALAPPDATA%\NikkeLocalLab`에 두는 것을 기본으로 합니다.

    %LOCALAPPDATA%\NikkeLocalLab\
      data\
      database\
      vault\
      cache\
      logs\
      secrets\

`C:\NIKKE`는 read-only source입니다. 소스 파일을 수정·교체하거나 저장소 안으로 shadow copy하지 않습니다. 향후 재현성용 local vault가 필요하면 content-addressed copy를 저장소 밖에 만들고 원본 hash와 접근 정책을 기록합니다.

복호물, compatibility map, 런타임 DB, cache와 log는 모두 Git 외부에 둡니다. 저장소 fixture에는 자체 UUID와 합성 hash만 사용합니다.

## 배포 경계

프로젝트와 데이터는 개인 로컬 실험에만 사용합니다. 원본 및 원본을 실질적으로 재구성할 수 있는 대량 파생 데이터는 공유·호스팅·커밋하지 않습니다. 로컬 사용은 저작권이나 서비스 약관 문제를 자동으로 해소하지 않으므로 범위가 바뀌면 별도 검토합니다.
