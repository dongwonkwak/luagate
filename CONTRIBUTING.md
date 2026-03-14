# Contributing to LuaGate

사람 기여자를 위한 온보딩 가이드.

> AI 도구 가이드: [AGENTS.md](AGENTS.md) (코딩 컨벤션, 불변식) / [CLAUDE.md](CLAUDE.md) (Claude Code 워크플로우)

---

## 읽기 순서

```
README.md
  → docs/spec/architecture.md
  → 관련 spec (작업 영역별)
  → AGENTS.md (코딩 컨벤션, 불변식, 용어집)
  → CLAUDE.md (AI 개발 워크플로우 — 참고용)
```

---

## 시작하기

### 사전 요건

| 방법 | 필요 도구 |
|------|----------|
| **권장 (Nix)** | [Nix](https://nixos.org/download) + [direnv](https://direnv.net/) |
| 수동 | OpenResty 1.25+, LuaJIT 2.1, Rust 1.75+, CMake 3.20+, Node.js 20+ |

### 개발 환경 설정

```bash
# 1. 클론
git clone https://github.com/dongwonkwak/luagate.git
cd luagate

# 2. Nix 개발 셸 진입 (모든 의존성 자동 설치)
nix develop
# 또는 direnv 사용 시: direnv allow

# 3. Git hooks 설치 (필수)
make install-hooks

# 4. FFI 빌드
make build

# 5. 테스트 실행
make test-unit
```

### 로컬 실행

```bash
make up          # Docker Compose 기동
curl http://localhost:8080/health  # 확인
make down        # 종료
```

---

## 브랜치 전략

| 패턴 | 용도 |
|------|------|
| `main` | 항상 빌드 가능한 stable 상태 |
| `epic/NN-<name>` | Epic 단위 작업 |
| `dongwonkwak/don-NN-<slug>` | 개별 이슈 작업 |
| `hotfix/<description>` | 긴급 수정 |

- 이슈 브랜치는 Linear의 `gitBranchName` 패턴을 사용한다.
- main에 직접 push 금지. PR 필수.

---

## 커밋 메시지 형식

```
type(scope): 설명 [DON-XX]
```

| type | 설명 |
|------|------|
| `feat` | 새 기능 |
| `fix` | 버그 수정 |
| `docs` | 문서만 변경 |
| `test` | 테스트 추가/수정 |
| `refactor` | 리팩터링 |
| `chore` | 빌드/의존성/기타 |
| `perf` | 성능 개선 |

예:
```
feat(policy): implement first-match-wins evaluation [DON-42]
fix(scanner): handle NULL body in luagate_scan_http [DON-55]
docs(spec): update http-pipeline stream preread section [DON-90]
```

> `commitlint`이 pre-commit hook으로 형식을 자동 검사한다. (`make install-hooks` 후 적용)

---

## PR 규칙

1. **제목**: 커밋 메시지와 동일한 형식 `type(scope): 설명 [DON-XX]`
2. **본문**: `.github/pull_request_template.md` 자동 적용
3. **머지 전략**: Squash merge (epic → main)
4. **필수 조건**: CI 통과 (lint + unit test) + 최소 1개 승인

---

## 코딩 컨벤션 핵심

전체: [`.claude/knowledge/conventions.md`](.claude/knowledge/conventions.md)

- **Lua**: StyLua + luacheck. blocking I/O 핸들러 금지.
- **Rust**: `cargo fmt` + `cargo clippy --deny warnings`
- **FFI 함수명**: `luagate_<module>_<action>`
- **shared dict zone명**: `luagate_` prefix 필수
- **정책 캐시**: `ngx.ctx`에 저장 금지 — module-level upvalue 사용

---

## 테스트 규칙

| 변경 유형 | 필수 테스트 |
|----------|-----------|
| 정책 평가 로직 | `make test-unit-lua` |
| FFI 모듈 | `make test-unit-c` + `make test-unit-lua` |
| HTTP 파이프라인 | `make test-integration-http` |
| Stream 파이프라인 | `make test-integration-stream` |
| Hot Reload | `make test-reload` |
| 전체 | `make test` |

새 기능 = 새 테스트 필수.

---

## 문서 업데이트 규칙

- **same-PR 규칙**: 코드 변경과 관련 스펙 문서 변경은 같은 PR에 포함.
- 변경 유형별 업데이트 대상: [`docs/spec/doc-strategy.md`](docs/spec/doc-strategy.md) §4 참조.

---

## 리뷰 프로세스

1. CI 자동 실행 (lint + test)
2. 보안/설계 변경 시: 코드 리뷰 요청 (Linear 이슈에 명시)
3. 최소 1개 승인 후 머지

---

## 이슈 작업 절차

1. Linear 이슈 상태 → **In Progress**
2. 브랜치 생성 (`gitBranchName` 패턴)
3. 구현 + 테스트 + 문서
4. 커밋: `type(scope): 설명 [DON-XX]`
5. PR 생성 → CI 통과 → 리뷰 → 머지
6. Linear 이슈 → **Done** + 완료 코멘트 (파일 경로 포함)
7. `PROGRESS.md` 엔트리 추가

### 이슈 완료 기준

- [ ] 코드 구현 완료
- [ ] 테스트 추가/통과
- [ ] 관련 스펙 준수 (AGENTS.md 불변식)
- [ ] 문서 갱신 (same-PR)
- [ ] Linear 코멘트: 구현 파일 경로 포인터 포함
- [ ] PROGRESS.md append

---

## 용어집

→ [AGENTS.md §용어집](AGENTS.md) 참조
