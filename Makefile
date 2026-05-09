.PHONY: all build release run fmt test unit-test integration-test eager-test fmt-test lsp-test aot-test aot-run aot-interpreter-strip-check bail-stats update-golden update-fmt-golden update-aot-golden update-lsp-golden benchmark benchmark-fib benchmark-quotation profiles build-example clean help docs docker-build docker-test

SHELL := /bin/bash
TARGET_TIMEOUT ?= 60
TEST_CASE_TIMEOUT ?= 10
AOT_TIMEOUT ?= 10
ZIG_PREFIX ?= zig-out
DOCKER_IMAGE ?= gcr.io/$(GCP_PROJECT_ID)/zag:v0.15.2
TEST_FILTER_ARG = $(if $(TEST_FILTER),-Dtest-filter=$(TEST_FILTER))

# Within each zig build invocation, the build runner parallelizes independent
# test steps automatically. JOBS controls the zig build runner thread count.
# Tests marked .serial=true in their .zon metadata, e.g., HTTP server tests,
# are chained to avoid port conflicts.
JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
ZIG_JOBS_ARG = -j$(JOBS)

all: build test

build: ## Build the project (default)
	zig build --prefix $(ZIG_PREFIX)

release: ## Build with optimizations
	zig build --release=fast --prefix $(ZIG_PREFIX)

run: build ## Build and run the 1z interpreter
	./$(ZIG_PREFIX)/bin/1z $(ARGS)

fmt: build ## Format zig and 1z source files
	timeout $(TARGET_TIMEOUT) zig fmt src/ build.zig
	timeout $(TARGET_TIMEOUT) ./$(ZIG_PREFIX)/bin/1z fmt $$(find . \( -path './.zig-cache' -o -path './$(ZIG_PREFIX)' \) -prune -o -name '*.1z' -print)

test: ## Run all tests
	timeout $(TARGET_TIMEOUT) zig build test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT)
	timeout $(TARGET_TIMEOUT) zig build integration-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)
	timeout $(TARGET_TIMEOUT) zig build fmt-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)
	timeout $(TARGET_TIMEOUT) zig build eager-integration-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)
	timeout $(TARGET_TIMEOUT) zig build lsp-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)
	timeout $(TARGET_TIMEOUT) zig build aot-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)

unit-test: ## Run unit tests
	timeout $(TARGET_TIMEOUT) zig build test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT)

integration-test: ## Run integration tests
	timeout $(TARGET_TIMEOUT) zig build integration-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)

jit-build: ## Build only the 1z-jit binary
	timeout $(TIMEOUT) zig build jit-build --prefix $(ZIG_PREFIX)

jit-test: ## Run integration tests with JIT auto-compilation
	timeout $(TARGET_TIMEOUT) zig build integration-test --prefix $(ZIG_PREFIX) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT)

eager-test: ## Run integration tests with eager compilation
	timeout $(TARGET_TIMEOUT) zig build eager-integration-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)

fmt-test: ## Run formatter tests
	timeout $(TARGET_TIMEOUT) zig build fmt-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)

aot-run: build ## AOT-compile and run a 1z file (FILE= ARGS= AOT_TIMEOUT=10)
	$(eval _aot_tmp := $(shell mktemp /tmp/1z-aot-run-XXXXXX))
	@trap 'rm -f $(_aot_tmp)' EXIT; \
	timeout $(AOT_TIMEOUT) ./$(ZIG_PREFIX)/bin/1z build $(FILE) -o $(_aot_tmp) $(ARGS) && \
	chmod +x $(_aot_tmp) && \
	timeout $(AOT_TIMEOUT) $(_aot_tmp)

aot-test: aot-interpreter-strip-check ## Run AOT build integration tests
	timeout $(TARGET_TIMEOUT) zig build aot-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)

