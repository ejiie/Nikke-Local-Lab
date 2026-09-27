# Nikke Local Lab

원본 NIKKE UI와 실제 전투 runtime을 사용하는 개인용·비배포 로컬 compatibility 프로젝트입니다.
관리도구는 계정·니케·보스 선택, 실행 준비, 레이드 기록 조회를 담당하며, 별도 게임 UI나 전투 시뮬레이터로 대체하지 않습니다.

## 현재 상태 — 2026-09-27

- 봉인한 152.8.11 client 복제본과 로컬 Epinel 서버로 솔로 레이드 Challenge(실전·모의전)와 유니온 레이드 하드를 실행합니다.
- 솔로 보스 9개 시즌(S7·9·10·25·26·27·29·34·41)을 공통 파이프라인으로 등록했습니다. S39·S42는 조립 실패를 고치는 중입니다.
- 레이드 결과의 딜표·투사체 제외 개인딜·캐릭터별 피해 구성을 저장하고 조회합니다.
- 상세 현황은 [HANDOFF](docs/HANDOFF.md), 남은 작업은 [NEXT_STEPS](docs/NEXT_STEPS.md)에 있습니다.

## 문서 찾기

- [전체 문서 색인](docs/README.md): 현행 문서, 기능, 운영 절차, 계약, 보관 기록
- [현재 아키텍처](docs/ARCHITECTURE.md): 구성 요소와 소스 구조
- [Micron 경로](docs/MICRON_CURRENT_PATHS.md): 실제 설치본·실행 lane·백업의 권위

## 작업 경계

관리도구 UI를 다른 프로젝트에서 사용할 때는
[UI 소스·WebView2 shell·로컬 이미지 분리 안내](docs/ARCHITECTURE.md#관리도구-ui-재사용)를
확인합니다. 이 저장소는 소스 게시본이며 게임 이미지·계정 데이터·설치 실행 파일은 포함하지 않습니다.

`C:\NIKKE`는 공식 launcher가 관리하는 설치본이며 Local Lab 실행·변경 대상이 아닙니다.
검증된 Epinel DLL과 별도 봉인한 로컬 client lane을 유지합니다.
게임 원본·asset·DB·실계정 raw·비밀 정보는 Git에 넣지 않습니다.
세부 범위와 허용 조건은 [SCOPE](docs/SCOPE.md), [보안](docs/SECURITY_BOUNDARY.md),
[데이터 정책](docs/DATA_POLICY.md), [AGENTS](AGENTS.md)를 따릅니다.

## 검증

필수 검사와 CI 운영은 [검증·Actions 절차](docs/operations/GITHUB_AUTOMATION.md)를 따릅니다.
운영자 실게임 확인, source-free 계약 검사, 단위 테스트, 폐기 DB 통합 검사의 결과를 구분합니다.
변경은 `agent/**` branch에 push하면 Actions가 검증·PR·squash merge를 처리합니다.

이전 프로젝트 소개와 Phase별 진행 이력은 [보관본](docs/archive/PROJECT_OVERVIEW_2026-09-06.md)에 있습니다.
