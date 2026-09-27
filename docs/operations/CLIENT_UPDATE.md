# 공식 client 업데이트 적용 순서

2026-09-17 151.8.5 → 152.8.11 적용에서 실제로 거친 순서를 다음 업데이트용으로 정리했습니다.
다음 버전에서도 같은 결과가 나온다는 보장은 아니며, 각 단계의 판정은 그 버전의 증거로 다시 합니다.
상세 원문: [152 호환성 조사·설치 기록](../archive/client/CLIENT_152_COMPATIBILITY_ASSESSMENT.md).

## 경계

- `C:\NIKKE`는 공식 launcher만 업데이트합니다. NLL 도구는 읽기 입력으로만 쓰고 실행 대상으로 삼지 않습니다.
- 새 버전은 새 후보입니다. 기존 lane이나 receipt를 새 버전으로 조용히 바꾸지 않습니다.
- 공식 로그인·토큰·통신 가로채기·메모리 주입을 쓰지 않습니다. 공개 metadata 익명 요청의 승인 범위는
  [보안 경계](../SECURITY_BOUNDARY.md)를 따릅니다.
- 자동 검사·설치 완료와 운영자 실게임 확인을 따로 기록합니다.

## 순서

1. **읽기 비교**: Unity PlayerSettings의 `bundleVersion`(Windows 파일 버전은 엔진 버전), `nikke.exe`·
   `GameAssembly.dll` hash, `sd.bin` 표, Addressables/dp/saus catalog 해석, 새 `StaticData.pack` 위치·hash를 기록합니다.
2. **StaticData 해석 설정**: 새 pack이 기존 gameconfig로 복호화되지 않으면 salt를 추정하지 않습니다. 152에서는
   공개된 EpinelPS 해당 버전 commit의 gameconfig를 commit SHA로 고정해 AES·서명·ZIP CRC·필수 표 검사를 통과시켰습니다.
3. **내용 비교**: 캐릭터·시즌·보스 행동/속성/QTE/FX 참조의 추가·변경을 기존 해석기로 비교합니다. 목록·이름·이미지
   해석 성공을 전투 실행 가능으로 해석하지 않습니다.
4. **client 복제·봉인**: `C:\NLL\Clients\NIKKE-<build>-ResourceProbe`로 복사하고 전체 manifest를 대조합니다.
   승인된 Epinel DLL과 client-local 인증서 overlay는 이 복제본에만 적용합니다. DLL은 2026-09-28 승인에 따라 새 버전마다
   재승인하지 않지만, 수정·재빌드하지 않은 같은 hash(`54ee18f5…5662`)일 때만 해당합니다. hash가 다르면 새 승인이 필요합니다.
5. **서버 후보**: 기존 NLL 변경을 유지한 별도 EpinelPS checkout에 upstream 버전 변경을 적용하고 서버 검사를 돌립니다.
   `resourcehosts2`는 upstream처럼 BaseUrl/Version만 돌려줍니다.
6. **리소스 안내 공급**: 외부 자동 다운로드를 끈 상태이므로 client가 요청하는 `latest-<n>.txt`와 native catalog·서명
   파일을 로컬에서 공급해야 합니다. 152에서는 이 누락으로 첫 실행이 4/7 단계(`DownloadPatch - Initialize failed`)에서
   멈췄고, 파일 15개를 hash 대조 후 공급해 해소했습니다.
7. **목록·계정 자료**: 운영 DB를 dump한 뒤 기존 importer로 새 불변 캐릭터 catalog snapshot을 추가하고 시즌 목록을
   갱신합니다. 기존 계정 revision·육성·진행도는 바꾸지 않습니다. 새 캐릭터 얼굴 초상화는
   `tools/AccountCollector/raid_portrait_assets.py`를 따로 실행합니다.
8. **등록 보스 재조립**: 기존 보스를 공통 조립기로 새 원본에서 다시 만들고 5약점 준비를 검사합니다. 전투 입력이
   바뀐 시즌(152에서는 S10·S26·S34)의 과거 기록은 보존하되 새 구성에 자동 상속하지 않습니다.
9. **native FX 기준 등록**: 새 client의 FX store를 한 번 검증해 별도 baseline/journal
   (`C:\NLL\RuntimeInputs\CommonBossExecution\native-fx-<build>`)에 등록합니다. 이전 버전 journal을 초기화하지 않습니다.
10. **검증·설치**: 필수 gate, 폐기 PostgreSQL 통합, 저장/복원 검사를 통과한 뒤 새 `PhaseD<build>-v1` bundle을
    `runtime-selection.private.json`으로 선택합니다. 방화벽의 복제본 규칙 경로를 새 client로 바꿉니다.
11. **이전 client 보관**: cold 상태에서 `D:\NikkeLocalLab\Backups\client-<build>-archive-<date>-01`로 복사하고 모든
    파일 hash를 대조한 뒤에만 C: 사본을 제거합니다. 이전 runtime bundle·cache·journal은 남깁니다.
12. **운영자 실게임 확인**: 로비 진입, 등록 보스 실행, 종료 후 기록 복원을 확인합니다.

경로와 현재 선택은 [경로 권위](../MICRON_CURRENT_PATHS.md)에 갱신합니다.