aot-interpreter-strip-check: build ## Verify linker GC strips the prelude loader from interpreter-free AOT binaries
	$(eval _free_bin := $(shell mktemp /tmp/1z-strip-check-free-XXXXXX))
	$(eval _linked_bin := $(shell mktemp /tmp/1z-strip-check-linked-XXXXXX))
	@trap 'rm -f $(_free_bin) $(_linked_bin)' EXIT; \
	./$(ZIG_PREFIX)/bin/1z build --interpreter-fallback=false --lock-interpreter-setting -o $(_free_bin) tests/aot/interpreter_free_lock_explicit.1z && \
	./$(ZIG_PREFIX)/bin/1z build --interpreter-fallback=true -o $(_linked_bin) tests/aot/interpreter_free_lock_explicit.1z && \
	if nm $(_free_bin) | grep -q '_onez_load_prelude'; then \
		echo "FAIL: interpreter-free binary still contains _onez_load_prelude (linker GC did not strip)"; exit 1; \
	fi; \
	if ! nm $(_linked_bin) | grep -q '_onez_load_prelude'; then \
		echo "FAIL: interpreter-linked binary missing _onez_load_prelude (build is broken or codegen mis-routed)"; exit 1; \
	fi; \
	free_size=$$(stat -f %z $(_free_bin) 2>/dev/null || stat -c %s $(_free_bin)); \
	linked_size=$$(stat -f %z $(_linked_bin) 2>/dev/null || stat -c %s $(_linked_bin)); \
	echo "PASS: _onez_load_prelude absent from interpreter-free, present in interpreter-linked"; \
	echo "      interpreter-free size:   $$free_size bytes"; \
	echo "      interpreter-linked size: $$linked_size bytes"; \
	echo "      delta:                   $$((linked_size - free_size)) bytes"; \
	free_inspect=$$(./$(ZIG_PREFIX)/bin/1z inspect $(_free_bin)); \
	linked_inspect=$$(./$(ZIG_PREFIX)/bin/1z inspect $(_linked_bin)); \
	if ! echo "$$free_inspect" | grep -qx 'interpreter: linked=no, fallback=false, locked=yes'; then \
		echo "FAIL: 1z inspect on free binary did not report linked=no with fallback=false, locked=yes:"; \
		echo "$$free_inspect"; exit 1; \
	fi; \
	if ! echo "$$linked_inspect" | grep -qx 'interpreter: linked=yes, fallback=true, locked=no'; then \
		echo "FAIL: 1z inspect on linked binary did not report linked=yes with fallback=true, locked=no:"; \
		echo "$$linked_inspect"; exit 1; \
	fi; \
	echo "PASS: 1z inspect reports linked=no for interpreter-free, linked=yes for interpreter-linked"

bail-stats: ## Build with bail instrumentation and AOT-run a file (FILE=)
	zig build --prefix $(ZIG_PREFIX) -Dbail-stats=true
	$(eval _aot_tmp := $(shell mktemp /tmp/1z-bail-stats-XXXXXX))
	@trap 'rm -f $(_aot_tmp)' EXIT; \
	timeout $(AOT_TIMEOUT) ./$(ZIG_PREFIX)/bin/1z build $(FILE) -o $(_aot_tmp) && \
	chmod +x $(_aot_tmp) && \
	timeout $(AOT_TIMEOUT) $(_aot_tmp)

lsp-test: ## Run LSP server tests
	timeout $(TARGET_TIMEOUT) zig build lsp-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)

update-aot-golden: ## Update AOT test golden files
	timeout $(TARGET_TIMEOUT) zig build update-aot-golden --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) $(TEST_FILTER_ARG)

update-lsp-golden: ## Update LSP test golden files
	timeout $(TARGET_TIMEOUT) zig build update-lsp-golden --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) $(TEST_FILTER_ARG)

update-golden: ## Update integration test golden files
	timeout $(TARGET_TIMEOUT) zig build update-golden --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) $(TEST_FILTER_ARG)

update-fmt-golden: ## Update formatter test golden files
	timeout $(TARGET_TIMEOUT) zig build update-fmt-golden --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) $(TEST_FILTER_ARG)

BENCHMARK_FILES := $(wildcard tests/benchmark/*.1z)

benchmark-fib: build ## Run fibonacci benchmark across all execution modes
	@scripts/benchmark-fib.sh ./$(ZIG_PREFIX)/bin/1z tests/benchmark/fibonacci_simple.1z $(ZIG_PREFIX)/benchmark-fib-aot

benchmark-quotation: build ## Run quotation sequence benchmark across all execution modes
	@scripts/benchmark-quotation.sh ./$(ZIG_PREFIX)/bin/1z tests/benchmark/quotation_seq.1z $(ZIG_PREFIX)/benchmark-quotation-aot

benchmark-scanner: build ## Run scanner vs direct benchmark across interpreter modes
	@scripts/benchmark-scanner.sh ./$(ZIG_PREFIX)/bin/1z tests/benchmark/scanner_vs_direct.1z

benchmark: build ## Run benchmarks
	@for f in $(BENCHMARK_FILES); do echo "--- $$f ---"; ./$(ZIG_PREFIX)/bin/1z "$$f"; echo; done

PROFILE_FILES := $(wildcard tests/profiles/*.1z)

profiles: build ## Run profile sample workloads and refresh their .sample files
	@for f in $(PROFILE_FILES); do \
		echo "--- $$f ---"; \
		./$(ZIG_PREFIX)/bin/1z run --profile "$$f" > "$${f%.1z}.sample"; \
	done

build-example: build ## Build the C embedding example
	zig cc -o $(ZIG_PREFIX)/embed examples/embed.c -Iinclude $(ZIG_PREFIX)/clib/lib1z.a -lffi

clean: ## Remove build artifacts
	mv .zig-cache .old.zig-cache
	rm -rf $(ZIG_PREFIX) .old.zig-cache

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

docs: build ## Generate API reference documentation
	./$(ZIG_PREFIX)/bin/1z tools/gen-docs.1z

docker-build: ## Build the project inside Docker (Linux)
	docker build --build-arg GCP_PROJECT_ID=$(GCP_PROJECT_ID) -t gcr.io/$(GCP_PROJECT_ID)/1z .

docker-test: ## Run integration tests inside a Docker container
	docker run --rm gcr.io/$(GCP_PROJECT_ID)/1z make integration-test
