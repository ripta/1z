.PHONY: all build release run fmt test unit-test integration-test eager-test fmt-test lsp-test aot-test update-golden update-fmt-golden update-aot-golden update-lsp-golden benchmark build-example clean help docs docker-build docker-test

SHELL := /bin/bash
TIMEOUT := 60
MAKEFLAGS += -j4
ZIG_PREFIX ?= zig-out
DOCKER_IMAGE ?= gcr.io/$(GCP_PROJECT_ID)/zag:v0.15.2

all: build test

build: ## Build the project (default)
	( time zig build --prefix $(ZIG_PREFIX) )

release: ## Build with optimizations
	( time zig build --release --prefix $(ZIG_PREFIX) )

run: build ## Build and run the 1z interpreter
	./$(ZIG_PREFIX)/bin/1z $(ARGS)

fmt: build ## Format zig and 1z source files
	zig fmt src/ build.zig
	./$(ZIG_PREFIX)/bin/1z fmt $$(find . \( -path './.zig-cache' -o -path './$(ZIG_PREFIX)' \) -prune -o -name '*.1z' -print)

test: unit-test integration-test fmt-test eager-test lsp-test aot-test ## Run all tests

unit-test: ## Run unit tests
	( time timeout $(TIMEOUT) zig build test --prefix $(ZIG_PREFIX) $(if $(VERBOSE),--summary all,) )

integration-test: ## Run integration tests
	( time timeout $(TIMEOUT) zig build integration-test --prefix $(ZIG_PREFIX) $(if $(VERBOSE),--summary all,) )

jit-build: ## Build only the 1z-jit binary
	( time timeout $(TIMEOUT) zig build jit-build --prefix $(ZIG_PREFIX) )

jit-test: ## Run integration tests with JIT auto-compilation
	( time timeout $(TIMEOUT) zig build jit-integration-test --prefix $(ZIG_PREFIX) $(if $(VERBOSE),--summary all,) )

eager-test: ## Run integration tests with eager compilation
	( time timeout $(TIMEOUT) zig build eager-integration-test --prefix $(ZIG_PREFIX) $(if $(VERBOSE),--summary all,) )

fmt-test: ## Run formatter tests
	( time timeout $(TIMEOUT) zig build fmt-test --prefix $(ZIG_PREFIX) $(if $(VERBOSE),--summary all,) )

aot-test: ## Run AOT build integration tests
	( time timeout $(TIMEOUT) zig build aot-test --prefix $(ZIG_PREFIX) $(if $(VERBOSE),--summary all,) )

lsp-test: ## Run LSP server tests
	( time timeout $(TIMEOUT) zig build lsp-test --prefix $(ZIG_PREFIX) $(if $(VERBOSE),--summary all,) )

update-aot-golden: ## Update AOT test golden files
	( time timeout $(TIMEOUT) zig build update-aot-golden --prefix $(ZIG_PREFIX) )

update-lsp-golden: ## Update LSP test golden files
	( time timeout $(TIMEOUT) zig build update-lsp-golden --prefix $(ZIG_PREFIX) )

update-golden: ## Update integration test golden files
	( time timeout $(TIMEOUT) zig build update-golden )

update-fmt-golden: ## Update formatter test golden files
	( time timeout $(TIMEOUT) zig build update-fmt-golden )

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
