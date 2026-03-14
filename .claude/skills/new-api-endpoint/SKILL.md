---
description: "새 Admin API 엔드포인트 추가 절차. docs/spec/admin-api.md 스펙 + 인증 + 감사 로그 포함."
---

# Skill: 새 Admin API 엔드포인트 추가

## 절차

1. **spec 확인**: `docs/spec/admin-api.md`에 엔드포인트 정의 추가
2. **라우터 등록**: `lua/luagate/admin/router.lua`에 path + handler 매핑
3. **핸들러 구현**: `lua/luagate/admin/<handler>.lua` (template.lua 참조)
4. **인증 미들웨어 적용**: GET /health 제외 모든 엔드포인트에 Bearer 토큰 인증
5. **응답 형식 준수**: `{"ok": true|false, "data": {...}}` 또는 `{"ok": false, "error": "...", "message": "..."}`
6. **감사 로그**: 상태 변경 엔드포인트(PUT, POST)에 audit_log 호출
7. **테스트 작성**: `tests/unit/admin/<handler>_test.lua`
8. **spec 업데이트**: admin-api.md에 새 엔드포인트 문서화

## 체크리스트

- [ ] admin-api.md 스펙에 엔드포인트 정의
- [ ] 인증 미들웨어 적용 (GET /health 제외)
- [ ] 응답 형식: `{"ok": ..., "data": ...}` 준수
- [ ] 에러 응답: HTTP 상태 코드 + error 코드 표 참조 (admin-api.md §6)
- [ ] 상태 변경 시 audit_log 기록
- [ ] 타이밍 안전 토큰 비교 (constant-time compare, lua/luagate/admin/auth.lua)
- [ ] CORS OPTIONS preflight 처리 (인증 없이 204 반환)
- [ ] 단위 테스트 작성
- [ ] 에러 코드 표 참조 확인

## 에러 코드 표 (admin-api.md §6)

| HTTP | error | 설명 |
|------|-------|------|
| 400 | ValidationError | 스키마 검증 실패 |
| 401 | Unauthorized | 인증 실패 |
| 404 | NotFound | 없는 엔드포인트 |
| 405 | MethodNotAllowed | 허용되지 않은 메서드 |
| 409 | ReloadInProgress | 중복 reload |
| 500 | InternalError | 서버 오류 |
| 500 | ReloadFailed | reload 실패 |

## 참조

- `template.lua` — 핸들러 템플릿 (이 디렉토리)
- `docs/spec/admin-api.md` — Admin API 스펙
- `lua/luagate/admin/auth.lua` — 인증 미들웨어
- `.claude/knowledge/security-patterns.md` — 보안 패턴
