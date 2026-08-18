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
