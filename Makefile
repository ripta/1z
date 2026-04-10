.PHONY: all build release run fmt test unit-test integration-test eager-test fmt-test lsp-test aot-test update-golden update-fmt-golden update-aot-golden update-lsp-golden benchmark build-example clean help docs docker-build docker-test

SHELL := /bin/bash
TARGET_TIMEOUT ?= 60
TEST_CASE_TIMEOUT ?= 10
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
	zig build --release --prefix $(ZIG_PREFIX)

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

aot-test: ## Run AOT build integration tests
	timeout $(TARGET_TIMEOUT) zig build aot-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)

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

benchmark: build ## Run benchmarks
	@for f in $(BENCHMARK_FILES); do echo "--- $$f ---"; ./$(ZIG_PREFIX)/bin/1z "$$f"; echo; done

build-example: build ## Build the C embedding example
	zig cc -o $(ZIG_PREFIX)/embed examples/embed.c -Iinclude $(ZIG_PREFIX)/clib/lib1z.a -lffi

clean: ## Remove build artifacts
	rm -rf $(ZIG_PREFIX) .zig-cache

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

docs: build ## Generate API reference documentation
	./$(ZIG_PREFIX)/bin/1z tools/gen-docs.1z

docker-build: ## Build the project inside Docker (Linux)
	docker run --rm -v $(PWD):/workspace -w /workspace $(DOCKER_IMAGE) \
		make build ZIG_PREFIX=/tmp/zig-out

docker-test: ## Run build and tests inside Docker (Linux)
	docker run --rm -v $(PWD):/workspace -w /workspace $(DOCKER_IMAGE) \
		make build test ZIG_PREFIX=/tmp/zig-out
