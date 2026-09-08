# Repository origin

- 이 저장소는 `Nikke-Dmg-Simulator`의 clone, fork, worktree, subtree가 아닙니다.
- 기존 저장소의 Git history를 상속하지 않는 독립 저장소입니다.
- 초기 commit에는 외부 프로젝트 코드나 게임 데이터가 없습니다.
- 향후 코드를 이관할 때는 파일 allowlist, 출처, upstream license를 먼저 검토합니다.
- 특히 외부 MemoryPack schema를 바탕으로 한 코드는 license와 attribution 확인 전까지 이관하지 않습니다.
- source repository는 사용자 소유의 **private GitHub repository**만 사용합니다.
- GitHub에는 정책 검사를 통과한 source, 계약, migration, 합성 fixture만 push합니다.
- 게임 파일·복호물·runtime state·compatibility map·실계정 데이터는 remote에 push하지 않습니다.
- 변경은 `agent/**` branch에서 Actions 검증 후 PR squash merge합니다. `main` 직접 push는 최초 bootstrap에만 사용합니다.

## EpinelPS reference 경계

- Phase 3A-R의 initial compatibility reference는 [`EpinelPS/EpinelPS`](https://github.com/EpinelPS/EpinelPS)이며 reviewed commit은 [`28b2f5413a0a1e3521a11ae162f91851335c8b40`](https://github.com/EpinelPS/EpinelPS/tree/28b2f5413a0a1e3521a11ae162f91851335c8b40), upstream license는 [AGPL-3.0](https://github.com/EpinelPS/EpinelPS/blob/28b2f5413a0a1e3521a11ae162f91851335c8b40/LICENSE)입니다.
- 이 저장소는 EpinelPS의 clone, fork, subtree 또는 submodule이 아니며 현재 upstream code를 vendor하지 않습니다. 초기 spike는 저장소 밖의 pinned 별도 checkout/process를 사용합니다.
- upstream generated protocol source, game data, certificate/private key, patched native binary, decoded cache와 client artifact는 이 저장소·GitHub Actions·release에 넣지 않습니다.
- 향후 EpinelPS 수정이 필요하면 별도 AGPL worktree/fork에서 수행하고, Local Lab에는 reviewed source-free loopback contract만 추가합니다. upstream code를 복사하거나 배포 형태를 바꾸기 전에는 license·attribution·source 제공 의무를 다시 검토합니다.
- 공개 저장소와 작동 사례는 기술 feasibility 근거이지 Shift Up 또는 배급사의 승인·허가·묵인 증거가 아닙니다. 이 저장소는 그런 승인을 주장하지 않습니다.
