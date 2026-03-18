# LuaGate 코딩 & 커밋 & 브랜치 컨벤션

## 코딩 컨벤션

### Lua
- 포매터: **StyLua** (`stylua --indent-type Spaces --indent-width 4`)
- 린터: **luacheck** (`.luacheckrc` 설정 기준)
- 모듈 구조: `lua/luagate/<subsystem>/` 아래 기능별 분리
- 전역 변수 금지: 모든 상태는 module-level upvalue 또는 `ngx.ctx.luagate` (요청 범위)
- blocking I/O 금지: `io.open`, `os.execute` 등 Lua 표준 blocking I/O는 핸들러에서 사용 금지
- `ngx.ctx` 사용 범위: 요청 단위(request-scoped) 데이터만 저장. 정책 캐시는 module-level upvalue 사용

### C / Rust
- 포매터: **clang-format** (`.clang-format` 기준, C 헤더가 있는 경우)
- Rust: `cargo fmt` + `cargo clippy --deny warnings`
- FFI 함수 명명: `luagate_<module>_<action>` (예: `luagate_scan_http`)
- Panic 전략: `panic = "abort"` — Rust panic 시 worker 즉시 abort (UB 방지)

### 테스트
- Lua 단위 테스트: **busted** 프레임워크, 한국어 서술형 BDD 스타일
- 통합 테스트: **Test::Nginx** (Docker 기반)
- Rust 단위 테스트: **cargo test**
- 커버리지 목표: 핵심 패스(policy evaluation, scanner) 80%+
- OWASP 페이로드 픽스처: `tests/fixtures/` 에 저장

예시:
```lua
-- tests/unit/policy/evaluator_test.lua
describe("정책 평가기", function()
    describe("HTTP 규칙 평가", function()
        it("deny 규칙이 allow보다 낮은 priority면 먼저 매칭된다", function()
            -- 참조: lua/luagate/policy/evaluator.lua:45-89
            -- 테스트: tests/unit/policy/evaluator_test.lua
        end)
    end)
end)
```

테스트 링크 패턴 — 코드 예시에 항상 포함:
```lua
-- 구현: lua/luagate/<subsystem>/<module>.lua:<line_range>
-- 테스트: tests/unit/<subsystem>/<module>_test.lua
```

## 커밋 메시지 형식

```
<type>(<scope>): <description> [DON-XX]

[optional body]
```

### type 종류
| type | 설명 |
|------|------|
| `feat` | 새 기능 |
| `fix` | 버그 수정 |
| `docs` | 문서만 변경 |
| `test` | 테스트 추가/수정 |
| `refactor` | 리팩터링 |
| `chore` | 빌드/의존성/기타 |
| `perf` | 성능 개선 |

### scope 예시
`lua`, `ffi`, `policy`, `scanner`, `admin`, `stream`, `docker`, `claude`, `spec`

### 예시
```
feat(policy): add conflict detection for stream rules [DON-42]
fix(scanner): handle NULL body in luagate_scan_http [DON-55]
docs(spec): add stream preread invariant [DON-90]
```

## 브랜치 전략

| 브랜치 패턴 | 용도 |
|------------|------|
| `main` | 항상 빌드 가능한 stable 상태 |
| `epic/NN-<name>` | Epic 단위 작업 |
| `dongwonkwak/don-NN-<slug>` | 개별 이슈 작업 |
| `hotfix/<description>` | 긴급 수정 |

- PR: Epic 브랜치 → main
- 이슈 브랜치: Linear 자동 생성 패턴(`gitBranchName`) 사용. **한글 포함 시 제거 후 연속 하이픈 정리**
  - 예: `dongwonkwak/don-106-git-hooks-설정-pre-commit` → `dongwonkwak/don-106-git-hooks-pre-commit`
- merge strategy: squash merge (epic → main), merge commit (issue → epic)

## 파일 경로 포인터 컨벤션

코드와 문서 변경은 같은 PR에 포함 (same-PR 규칙).
Linear 코멘트에 파일 경로 포인터 포함:
```
구현 파일: lua/luagate/policy/evaluator.lua:45-89
테스트 파일: tests/unit/policy/evaluator_test.lua
```

## Git Hooks

`pre-commit` 프레임워크로 관리. `.pre-commit-config.yaml` 참조.

### 설치

```bash
make install-hooks
```

### pre-commit (매 커밋, 목표 < 3초)

| Hook | 대상 | 도구 |
|------|------|------|
| Lua 포맷 | `lua/**/*.lua`, `tests/**/*.lua` | `stylua --check` |
| Lua 린트 | `lua/**/*.lua`, `tests/**/*.lua` | `luacheck` |
| C 포맷 | `*.c/h` (있는 경우) | `clang-format --dry-run --Werror` |
| Shell 린트 | `scripts/**/*.sh` | `shellcheck` |
| Markdown 린트 | `docs/**/*.md`, `*.md` | `markdownlint` |
| 후행 공백 / 개행 | 전체 | pre-commit built-in |
| 시크릿 방지 | 전체 | `detect-secrets` |
| main 직접 커밋 방지 | — | `no-commit-to-branch` |

### commit-msg

`commitlint`로 Conventional Commits 형식 강제:
```
type(scope): description [DON-XX]
```

### pre-push (느린 검사, push 시만)

| Hook | 내용 |
|------|------|
| `make test-unit` | busted 단위 테스트 (~10초) |
| `cargo clippy` | Rust 정적 분석 |
| `luacheck` 전체 | 전체 프로젝트 린트 |

## PR 컨벤션

### PR 제목
형식: `type(scope): 설명 [DON-XX]`
커밋 메시지와 동일한 Conventional Commits 형식.

예:
```
feat(policy): implement first-match-wins evaluation [DON-98]
docs(readme): revamp quick start and port table [DON-108]
```

### PR 본문
`.github/pull_request_template.md` 자동 적용.

### 리뷰 프로세스
1. CI (lint + test) 자동 실행
2. `request-codex-review` 스킬로 Codex 리뷰 요청 (보안/설계 변경 시)
3. 보안 관련 변경: `security-reviewer` 에이전트 호출 권장
4. 최소 1개 승인 필요

### 머지 전략
- **Squash merge** (epic → main): 깔끔한 main 히스토리
- **Merge commit** (issue → epic): 이슈별 히스토리 보존
- 머지 후 브랜치 자동 삭제

### 브랜치 보호 규칙
- main 직접 푸시 금지 (PR 필수)
- CI(lint + test) 통과 필수
- 최소 1개 리뷰 승인
