# Windows 종료 후 실행 상태 복구 — 2026-09-22

> 2026-09-27 보관: 작성 당시의 기록이며 현재 작업 지시가 아닙니다. 현행 문서는 [문서 색인](../../README.md)에서 찾습니다.

운영자가 게임을 켜둔 채 Windows를 종료하고 다시 켠 뒤 `phase_d_runtime_not_cold`를 보고했다. 관리도구 종료 확인 후 해당 실행 한 건을 복구했다.

## 원인과 관측

- 실제 client/bootstrap/server 프로세스는 없지만 실행 상태가 `started`로 남아 있었다. 관리 API는 이 상태를 새 실행 차단 근거로 사용한다.
- 자동 복구는 봉인된 v3 runner의 기존 Windows Job을 열어 종료를 입증한다. 관리자 조회에서도 해당 Job은 Win32 오류 2로 존재하지 않았다. 기존 복구는 `phase_d_job_owner_unresolved`에서 중단되고 관리 API에는 `phase_d_orphan_recovery_failed`가 남았다.
- 실행 이후 Windows Kernel-Boot 이벤트 27의 `BootType=1`(빠른 시작)이 관측됐다. 커널의 `LastBootUpTime`은 이전 날짜로 유지되어, 그 시간만으로 실행 후 재시작을 판별하면 이 사례를 놓친다.
- 사라진 Job을 다시 만들거나 Job 종료 증거를 위조하지 않았다. 해당 실행에는 execution FX가 없었으며 이 복구를 FX가 적용된 실행에 일반화하지 않는다.

## 이번 복구

1. 관리도구 종료, maintenance/lifecycle lock, 봉인 hash, 실행 이후의 고정된 Boot 이벤트, Job 부재, 이전 PID/생성 시각 및 현재 대상 프로세스 부재를 대조했다. 관련 ACE 서비스도 실제 관리자 SCM 조회에서 `Stopped`/`Manual`임을 확인했다.
2. 실행 DB, 원복 기준 DB, hosts, 상태/context/pointer, 공유 차단 설정을 hash 검증하여 백업했다. PostgreSQL의 복구 전 논리 백업도 남겼다.
3. 원래 봉인된 capture/replay 함수와 materializer를 사용했다. 저장 결과는 `state_advanced`, 사용자 설정은 `state_advanced`, quarantine은 false였다. 저장 성공을 확인한 뒤에만 실행 DB와 hosts를 기준선으로 복원했다.
4. 공유 차단 설정을 저장된 이전 상태로 복원하고, 활성 pointer와 종료 감시기 신원을 보관했다. 해당 실행의 상태를 `completed`로 종료하고 pending을 정리했다. 이것은 저장/종료 복구 상태이며 중단 전 전투가 완주했다는 새로운 판정이 아니다.
5. 최종 확인: 활성 실행 0건, client/bootstrap/server 0개, 활성 pointer 없음, pending 없음, hosts 기준선 hash 일치. 기존 BattleLog와 봉인된 runner 파일, 공식 설치본은 변경하지 않았다. 게임은 재실행하지 않았다.

첫 시도에서 PowerShell `Start-Process -Wait`가 PostgreSQL 자손의 수명까지 기다렸다. DB 쓰기 전 단계였으며, 복구 도구가 시작한 DB를 정상 종료하고 pg_ctl 자체의 `WaitForExit()`만 기다리도록 보조 스크립트를 고친 뒤 재실행했다. 첫 실패 이력도 보존한다.

비공개 근거와 백업: `artifacts/shutdown-recovery-20260922/`. `recovery.receipt.json`, `final-verification.json`, `backup-*/database.dump`를 확인한다. 운영자 승인 복구 스크립트는 이 실행 UID·봉인 hash·Boot 이벤트에만 고정되어 있으며 일반 자동 복구 도구가 아니다.

## 남은 제품 작업

현재 실행 차단은 해소했다. **빠른 시작/재부팅 후 자동 복구의 일반 경로는 아직 변경하지 않았다.** 같은 Job이 없는 상태를 기존 same-Job proof로 위장하지 않는 별도 재시작 복구 계약이 필요하다. 빠른 시작과 일반 재부팅, PID 재사용, 관리자 접근 거부, FX 적용·미적용, 복구 중 다시 종료되는 경우를 나눠 검증해야 한다. 사용자 실게임 재실행 확인은 별도다.

작업 전후 광역 gate도 실행했다. Phase 0·Actions는 통과했고, repository origin 정책 및 제한된 NuGet 취약성 조회 `NU1900`으로 나머지 wrapper는 통과하지 못했다. 복구 상태 실측과 전체 repository 검증 통과를 구별한다.
