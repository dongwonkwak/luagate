# 리뷰 결과: DON-216-code

## 1차 리뷰 (2026-03-22)

- [x] `lua/luagate/admin/policies.lua:343`의 `Content-Type` charset 파싱이 `content_type:match("charset=([^;%s]+)")`에 고정돼 있어 RFC 표기 변형을 처리하지 못합니다. 그래서 `application/x-yaml; Charset=iso-8859-1`나 `application/x-yaml; charset = iso-8859-1`처럼 실제로는 charset 파라미터가 있는 비 UTF-8 요청이 422 없이 통과할 수 있고, 반대로 유효한 `charset=\"utf-8\"`는 `"utf-8"`로 비교돼 잘못 거부됩니다. `tests/unit/admin/policies_spec.lua:1036` 및 `tests/unit/admin/policies_spec.lua:1280`도 정확히 `charset=...` 형태만 검증해서 이 우회/오탐을 잡지 못합니다.
      → 해결자: Claude Code
      → 해결 방식: `:lower()` + `charset%s*=%s*\"?([^;%s\"]+)` 패턴으로 변경. 대소문자/공백/따옴표 변형 테스트 3개 추가.

---

## 재리뷰 (2026-03-22)

미해결 항목 없음
