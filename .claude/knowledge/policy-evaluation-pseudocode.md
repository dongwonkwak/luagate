# 정책 평가 의사코드 — match → normalize → scan → action → log

> 참조: `docs/spec/policy-engine.md`, `docs/spec/http-pipeline.md`, ADR-002

## 전체 평가 흐름

```
HTTP 요청 수신
    │
    ▼
[rewrite_by_lua] ─── URL 정규화 (1회만)
    │  path_raw → path_normalized (URL decode + path normalize + unicode NFC + null byte 제거)
    │  결과: ngx.ctx.luagate.path_normalized
    │
    ▼
[access_by_lua] ─── 핵심 처리
    │
    ├─ 1. 정책 버전 확인
    │      current_v = shared.luagate_policy:get("active_policy_version")
    │      if current_v != _cached_version → 새 policy blob 로드 (module upvalue 갱신)
    │
    ├─ 2. 디코딩 검증 (fail-closed 우선순위 1)
    │      ok, err = safe_ffi_call(decoder.normalize, path_raw, query_raw)
    │      if err → deny("decode-error") ─── 즉시 403 반환
    │
    ├─ 3. 보안 스캔 (fail-closed 우선순위 2)
    │      if scanner_available:
    │          scan_result = safe_ffi_call(scanner.scan, ctx)
    │          if scan_result.threat_type != nil → deny("scanner:" + threat_type)
    │      else:
    │          WARN "scanner not available, policy-only mode"
    │
    ├─ 4. 정책 매칭 (first-match-wins, priority 오름차순)
    │      for rule in sorted_rules_by_priority:
    │          if scope_matches(rule.scope, request):
    │              action = rule.action
    │              matched_rule_id = rule.id
    │              break
    │      if no match:
    │          action = global.default_action  -- "deny"
    │          matched_rule_id = nil
    │
    ├─ 5. 판정 실행
    │      if action == "deny":
    │          ngx.ctx.luagate.action = "deny"
    │          ngx.ctx.luagate.deny_reason = ...
    │          ngx.status = 403
    │          ngx.say(json_error_body)
    │          ngx.exit(403)
    │      else:
    │          ngx.ctx.luagate.action = "allow"
    │
    ▼
[proxy_pass] ─── allow 판정된 요청만 도달
    │
    ▼
[log_by_lua] ─── 비동기 로그 + 메트릭
    │  22개 필드 JSON 레코드 생성
    │  luagate_metrics shared dict 카운터 증가
```

## Stream 평가 흐름

```
TCP 연결 수신
    │
    ▼
[preread_by_lua] ─── 탐지 + 판정 통합 (access_by_lua 없음!)
    │
    ├─ 1. preread buffer peek (ngx.req.socket() 기반)
    │      data = peek_bytes(sock, 16)  -- 버퍼 소비 없이 읽기
    │
    ├─ 2. 프로토콜 탐지
    │      0x16 0x03... → "tls" (SNI 추출)
    │      "GET/POST/..." → "http"
    │      "SSH-" → "ssh"
    │      else → "unknown"
    │
    ├─ 3. 정책 버전 확인 + 스트림 정책 매칭
    │      scope: src_ip, dst_port, detected_protocol, sni
    │      action: "proxy" or "deny"
    │
    └─ 4. 판정 실행
           if action == "deny":
               ngx.ctx.luagate_stream.action = "deny"
               return ngx.exit(ngx.DECLINED)  -- 연결 종료
           else:
               upstream = matched_rule.upstream
    │
    ▼
[proxy_pass] ─── proxy 판정된 연결만 (Nginx native TCP 프록시)
    │
    ▼
[log_by_lua] ─── 세션 종료 시 로그 + luagate_connections 감소
```

## 핵심 규칙 요약

1. **URL 정규화**: `rewrite_by_lua`에서 1회만 수행, 이후 단계에서 재정규화 금지
2. **디코드 에러 → 무조건 deny** (precedence 1)
3. **스캐너 hit → 무조건 deny** (precedence 2, 정책 allow여도)
4. **first-match-wins**: priority 오름차순, 동률 시 YAML 선언 순서 유지
5. **default_action**: "deny" (정책 미매칭 시 차단)
6. **Stream**: "allow" 아니라 "proxy" — 업스트림 지정 필요

## 에러 응답 형식

```json
{
  "error": "Forbidden",
  "request_id": "<UUID>",
  "reason": "policy: <rule-id> | scanner:<threat_type> | decode-error"
}
```

## 참조

- `docs/spec/policy-engine.md` §3 — 평가 알고리즘 상세
- `docs/spec/http-pipeline.md` §2.3 — access_by_lua 처리 순서
- `docs/spec/stream-pipeline.md` §2.1 — preread 처리 순서
- `lua/luagate/policy/evaluator.lua` — 구현 위치
