# 150 클라이언트 보관 이전

2026-09-12 운영자는 영속화 실게임 검증과 병행하여 GitHub 복구 및 150의 D: 이동을 요청했다.
현재 상태는 **D: 전체 복사/검산 완료, C: 원본 제거는 실게임/관리도구 종료 대기**다.
공간 회수까지 끝난 이동 완료로 해석하지 않는다.

## 정확한 범위

- 원본: `C:\NLL\Clients\NIKKE-150.6.9-Physical`
- 보관: `D:\NikkeLocalLab\Backups\client-150-archive-20260912-01\NIKKE-150.6.9-Physical`
- 원본 조사: 39,504개 파일, 27,264,219,735 byte, reparse point 0개.
- 공식 `C:\NIKKE`, 151 ResourceProbe, v6 bundle, 운영 DB와 과거 sealed receipt는 이동·수정하지 않는다.
- D:는 보관 경로이지 150 실행 경로가 아니다. 복원 시 원래 C: 경로로 돌리고 전체 manifest를 검증한다.

## 의존성 조사와 분리

선택 포인터는 151/v6를 유지한다. bundle SHA-256은
`148ea9ae3e6a5759fd5075c7e25a2860331affc5644043a20a2869afcff8c9db`이다.
coordinator는 선택된 bundle의 client/bootstrap을 사용한다. 실제 bootstrap DLL의
컴파일된 문자열에서 151 client 경로 존재 및 150 경로 부재를 확인했다. v6 tree의
reparse point는 0개이며 manifest에도 150 client 참조가 없다.

과거 150 bootstrap, legacy runner fallback과 sealed rollback 경로는 역사/명시적 복원용으로
보존한다. 이들을 D:로 자동 재지정하지 않는다. 선택 포인터를 지우거나 150 fallback을
활성화하는 것은 이 보관 작업에 포함되지 않는다. 151도 사용하는 과거 runtime seed/server
폴더는 클라이언트 보관 대상이 아니며 그대로 둔다.

관리도구 복구 스크립트만 사용하던 큐브 번역 입력 2개(총 4,510,922 byte)는
`C:\NLL\RuntimeInputs\CubeLocale-150-v1`에 private ACL로 분리했다.
`manifest.private.json`에 원본과 일치하는 길이·SHA-256을 고정했다. 복구 스크립트는
설치 파일/DB 변경 전에 이 입력의 경로·reparse·hash를 확인하고 복사 후에도 hash를 검증한다.
원본 게임 데이터이므로 Git/CI에 입력 파일을 올리지 않는다. 현재 게임이나 관리도구 복구를
실행한 것이 아니며, 검증부만 정상 실제 pin·결손·변조·옛 경로 제거 4개 항목으로 확인했다.

## 이전/복원 게이트

1. 원본 전체 파일, 빈 디렉터리 및 대체 데이터 스트림의 private manifest를 수집한다.
2. 새 D: private 폴더로 복사하며 기존 백업을 덮어쓰지 않는다.
3. 원본 재검산과 목적지 전체 검산이 사전 manifest와 같아야 copy receipt를 발급한다.
4. 게임·서버·관리도구·PG·종료 watcher가 모두 종료되고 151 선택/파일 pin이 유지된 상태에서만
   C: 원본 제거를 진행한다. 실행 중인 사용자 테스트를 중단하지 않는다.
5. 원본 제거 전 source/destination pin을 재검증한다. 실패 시 D: 사본과 C: 원본을 유지한다.
6. 원본 제거 후 D: payload, private manifest/receipt와 기존 rollback evidence를 보존한다.

상세 원본 member/stream 이름과 해시는 위 private 보관 폴더에만 둔다. source-free 문서에는
전체 count/byte와 비가역 manifest hash 및 완료 상태만 기록한다. C: 원본이 남아 있는 동안은
디스크 공간 회수 또는 이동 완료를 주장하지 않는다.

검산기는 합성 파일/스트림으로 7개 검사(파일·디렉터리 count, 스트림 포함, 복사 동등성,
스트림 변조, 파일 변조, 빈 디렉터리 차이, reparse 거부)를 통과했다. 실행 중 게임이 있는
상태에서 제거 절차를 유효하지 않은 manifest hash로 호출했을 때 첫 cold guard에서
`resource_native_archive_not_cold`로 거절되고 원본이 유지되는 것도 확인했다.

## 확인된 복사 결과

사전 원본, 사후 원본, D: 복사본의 전체 manifest SHA-256이 모두
`7afd6f48e14301b1cfb7ffe9bc50c339cfe5b49b440130196cccdcd64b448d7d`로 일치했다.
`copy.receipt.json`은 `copy_verified_source_retained`, 39,504개 파일,
27,264,219,735 byte, `alternateStreamsChecked=true`, `sourceRemoved=false`다.
이는 원본 전후 불변 및 복사 일치 증거이며 C: 제거 완료 receipt가 아니다.

`dependency-audit.receipt.json`과 `operation-tools/manifest.json`에는 의존성 조사와
이번 copy/retire 절차 코드의 pin을 보존했다. 게임과 관리도구를 정상 종료한 뒤
`operation-tools/retire-verified-source.ps1`에 위 manifest hash를 명시하면
cold/151 pin/복구 입력과 원본·보관본 전체를 다시 검증한 뒤 정확한 C: 150 경로만 제거한다.
제거 완료 증거는 별도의 `retirement.receipt.json`이며 **아직 발급되지 않았다**.
