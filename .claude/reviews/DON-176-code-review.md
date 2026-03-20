# Codex Review: DON-176 — Security fuzzing — luagate_scanner.so + luagate_decoder.so (cargo fuzz + CI weekly) (code)

## 리뷰 유형

코드 리뷰 — 구현 정확성, 보안, 테스트 완전성 검토

## 변경 파일 목록

```
src/scanner/Cargo.toml                              (수정 — crate-type에 "lib" 추가)
src/decoder/Cargo.toml                              (수정 — crate-type에 "lib" 추가)
src/stream/Cargo.toml                               (수정 — crate-type에 "lib" 추가)
src/scanner/fuzz/Cargo.toml                         (신규)
src/scanner/fuzz/fuzz_targets/fuzz_scanner.rs       (신규)
src/scanner/fuzz/corpus/fuzz_scanner/*              (신규 — 11개 seed)
src/decoder/fuzz/Cargo.toml                         (신규)
src/decoder/fuzz/fuzz_targets/fuzz_decoder.rs       (신규)
src/decoder/fuzz/corpus/fuzz_decoder/*              (신규 — 11개 seed)
src/stream/fuzz/Cargo.toml                          (신규)
src/stream/fuzz/fuzz_targets/fuzz_sni.rs            (신규)
src/stream/fuzz/corpus/fuzz_sni/*                   (신규 — 11개 seed)
.github/workflows/fuzz.yml                          (신규)
```

## 관련 스펙 문서

- `docs/spec/rust-ffi-modules.md` — FFI ABI 계약, 에러 코드
- `docs/spec/security-scanner.md` — 스캐너 사양
- `AGENTS.md` — 불변식

## Acceptance Criteria

- [x] 3개 fuzz target 작성
- [x] `cargo fuzz run fuzz_scanner` 로컬 실행 가능
- [x] CI weekly fuzz job 추가
- [x] 초기 seed corpus 10개 이상

## 적용 불변식 (AGENTS.md)

- `luagate_` prefix 필수 — 모든 ngx.shared.DICT zone 이름
- fail-closed — 스캐너/디코더/FFI 에러 시 deny
- `ngx.worker.id()` 사용 (`ngx.worker.pid()` 금지)
- Hot Reload 7단계 준수 (staged → validate → hash → blob store → pointer swap)
- same-PR 규칙 — 코드 변경과 문서/spec 변경은 같은 PR에 포함
- FFI free 함수 호출 의무

## 리뷰 체크리스트

참조: `.claude/knowledge/review-checklist.md`

### 코드 품질

- [ ] 불변식 위반 없음
- [ ] 에러 핸들링 (fail-closed)
- [ ] 테스트 커버리지 충분
- [ ] blocking I/O 없음 (핸들러 내 io.open, os.execute 등)
- [ ] ngx.ctx에 정책 캐시 저장 없음

### 보안

- [ ] 인증/인가 처리
- [ ] PII 레독션
- [ ] OWASP 패턴 적용

### 문서

- [ ] spec/ADR 갱신 여부
- [ ] same-PR 규칙 준수

## 리뷰 관점 안내

역할: 찾기만, 수정 없음

발견한 문제점을 result.md 형식으로 출력하라. 코드를 직접 수정하거나 수정 방법을 실행하지 말 것.
수정은 사람의 별도 지시로만 수행한다.

## 결과 출력 형식

결과는 반드시 아래 포맷으로만 출력하라. 헤더/구조를 임의로 변경하지 말 것.

```
# 리뷰 결과: DON-176-code

## 1차 리뷰 (YYYY-MM-DD)

- [ ] 발견된 문제 1
- [ ] 발견된 문제 2
```

규칙:
- 각 항목은 반드시 `- [ ]` 로 시작
- 헤더(`#`, `##`)는 위 포맷 외 추가 금지
- 문제가 없으면 `- [ ] 없음` 한 줄만 출력

참조: `.claude/skills/request-codex-review/result-template.md`

결과 파일 경로: .claude/reviews/DON-176-code-result.md
