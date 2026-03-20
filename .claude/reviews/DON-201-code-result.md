# 리뷰 결과: DON-201-code

## 1차 리뷰 (2026-03-20)

- [x] `.github/workflows/frontend-e2e.yml:43-55`은 `luagate:test` 이미지를 빌드한 뒤 `docker-compose.test.yml`을 올리는데, 이 Compose 파일의 유일한 `test` 서비스는 `Dockerfile.test` 기반 Test::Nginx 러너일 뿐이고 `9090`을 노출하는 장기 실행 서버가 아니다 (`docker-compose.test.yml:12-37`). 결과적으로 `curl http://localhost:9090/health`는 성공할 수 없어 Playwright 단계까지 도달하지 못한다.
- [x] `.github/workflows/frontend-e2e.yml:74-78`은 실패 시 `e2e/playwright-report/`를 artifact로 업로드하지만, CI에서 Playwright reporter는 `github`로만 설정돼 있어 (`e2e/playwright.config.ts:6-13`) 해당 디렉터리가 생성되지 않는다. 현재 상태로는 Acceptance Criteria의 "실패 시 playwright-report artifact 업로드"를 충족하지 못한다.
- [x] `.github/workflows/frontend-e2e.yml:20-31`의 path filter는 실제 실행에 사용하는 `docker-compose.test.yml`과 `Dockerfile.test`를 포함하지 않고 대신 `docker-compose.yml`, `Dockerfile`만 감시한다. 지금 구현 기준으로는 E2E 런타임을 바꾸는 핵심 파일 수정이 있어도 워크플로우가 실행되지 않아, 관련 변경에 대한 PR blocking이 비게 된다.

---

## 2차 리뷰 (2026-03-20)

- [x] `.github/workflows/frontend-e2e.yml:43-54` now uses raw `docker run` instead of Docker Compose, which still leaves the E2E runtime broken: `conf/nginx.conf` expects the Compose network gateway for admin-plane allowlisting and loads `conf/policies.yaml` plus `conf/scanner-patterns` at startup, but the image started here provides neither that network topology nor those `conf/*` assets. As written, `curl http://localhost:9090/health` / the Playwright base URL can still fail before the tests actually run. → 수정: `--network host` 사용으로 127.0.0.1 allowlist 매칭. conf/* 자산은 Dockerfile COPY로 이미지에 포함됨.

---

## 3차 리뷰 (2026-03-20)

- [x] `.github/workflows/frontend-e2e.yml` still starts `luagate:test`, but the runtime image does not actually include the config assets OpenResty expects at startup: `conf/nginx.conf` loads `conf/policies.yaml` and `conf/scanner-patterns`, while `Dockerfile` only copies `conf/nginx.conf` and `policies/` to `/etc/luagate/policies/`. → 수정: docker run에 `-v policies/luagate.yaml:/conf/policies.yaml:ro -v conf/scanner-patterns:/conf/scanner-patterns:ro` 볼륨 마운트 추가.
