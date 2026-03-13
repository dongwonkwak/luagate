.PHONY: build test lint bench up down implement clean

# ── Build ──────────────────────────────────────────────────────────────────
build:
	@echo "==> Building C extensions..."
	cmake -S csrc -B csrc/build -DCMAKE_BUILD_TYPE=Release
	cmake --build csrc/build

# ── Test ───────────────────────────────────────────────────────────────────
test:
	@echo "==> Running Lua unit tests..."
	busted --config-file=.busted tests/unit
	@echo "==> Running integration tests..."
	busted --config-file=.busted tests/integration

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
bench:
	@echo "==> Running benchmarks..."
	wrk -t4 -c100 -d30s http://localhost:8080/bench

# ── Docker ─────────────────────────────────────────────────────────────────
up:
	docker compose up -d

down:
	docker compose down

# ── AI-assisted implementation ─────────────────────────────────────────────
implement:
	@echo "==> Running AI implementation agent..."
	claude --dangerously-skip-permissions -p "$(PROMPT)"

# ── Clean ──────────────────────────────────────────────────────────────────
clean:
	rm -rf csrc/build
	rm -rf frontend/dist
	find lua -name '*.so' -delete
