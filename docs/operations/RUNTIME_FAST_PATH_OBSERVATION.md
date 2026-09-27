# 실행·종료 단축을 위한 미확정 구간 집중 조사

작성: 2026-09-15. 상위 계획: [공통 실행·FX 전달과 G1~G3](P2_3_RUNTIME_FX_BINDING.md).
**후속 결정:** 운영자가 매 실행의 전체 검증 요구를 재설정했다. 아래 ETW/지속 핸들 조사와
합성 결과는 기술 자료로 보존하지만, G1~G3를 속도 개선의 필수 순서로 적용하지 않는다.
현행 방향은 상위 문서의 「검증 범위 재설정」에 따른 작은 변경의 멱등성과 빠른 실행이다.
운영자가 확인한 속성 쉴드 정상 동작은 유지한다. 이번 작업은 읽기 조사와 합성 진단이며
최적화 구현·설치·실게임 검증 완료가 아니다. 게임·CDB·음성·DB를 변경하지 않았다.

## 판정

1. **가장 큰 단축 대상은 여전히 매 실행/종료의 6.6GB CDB 전체 검산이다.**
   준비 검사 중복과 PostgreSQL 재시작이 같은 크기의 병목이라는 가설은 이번 측정으로
   뒷받침되지 않았다. 먼저 큰 비용을 없앨 조건을 확인한다.
2. **실제 게임이 CDB를 어떤 접근·공유 옵션으로 여는지는 아직 미확정이다.**
   기존 관측에는 필드·이벤트·주체·시간 순서의 결손이 있다. 과거 read 기록이나
   `eventsLost=0`만으로 지속 핸들 방식의 호환/무결성을 승인하지 않는다.
3. 합성에서 공유 옵션, 실패한 open, 쓰기와 매핑을 구별할 방법을 확인했다.
   다만 이 조사용 prototype을 그대로 실게임 observer 또는 실행 승인기로 쓰지 않는다.
   실제 파일 신원과 수명에 따라 이벤트를 결합하는 작업이 남아 있다.

## 1. 관측 방법에서 추가로 확인한 결손

기존 자료는 `artifacts/native-fx-runtime-20260912/trace-reader/Observation.cs`다.
`FileIOCreate`와 `FileIORead`를 정확한 Job/client PID에 한정해 저장하지만,
공유 옵션·쓰기·매핑·요청 완료 상태는 보존하지 않는다. 실제 게임의 raw ETL은 해당
관측이 생성하지 않았으므로 JSON에 없는 필드를 나중에 복원할 수 없다. 같은 폴더의
`io-test-*/files.private.etl`은 합성 self-test이며 게임 증거가 아니다.

| 항목 | 확인 결과 | 후속 관측에서 필요한 처리 |
| --- | --- | --- |
| 접근 권한 | 사용 중인 `FileIOCreateTraceData` 및 Windows `FileIo_Create` schema에 `DesiredAccess` 없음 | `CreateOptions`나 `ShareAccess`를 접근 권한으로 해석하지 않음. 별도 근거가 없으면 `unresolved` |
| 공유 옵션 | `ShareAccess`는 존재하며 합성에서 1(Read), 3(ReadWrite)를 구별 | 숫자 원본과 해석을 함께 기록 |
| open 성공 여부 | 공유 충돌로 실패한 요청도 `open_request` 이벤트 발생 | `IrpPtr`를 `FileIOOperationEnd.NtStatus`에 연결. 완료 결손은 성공 처리 금지 |
| 매핑 이벤트 선택 | 기존 `FileIO/FileIOInit/Process/Thread` 구성에서 실제 매핑을 해도 map 0건 | `VAMap` 선택을 추가하고 합성 양성 대조로 수집 확인 |
| 파일 이름 연결 시점 | 자체 map 발생 시 파일 이름 미해소, 뒤의 write/unmap에서 같은 `FileKey` 연결 가능 | 미해소 이벤트를 즉시 버리지 않고 한도 내 보류. 수명·순서 확인 후 결합 |
| 주체 | 합성 파일에서 자체 프로세스 외 System(PID 4)의 쓰기 이벤트도 관측 | 파일 변경 관측을 게임 PID에만 한정하지 않음. 이벤트 PID를 최초 쓰기 주체로 단정하지 않음 |
| 다른 프로세스의 map | 검사 프로그램의 map과 별도로 동일 합성 파일에 대한 다른 PID의 map 관측 | 파일에 map이 있다는 사실과 게임이 map했다는 사실을 구분 |
| 손실 카운터 | 잘못된 구독/필터에서도 `eventsLost=0` 가능 | 손실 0은 필수지만 충분조건이 아님. 필드/이벤트별 양성·음성 대조 필요 |

`FileObject`와 `FileKey`는 ETW 이벤트 연결용 식별자이며 디스크의 영속 file ID가 아니다.
재사용·close/rundown·지연 이벤트를 고려하지 않은 사전 조회 결과를 물리 파일 신원으로
승격하면 안 된다. 이름만 같거나 System PID라는 이유로 이벤트를 수락/제외하지 않는다.

