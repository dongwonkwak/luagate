.PHONY: build test test-unit test-unit-lua test-unit-rust test-integration-http test-integration-stream test-reload test-docker lint bench bench-http bench-stream up down implement install-hooks clean ui-dev ui-build ui-lint ui-test e2e pre-pr

TEST_ADMIN_TOKEN ?= test-secret-token-for-integration
DOCKER_COMPOSE_TEST_FLAGS ?= --build
TEST_HTTP_PROVE_ARGS ?= -r -v tests/integration/http/
TEST_NGINX_PORT ?= 1984
TEST_NGINX_SERVROOT ?= /tmp/nginx-test-servroot
COMPOSE_PROJECT_NAME ?= luagate-test

# ── Build ──────────────────────────────────────────────────────────────────
build: build-ffi

# ── Test ───────────────────────────────────────────────────────────────────
test: test-unit test-integration-http test-integration-stream test-reload

test-unit: test-unit-lua test-unit-rust

test-unit-lua:
	@echo "==> Running Lua unit tests (busted)..."
	busted --config-file=.busted tests/unit

test-unit-rust:
	@echo "==> Running Rust unit tests (cargo test)..."
	@for crate_dir in src/decoder src/scanner src/stream; do \
	  if [ -f "$$crate_dir/Cargo.toml" ]; then \
	    echo "  -> $$crate_dir"; \
	    if [ "$$crate_dir" = "src/scanner" ]; then \
	      (cd "$$crate_dir" && cargo test -- --test-threads=1) || exit 1; \
	    else \
	      (cd "$$crate_dir" && cargo test) || exit 1; \
	    fi; \
	  fi; \
	done


test-integration-http:
	@echo "==> Running HTTP integration tests (Test::Nginx)..."
	@if [ ! -d tests/integration/http ]; then \
	  echo "  (skipping — tests/integration/http/ not yet created)"; \
	elif perl -MTest::Nginx::Socket -e1 >/dev/null 2>&1; then \
	  LUAGATE_ADMIN_TOKEN=$(TEST_ADMIN_TOKEN) prove -r tests/integration/http/; \
	elif command -v docker >/dev/null 2>&1; then \
	  echo "  (Test::Nginx::Socket not available locally — falling back to Docker Compose)"; \
	  $(MAKE) test-docker; \
	else \
	  echo "  (cannot run HTTP integration tests: install Test::Nginx::Socket or use Docker)"; \
	  exit 1; \
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
	@echo "==> Running HTTP integration tests in Docker Compose..."
	LUAGATE_ADMIN_TOKEN=$(TEST_ADMIN_TOKEN) \
	TEST_HTTP_PROVE_ARGS='$(TEST_HTTP_PROVE_ARGS)' \
	TEST_NGINX_PORT=$(TEST_NGINX_PORT) \
	TEST_NGINX_SERVROOT=$(TEST_NGINX_SERVROOT) \
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
	docker compose -f docker-compose.test.yml up $(DOCKER_COMPOSE_TEST_FLAGS) --exit-code-from test

# ── Lint ───────────────────────────────────────────────────────────────────
lint:
	@echo "==> Lua lint..."
	luacheck lua/
	@echo "==> Rust lint..."
	@for crate_dir in src/decoder src/scanner src/stream; do \
	  if [ -f "$$crate_dir/Cargo.toml" ]; then \
	    echo "  -> $$crate_dir"; \
	    (cd "$$crate_dir" && cargo clippy -- -D warnings) || exit 1; \
	  fi; \
	done
	@echo "==> Prometheus rules lint..."
	@if command -v promtool >/dev/null 2>&1; then \
	  promtool check rules conf/alerts.yml; \
	else \
	  echo "  (promtool not found — skipping alerting rules validation)"; \
	fi
	@echo "==> Markdown lint..."
	markdownlint docs/

# ── Benchmark ──────────────────────────────────────────────────────────────
bench:
	@echo "==> Running full benchmark suite..."
	bash tests/bench/run-all.sh

bench-http:
	@echo "==> Running HTTP allow benchmark (wrk)..."
	bash tests/bench/http-allow.sh

bench-stream:
	@echo "==> Running TCP stream benchmark..."
	bash tests/bench/stream-tcp.sh

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

# ── FFI (Rust) ──────────────────────────────────────────────────────────────
.PHONY: build-ffi fuzz-regression

build-ffi:
	@echo "==> Building Rust FFI modules..."
	cd src/decoder && cargo build --release
	cd src/scanner && cargo build --release 2>/dev/null || echo "  (scanner not yet built)"
	cd src/stream && cargo build --release
	@mkdir -p lib
	cp src/decoder/target/release/libluagate_decoder.so lib/luagate_decoder.so
	@[ -f src/scanner/target/release/libluagate_scanner.so ] && \
	  cp src/scanner/target/release/libluagate_scanner.so lib/luagate_scanner.so || true
	cp src/stream/target/release/libluagate_stream.so lib/luagate_stream.so

fuzz-regression:
	@echo "==> Running fuzz regression..."
	@if cargo fuzz --help >/dev/null 2>&1; then \
		cd src/scanner && cargo +nightly fuzz run fuzz_scanner -- -max_total_time=10 2>/dev/null; \
	else \
		echo "  (scanner fuzz target not available — install cargo-fuzz)"; \
	fi
	@if cargo fuzz --help >/dev/null 2>&1; then \
		cd src/decoder && cargo +nightly fuzz run fuzz_decoder -- -max_total_time=10 2>/dev/null; \
	else \
		echo "  (decoder fuzz target not available — install cargo-fuzz)"; \
	fi
	@if cargo fuzz --help >/dev/null 2>&1; then \
		cd src/stream && cargo +nightly fuzz run fuzz_sni -- -max_total_time=10 2>/dev/null; \
	else \
		echo "  (stream fuzz target not available — install cargo-fuzz)"; \
	fi

# ── UI (Dashboard) ────────────────────────────────────────────────────
ui-dev:
	@echo "==> Starting UI dev server..."
	cd ui && npm run dev

ui-build:
	@echo "==> Building UI for production..."
	@echo "    Output: ui/dist/ (Docker COPY maps to /etc/luagate/ui/dist)"
	cd ui && npm run build

ui-lint:
	@echo "==> Running UI lint + format check..."
	cd ui && npm run lint && npm run format:check

ui-test:
	@echo "==> Running UI unit tests (Vitest)..."
	cd ui && npm run test

# ── E2E (Playwright) ──────────────────────────────────────────────────────
e2e:
	@echo "==> Running Playwright E2E tests..."
	cd e2e && npm ci && npm run test

e2e-ui:
	@echo "==> Running Playwright E2E tests (UI mode)..."
	cd e2e && npm run test:ui

# ── Pre-PR Test Gate ─────────────────────────────────────────────────────
pre-pr:
	@echo "==> Running pre-PR test gate..."
	@scripts/pre-pr.sh

# ── Clean ──────────────────────────────────────────────────────────────────
clean:
	rm -rf lib/*.so
	rm -rf ui/dist
	@for crate_dir in src/decoder src/scanner src/stream; do \
	  if [ -d "$$crate_dir/target" ]; then \
	    echo "  -> cleaning $$crate_dir"; \
	    (cd "$$crate_dir" && cargo clean); \
	  fi; \
	done
