# 코드 리뷰 체크리스트

> 커버리지 상태: ✅ 커버 / ⚠️ 부분 커버 / ❌ 누락

## 일반 규칙

- [ ] ✅ 커밋 메시지 형식 준수 (`type(scope): description [DON-XX]`)
- [ ] ✅ 코드와 문서 변경이 같은 PR에 포함 (same-PR 규칙)
- [ ] ✅ 전역 변수 없음 (module-level upvalue 또는 ngx.ctx 사용)
- [ ] ✅ Linear 코멘트에 파일 경로 포인터 포함
- [ ] ✅ StyLua / cargo fmt / cargo clippy 통과 (clang-format은 C 헤더가 있는 경우)

## Lua 핸들러

- [ ] ✅ Blocking I/O 없음 (`io.open`, `os.execute` 등 핸들러 내 사용 금지)
- [ ] ✅ `ngx.ctx.luagate`에 요청 범위 데이터만 저장 (정책 캐시 금지)
- [ ] ✅ 정책 캐시는 module-level upvalue 사용 (`_cached_policy`, `_cached_version`)
- [ ] ✅ `ngx.worker.id()` 사용 (PID 아님)
- [ ] ✅ zone prefix `luagate_` 필수 (shared dict 이름)
- [ ] ⚠️ `table.sort` 사용 시 stable sort (original_index 비교 포함)
- [ ] ✅ `*_by_lua_block` 또는 `*_by_lua_file` 사용 (구식 inline 금지)

## 로깅 규칙

- [ ] ✅ `log_by_lua`에서 cosocket (네트워크 I/O) 사용 없음
- [ ] ✅ Lua로 access_log를 대체하지 않는다 — Nginx native `access_log` + `log_format luagate_json` 사용
- [ ] ✅ log phase에서 외부 I/O 금지 (파일/소켓 쓰기 불가 — OpenResty 제약)
- [ ] ✅ Lua `io.open`/`io.write`로 access_log 직접 작성 금지 (rotate 후 구 파일에 계속 씀)
- [ ] ✅ native access_log hot reload semantics: USR1 시그널은 Nginx 관리 파일 핸들에만 작용. Lua가 직접 연 파일 핸들은 rotate 영향을 받지 않는다.
- [ ] ⚠️ PII 필드 redaction 적용 (Authorization, Cookie, password 파라미터)

## FFI 코드

- [ ] ✅ `pcall` 래핑 여부
- [ ] ✅ Rust 할당 메모리 → Rust free 함수로 해제 (`luagate_*_free()` 호출)
- [ ] ✅ C 포인터를 Lua 테이블에 장기 저장 금지 (즉시 Lua 값으로 복사)
- [ ] ✅ NULL 반환 처리 (fail-closed: deny)
- [ ] ✅ `ffi.cast` 사용 시 Lua 변수 수명 관리
- [ ] ✅ ffi.gc 또는 명시적 free 중 하나로 누수 방지

## 보안

- [ ] ✅ 보안 경로 fail-closed (에러 → deny)
- [ ] ✅ Admin API: 타이밍 안전 토큰 비교 (constant-time compare)
- [ ] ✅ Admin API: 127.0.0.1 바인딩만 (외부 노출 없음)
- [ ] ✅ 인증 실패 감사 로그 기록
- [ ] ✅ SQL injection / XSS / path-traversal: OWASP 페이로드 테스트 포함
- [ ] ⚠️ 스캐너 hit + 정책 allow 시에도 deny (precedence matrix 준수)

## 정책 평가

- [ ] ✅ first-match-wins 평가 순서 (priority 오름차순 정렬)
- [ ] ✅ 동률 priority 시 stable sort (YAML 선언 순서 유지)
- [ ] ✅ 기본 정책 `deny` (default_action: deny)
- [ ] ✅ stream 파이프라인: `preread_by_lua`에서 탐지 + 평가 (access_by_lua 단계 없음)
- [ ] ⚠️ 충돌/음영 규칙 경고 로그 확인

## Hot Reload

- [ ] ✅ reload pipeline 7단계 준수 (staged → validate → hash → blob → pointer swap)
- [ ] ✅ 실패 시 LKG(last-known-good) 유지 (active pointer 변경 없음)
- [ ] ✅ `safe_set` no-memory 에러 경로 처리
- [ ] ✅ versioned keyspace 사용 (`policy:<hash>:blob`)

## 테스트

- [ ] ✅ 새 기능에 대한 busted 단위 테스트 추가
- [ ] ✅ 한국어 서술형 BDD 스타일 (`describe/it`)
- [ ] ✅ OWASP 페이로드 픽스처 사용 (`tests/fixtures/`)
- [ ] ⚠️ FFI 모듈: Rust cargo test + Lua integration test 양쪽
- [ ] ❌ 성능 회귀 테스트 (p99 < 1ms for FFI) — 현재 자동화 없음

## 문서

- [ ] ✅ spec 변경 시 관련 ADR 참조 또는 새 ADR 마커 추가
- [ ] ✅ `<!-- ADR 필요 -->` 마커: 2개 이상의 대안이 있거나 설계 결정 필요 시
- [ ] ✅ 새 API 엔드포인트: `docs/spec/admin-api.md` 갱신
- [ ] ✅ 로그 스키마 변경: `docs/spec/log-schema.md` 갱신
- [ ] ⚠️ PR body에 `<!-- PROGRESS -->` 블록 포함 (머지 시 자동 append)