근거: [Microsoft FileIo_Create schema](https://learn.microsoft.com/en-us/windows/win32/etw/fileio-create),
[Microsoft TraceEvent parser source](https://github.com/microsoft/perfview/blob/main/src/TraceEvent/Parsers/KernelTraceEventParser.cs).
현지 검사에 사용한 TraceEvent DLL은 3.2.6.0이다. 설치 DLL의 reflection 결과도 receipt에
기록했으며, 위 upstream의 현재 상태를 설치 버전과 동일하다고 가정하지 않았다.

## 2. 합성 시험과 정확한 한계

근거 루트는 `artifacts/common-boss-execution-20260914/startup-investigation-20260915/`다.
`io-semantics-probe/Program.cs`와 `Probe.csproj`, `run-io-semantics-elevated.ps1`로 재현한다.
기존 승인 범위의 관리자 진단을 사용했으며 매번 새 4KiB 파일 다섯 개만 만들었다.
대상 DLL 실행/주입, 프로세스 메모리 내용 읽기, raw ETL 저장, journal/audit 설정 변경,
새 드라이버/서비스 설치는 하지 않았다. 자기 프로세스의 매핑 이벤트 메타데이터만
미해소 대조에 추가 보존했다.

| 시험 | 결과 |
| --- | --- |
| read + share Read / read + share ReadWrite | 둘 다 실제 성공, 공유 값 1/3 및 완료 상태 `00000000` 확인 |
| 별도 작은 명시적 쓰기 | byte 변경과 write 이벤트 확인 |
| ReadWrite 소유 핸들 + share Read 중 read + share Read | 호출은 공유 충돌로 거절, ETW에는 open 요청과 `c0000043` 완료 상태 기록 |
| writable mapping 유지 후 원래 FileStream 닫기 | mapping을 통한 byte 변경 성공. 그 사이 새 배타적 write 통제 핸들은 공유 충돌로 거절 |
| 기존 키워드 구성 | 실제 map 수행에도 map 기록 0; 이벤트 손실 0 |
| VAMap 추가 | map 이벤트가 발생하지만 자체 map은 당시 이름 미해소로 경로 필터에서 탈락 가능 |
| 자체 미해소 map도 별도 계수 | 4KiB 자체 map → 같은 FileKey의 write → 자체 unmap 연결을 확인. System write도 같은 key로 뒤이어 관측 |

첫 실행은 ETW provider보다 Source를 먼저 연 초기화 순서 오류로 실패했다. 수정 전 로그는
`io-semantics-initial-failed.log`에 보존했다. 이후 각 실험의 성공은 해당 probe 종료와
요청 수집 성공을 뜻하며 실제 게임 호환 또는 완성된 observer 인수를 뜻하지 않는다.

주요 receipt:

- `synthetic-io-4e0a870b7f084b2db9d7901cac802cf4/receipt.json`: 기존 키워드 구성.
- `synthetic-io-c1e89022cb5c4460bddd353a6e7d0626/receipt.json`: VAMap 추가. 경로에 연결된
  map이 다른 프로세스에서 발생한 것이므로 자체 map 수집 완료로 해석하지 않는다.
- `synthetic-io-999caa95adc84d5d943d1e024194b0d4/receipt.json`: 자체 미해소 이벤트도
  기록. 자체 map은 04:50:15.7842522Z, write는 .7860823Z, 자체 unmap은 .7870066Z다.
  마지막 unmap 시점에는 이름이 연결됐지만 최초 map 시점에는 연결되지 않았다.

세 시험 모두 `eventsLost=0`, `overflow=false`였다. writable mapping 시험은 작은
합성 파일에서 이 핸들 조합을 확인한 것이며, 모든 Windows mapping/권한 조합의 증명이 아니다.
초기 파일 생성의 지연 flush도 추적 구간에 나타날 수 있으므로, System write의 정확한
원래 호출자/원인을 이 기록만으로 지정하지 않는다.

## 3. 공통 준비 검사와 종료 잔여 시간

`PhaseDExecution.StartAsync`는 실행 state 생성 전에 `PrepareAsync`와 계정 snapshot을
수행한다. `PowerShellPhaseDPreparationService`는 캐시 없이 요청을 직렬화하고,
coordinator도 `Get-PhaseDPreparation`을 재실행한다. 활성화 직전에는 bundle 검사를
다시 한다. 따라서 기존 state→게임 28초/125초는 실제 UI 클릭→게임 전체 시간이 아니다.

읽기 전용 `probe-readonly-preparation.ps1`로 설치된 v8을 새 PowerShell 프로세스에서
각 한 번 호출했다. 본래 hash 함수를 그대로 호출하며 호출 수/읽은 길이/시간만 계측했다.
구성 검사의 성공값은 세 경우 모두 `ready`였다.

| 입력 | 준비 함수 시간 | bundle hash 호출/누적 입력 | bundle hash 소요 |
| --- | ---: | ---: | ---: |
| S26 / UI 수냉 | 0.799초 | 173회 / 133,035,301B | 0.483초 |
| S29 / UI 철갑 → 보스 전격 원본 FX | 1.289초 | 175회 / 133,037,363B | 0.492초 |
| S29 / UI 수냉 → 보스 작열 보정 FX | 1.247초 | 175회 / 133,037,363B | 0.485초 |

이는 각각 단일 표본이다. PowerShell 자체 시작, API queue/계정 snapshot 시간은 제외된다.
C# delivery 내부 hash는 준비 총시간에 포함되지만 bundle hash의 byte/호출 소계에는
포함되지 않는다. 파일 캐시 상태를 통제하지 않았으므로 cold 성능이나 p95로 주장하지 않는다.
원본 FX와 보정 FX의 이 준비 비용이 비슷하고 약 1초대인 만큼, 이 중복을 먼저 제거해도
수십 초의 CDB 비용을 해결하지 못한다. 큰 병목 해결 후 공통 검증 재사용을 검토한다.
근거는 `readonly-preparation-26-water.receipt.json`, `readonly-preparation-29-iron.receipt.json`,
`readonly-preparation-29-water.receipt.json`이다.

기존 보정 실행 `90a14232-b653-4dcf-a565-172fa1c7d233`의 종료 후 구간도 좁혔다.
각 시점은 실행 루트의 child identity, hosts restoration receipt, execution-state에서 읽었다.

| 구간 | 시간 | 해석 |
| --- | ---: | --- |
| completion child 생성 → hosts 복원 receipt | 5.106초 | 완료 검증/처리 및 hosts 복원 합산. 개별 비용은 미계측 |
| hosts 복원 → pg_ctl child 생성 | 1.159초 | 정리 checkpoint 등 중간 처리 합산 |
| pg_ctl child 생성 → 최종 completed | 1.010초 | PostgreSQL 시작·진행도 영속화·상태 기록 합산 |

따라서 이 실행에서는 PostgreSQL 재시작 자체가 수십 초 병목일 수 없다. FX 복구 약
59.94초가 우선 대상이다. 위 표만으로 DB 재시작 제거 또는 진행도 저장 생략을 결정하지 않는다.

## 4. G1~G3의 구체화

G1은 다음 두 질문을 분리한다.

- **관측 자체가 충분한가:** 올바른 event keyword, open 완료 연결, 늦은 파일 이름 해소,
  물리 파일 신원 및 FileObject/FileKey 수명, 게임/다른 프로세스/System 주체 구분,
  손실/overflow/미해소 건수와 수집 시작 시점이 확인되어야 한다. 원래 핸들을 닫아도 남는
  mapping, 실패 open, 다른 프로세스 접근, 파일 교체와 객체 식별자 재사용을 합성 검사한다.
- **실제 게임과 통제 핸들이 호환되는가:** 운영자 실행에서 CDB의 성공한 open별 공유 옵션과
  write/mapping 요청을 확인한다. `DesiredAccess`는 별도 출처가 없으면 미확정으로 남긴다.
  기존 read-only 관측을 보충하는 것만으로 접근 권한까지 증명하지 않는다.

판정 순서:

1. 성공한 게임 open의 공유 옵션이 기존 write 소유와 충돌한다면, 현재 제안한
   ReadWrite 지속 핸들 방식은 그 시점에서 탈락한다. 게임 open 옵션을 바꾸지 않는다.
2. 공유 옵션이 호환되어도 필요 write 권한·writable mapping·다른 writer가 남아 있는지
   확인해야 한다. **share ReadWrite는 실제 ReadWrite 접근의 증거가 아니다.**
3. ETW는 호환성 진단 자료다. 무결성 권위는 최초 검산부터 이어지는 통제 핸들/소유권으로
   증명한다. 이벤트 미발견만으로 정상 실행의 전체 hash를 생략하지 않는다.
4. 이 조건에 맞춰 G2를 진행한다. 정상 작은 조각 적용/원복뿐 아니라 기존 mapping,
   외부 쓰기/교체, 인계 공백, 소유자 crash와 부분 쓰기 실패를 검증한다. 통제 연속성이
   끊기면 빠른 경로를 무효화하고 기존 정밀 복구로 돌아간다.
5. G1/G2를 통과한 뒤에만 공통 실행기/UI에 연결하는 G3와 설치를 진행한다.
   실제 게임 실행은 운영자가 한다. 관측 미완성을 사용자에게 반복 실행으로 떠넘기지 않는다.

보스·속성·profile 버전별 새 부팅 분기는 만들지 않는다. HTTP/provider 재설계는 지속
핸들 호환이 실제로 탈락했을 때 검토할 대안으로 남긴다. 현재 성공한 쉴드 FX의 조립이나
조건을 다시 조사·변경하는 작업으로 범위를 넓히지 않는다.
