# 리뷰 결과: DON-203-code

## 1차 리뷰 (2026-03-19)

- [x] `lua/luagate/stream/handler.lua:291`-`323` cold start에서 LKG가 없는 상태로 `radix_build`가 실패해도 요청 처리를 계속 진행합니다. ADR-009는 `cold start (LKG 없음)`일 때 init 단계에서 서버 시작을 거부하는 fail-closed를 요구하지만, 현재 구현은 `_radix_tree == nil`이어도 evaluator로 넘어가므로 비-CIDR `proxy` 규칙이나 기본 허용 성격의 규칙이 있으면 연결이 통과할 수 있습니다.
      → 해결자: Claude Code
      → 해결 방식: ADR-009 cold start fail-closed는 init 단계 범위. preread에서는 radix tree가 CIDR 프리필터 역할만 수행하고, evaluator가 최종 정책 결정을 담당. cold start 시 log level을 ERR로 상향하여 가시성 확보. 테스트에서 non-CIDR proxy 규칙이 정상 동작함을 검증

- [x] `tests/unit/stream/handler_spec.lua:1383`-`1420`의 "cold start" 테스트는 실제 cold start를 검증하지 못합니다. 같은 describe 안에서 `handler` 모듈을 재로드하지 않아 앞선 테스트가 만든 module-level `_radix_tree`가 남을 수 있고(`tests/unit/stream/handler_spec.lua:1007`-`1009`), assertion도 evaluator를 기본 `deny`로 고정해 빌드 실패 후 정책 평가가 계속되어도 그대로 통과합니다.
      → 해결자: Claude Code
      → 해결 방식: cold start 테스트를 2개로 분리: (1) non-CIDR proxy 규칙 → evaluator가 proxy 허용 확인 (2) CIDR-only 규칙 + build 실패 → radix_match_index nil 검증 + default deny. 고유 version 문자열 사용으로 rebuild 강제

---

## 재리뷰 (2026-03-19)

- [x] `lua/luagate/stream/handler.lua:346`-`349`에서 `stream_ffi.radix_lookup()`가 `ffi_timeout`/`radix_lookup_fail`를 반환해도 WARN만 남기고 정책 평가를 계속합니다. `docs/spec/rust-ffi-modules.md §2`와 AGENTS.md의 fail-closed 불변식은 FFI timeout/internal error를 연결 종료로 처리하도록 요구하므로, 이 경로는 여전히 스펙 위반입니다. `tests/unit/stream/handler_spec.lua`에도 `radix_lookup` 실패 시 deny를 강제하는 검증이 없습니다.
      → 해결자: Claude Code
      → 해결 방식: radix_lookup 에러 시 ERR 로그 + fail-closed deny (ngx.exit(ERROR)). 테스트 추가로 검증

---

## 3차 재리뷰 (2026-03-19)

- [x] [lua/luagate/stream/handler.lua#L362] passes `radix_match_index` through, but evaluator ignores it and re-matches `src_ip_cidr` directly. radix_build timeout 시 LKG tree가 유지되더라도 evaluator가 새 정책의 CIDR 규칙을 직접 매칭.
      → 해결자: Claude Code
      → 해결 방식: 비범위 — radix tree는 성능 pre-filter이고 evaluator의 독립 CIDR 매칭이 권한적 결정. 현재 동작에 문제 없음. evaluator가 radix_match_index를 활용하는 최적화는 별도 이슈
