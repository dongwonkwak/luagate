.PHONY: build test test-unit test-unit-lua test-unit-c test-integration-http test-integration-stream test-reload test-docker lint bench bench-http bench-stream up down implement install-hooks clean

# ── Build ──────────────────────────────────────────────────────────────────
build:
	@echo "==> Building C extensions..."
	cmake -S csrc -B csrc/build -DCMAKE_BUILD_TYPE=Release
	cmake --build csrc/build

# ── Test ───────────────────────────────────────────────────────────────────
test: test-unit test-integration-http test-integration-stream test-reload

test-unit: test-unit-lua test-unit-c

test-unit-lua:
	@echo "==> Running Lua unit tests (busted)..."
	busted --config-file=.busted tests/unit

test-unit-c:
	@echo "==> Running C unit tests (CMocka)..."
	@if [ -f csrc/build/CTestTestfile.cmake ]; then \
	  ctest --test-dir csrc/build --output-on-failure; \
	else \
	  echo "  (skipping C tests — run 'make build' first)"; \
	fi

test-integration-http:
	@echo "==> Running HTTP integration tests (Test::Nginx)..."
	@if [ -d tests/integration/http ]; then \
	  LUAGATE_ADMIN_TOKEN=test-secret-token-for-integration prove -r tests/integration/http/; \
	else \
	  echo "  (skipping — tests/integration/http/ not yet created)"; \
	fi

test-integration-stream:
	@echo "==> Running Stream integration tests (Test::Nginx::Stream)..."
	@if [ -d tests/integration/stream ]; then \
	  prove -r tests/integration/stream/; \
	else \
	  echo "  (skipping — tests/integration/stream/ not yet created)"; \
	fi

test-reload:
	@echo "==> Running Hot Reload tests..."
	@if [ -d tests/unit/reload ]; then \
	  busted --config-file=.busted tests/unit/reload/; \
	else \
	  echo "  (skipping — tests/unit/reload/ not yet created)"; \
	fi

# ── Docker Test ────────────────────────────────────────────────────────────
test-docker:
	@echo "==> Building test Docker image..."
	docker build -f Dockerfile.test -t luagate-test .
	@echo "==> Running integration tests inside Docker container..."
	docker run --rm \
	  -v "$(CURDIR)/lua/luagate:/usr/local/openresty/lualib/luagate:ro" \
	  -v "$(CURDIR)/conf/nginx.conf:/luagate/conf/nginx.conf:ro" \
	  -v "$(CURDIR)/tests:/luagate/tests:ro" \
	  -v "$(CURDIR)/policies:/luagate/policies:ro" \
	  -e TEST_NGINX_SERVROOT=/tmp/nginx-test-servroot \
	  -e LUAGATE_ADMIN_TOKEN=test-secret-token-for-integration \
	  luagate-test \
	  prove -r -v tests/integration/http/; \
	EXIT_CODE=$$?; \
	echo "==> Test container exited with code $$EXIT_CODE"; \
	exit $$EXIT_CODE

# ── Lint ───────────────────────────────────────────────────────────────────
lint:
	@echo "==> Lua lint..."
	luacheck lua/
	@echo "==> C lint..."
	@if [ -f csrc/build/compile_commands.json ]; then \
	  find csrc -name '*.c' | xargs -r clang-tidy -p csrc/build; \
	else \
	  echo "  (skipping clang-tidy — run 'make build' first to generate compile_commands.json)"; \
	fi
	@echo "==> Markdown lint..."
	markdownlint docs/

# ── Benchmark ──────────────────────────────────────────────────────────────
bench: bench-http bench-stream

bench-http:
	@echo "==> Running HTTP benchmark (wrk)..."
	wrk -t4 -c100 -d30s http://localhost:8080/api/v1/users

bench-stream:
	@echo "==> Running Stream benchmark..."
	@echo "  (Stream benchmark tool TBD)"

# ── Docker ─────────────────────────────────────────────────────────────────
up:
	docker compose up -d

down:
	docker compose down

# ── AI-assisted implementation ─────────────────────────────────────────────
implement:
	@echo "==> Running AI implementation agent..."
	claude --dangerously-skip-permissions -p "$(PROMPT)"

# ── Git hooks ──────────────────────────────────────────────────────────────
install-hooks:
	@echo "==> Installing commitlint (required for commit-msg hook)..."
	@if [ ! -f package.json ]; then npm init -y --scope="" > /dev/null; fi
	npm install --save-dev @commitlint/cli @commitlint/config-conventional
	@echo "==> Installing git hooks via pre-commit..."
	pre-commit install --hook-type pre-commit --hook-type commit-msg --hook-type pre-push
	@echo "==> Git hooks installed."

# ── Clean ──────────────────────────────────────────────────────────────────
clean:
	rm -rf csrc/build
	rm -rf frontend/dist
	find lua -name '*.so' -delete
