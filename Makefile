.PHONY: all build release run fmt test unit-test integration-test eager-test fmt-test lsp-test aot-test update-golden update-fmt-golden update-aot-golden update-lsp-golden benchmark build-example clean help docs

SHELL := /bin/bash
TIMEOUT := 45
MAKEFLAGS += -j4

all: build test

build: ## Build the project (default)
	( time zig build )

release: ## Build with optimizations
	zig build --release

run: build ## Build and run the 1z interpreter
	./zig-out/bin/1z

fmt: build ## Format zig and 1z source files
	zig fmt src/ build.zig
	./zig-out/bin/1z fmt $$(find . \( -path './.zig-cache' -o -path './zig-out' \) -prune -o -name '*.1z' -print)

test: unit-test integration-test fmt-test eager-test lsp-test aot-test ## Run all tests

unit-test: ## Run unit tests
	( time timeout $(TIMEOUT) zig build test $(if $(VERBOSE),--summary all,) )

integration-test: ## Run integration tests
	( time timeout $(TIMEOUT) zig build integration-test $(if $(VERBOSE),--summary all,) )

jit-build: ## Build only the 1z-jit binary
	( time timeout $(TIMEOUT) zig build jit-build )

jit-test: ## Run integration tests with JIT auto-compilation
	( time timeout $(TIMEOUT) zig build jit-integration-test $(if $(VERBOSE),--summary all,) )

eager-test: ## Run integration tests with eager compilation
	( time timeout $(TIMEOUT) zig build eager-integration-test $(if $(VERBOSE),--summary all,) )

fmt-test: ## Run formatter tests
	( time timeout $(TIMEOUT) zig build fmt-test $(if $(VERBOSE),--summary all,) )

aot-test: ## Run AOT build integration tests
	timeout $(TIMEOUT) zig build aot-test $(if $(VERBOSE),--summary all,)

lsp-test: ## Run LSP server tests
	timeout $(TIMEOUT) zig build lsp-test $(if $(VERBOSE),--summary all,)

update-aot-golden: ## Update AOT test golden files
	timeout $(TIMEOUT) zig build update-aot-golden

update-lsp-golden: ## Update LSP test golden files
	timeout $(TIMEOUT) zig build update-lsp-golden

update-golden: ## Update integration test golden files
	( time timeout $(TIMEOUT) zig build update-golden )

update-fmt-golden: ## Update formatter test golden files
	( time timeout $(TIMEOUT) zig build update-fmt-golden )

BENCHMARK_FILES := $(wildcard tests/benchmark/*.1z)

benchmark: build ## Run benchmarks
	@for f in $(BENCHMARK_FILES); do echo "--- $$f ---"; ./zig-out/bin/1z "$$f"; echo; done

build-example: build ## Build the C embedding example
	zig cc -o zig-out/embed examples/embed.c -Iinclude zig-out/clib/lib1z.a -lffi

clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

docs: build ## Generate API reference documentation
	./zig-out/bin/1z tools/gen-docs.1z
