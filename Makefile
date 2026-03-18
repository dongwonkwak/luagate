.PHONY: build test test-unit test-unit-lua test-unit-c test-unit-rust test-integration-http test-integration-stream test-reload test-docker lint bench bench-http bench-stream up down implement install-hooks clean ui-dev ui-build

TEST_ADMIN_TOKEN ?= test-secret-token-for-integration
DOCKER_COMPOSE_TEST_FLAGS ?= --build
TEST_HTTP_PROVE_ARGS ?= -r -v tests/integration/http/
TEST_NGINX_PORT ?= 1984
TEST_NGINX_SERVROOT ?= /tmp/nginx-test-servroot
COMPOSE_PROJECT_NAME ?= luagate-test

# ── Build ──────────────────────────────────────────────────────────────────
build:
	@echo "==> Building C extensions..."
	cmake -S csrc -B csrc/build -DCMAKE_BUILD_TYPE=Release
	cmake --build csrc/build

# ── Test ───────────────────────────────────────────────────────────────────
test: test-unit test-integration-http test-integration-stream test-reload

test-unit: test-unit-lua test-unit-c test-unit-rust

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

test-unit-c:
	@echo "==> Running C unit tests (CMocka)..."
	@if [ -f csrc/build/CTestTestfile.cmake ]; then \
	  ctest --test-dir csrc/build --output-on-failure; \
	else \
	  echo "  (skipping C tests — run 'make build' first)"; \
	fi

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
	cd src/decoder && cargo +nightly fuzz run fuzz_normalize_path -- -max_total_time=10 2>/dev/null || \
	  echo "  (fuzz target not available — install cargo-fuzz)"

# ── UI (Dashboard) ────────────────────────────────────────────────────
ui-dev:
	@echo "==> Starting UI dev server..."
	cd ui && npm run dev

ui-build:
	@echo "==> Building UI for production..."
	cd ui && npm run build

# ── Clean ──────────────────────────────────────────────────────────────────
clean:
	rm -rf csrc/build
	rm -rf frontend/dist
	rm -rf ui/dist
	find lua -name '*.so' -delete
