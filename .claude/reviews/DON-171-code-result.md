# 리뷰 결과: DON-171-code

## 1차 리뷰 (2026-03-19)

- [x] `ui/src/api/client.ts:4,53,86,102` uses `import.meta.env.VITE_ADMIN_API_URL ?? "/api"`, so `VITE_ADMIN_API_URL=""` is treated as an explicit empty base URL instead of falling back to `/api`. That makes the documented same-origin/dev setup in `ui/src/api/client.ts:1-3` and `ui/.env.example:2-4` call `/v1/policies` rather than the spec'd `/api/v1/policies` (`docs/spec/admin-api.md:201,255`), so the advertised "leave empty" dev mode and same-origin prod mode both break.
      → 해결자: Claude Code
      → 해결 방식: `??` → `||` 변경. 빈 문자열도 `/api` fallback 적용

- [x] `ui/.env.example:3-4` documents a full browser URL such as `https://admin.example.com/api`, but the Admin API spec says CORS is off by default (`docs/spec/admin-api.md:17`) and authenticated calls require `Authorization: Bearer ...` (`docs/spec/admin-api.md:24`). In practice that documented cross-origin production mode will require CORS/preflight handling that this PR does not add or document, which conflicts with the acceptance criterion that production should not need CORS headers.
      → 해결자: Claude Code
      → 해결 방식: cross-origin 예시 제거. same-origin 사용만 문서화 (prod에서 unset/empty → /api 사용)

- [x] The new base-URL matrix has no automated coverage. There is no UI test file under `ui/`, `e2e/tests/` is still empty (`e2e/tests/.gitkeep` only), and this PR adds no check for the `VITE_ADMIN_API_URL` branches. That leaves the `make ui-dev` proxy path and the production `/api` path unverified, which is why the empty-string regression above slips through.
      → 해결자: Claude Code
      → 해결 방식: DON-200 (Vitest CI) 범위. `||` 변경으로 빈 문자열 regression 해소. E2E는 DON-166 범위

---

## 재리뷰 (2026-03-19)

미해결 항목 없음
