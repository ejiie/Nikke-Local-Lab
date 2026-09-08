# Nikke Local Lab

원본 NIKKE UI와 실제 전투 runtime을 사용하는 개인용·비배포 로컬 compatibility 프로젝트입니다.
관리도구는 계정·프로필·보스 선택과 실행 준비를 담당하며, 별도 게임 UI나 전투 시뮬레이터로 대체하지 않습니다.

## 현재 상태 — 2026-09-06

- 관리도구에 연결한 **151 / S26 실게임 검증을 운영자가 완료**했습니다. 리소스 변화 대응은 종료했습니다.
- 다음 작업은 기능 추가가 아닌 코드·DB·문서 안정화입니다.
- S29 profile 버전 불일치와 미완료 실드 확장은 별도 보류입니다. S26 성공을 모든 조합의 성공으로 확대하지 않습니다.
- 실제 실행은 선택된 로컬 bundle을 사용합니다. 과거 source-free harness의 blocked fixture와 현재 실게임 검증은 별도 증거입니다.

## 문서 찾기

- [전체 문서 색인](docs/README.md): 현행 안내, 상세 계약, 기능, 운영 절차, 과거 기록
- [현재 작업 인계](docs/HANDOFF.md): 확인된 상태와 보류 사항
- [안정화 점검·계획](docs/STABILIZATION_PLAN.md): 발견 사항, 검사 결과, 정비 순서
- [현재 아키텍처](docs/ARCHITECTURE.md): 실행·저장 흐름과 책임 경계
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
실게임 인수, source-free 계약 검사, 단위 테스트, 폐기 DB 통합 검사의 결과를 구분합니다.
현재 검사 통과 범위와 남은 통합 검증 조건은 [안정화 계획](docs/STABILIZATION_PLAN.md)에 기록했습니다.

이전 프로젝트 소개와 Phase별 진행 이력은 [보관본](docs/archive/PROJECT_OVERVIEW_2026-09-06.md)에 있습니다.
