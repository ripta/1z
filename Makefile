.PHONY: all build release run fmt test unit-test integration-test jit-test fmt-test update-golden update-fmt-golden benchmark clean help

SHELL := /bin/bash

ONE_Z_FILES := $(shell find . -name '*.1z' -not -path './.zig-cache/*' -not -path './zig-out/*')
TIMEOUT := 30

all: build test

build: ## Build the project (default)
	( time zig build )

release: ## Build with optimizations
	zig build --release

run: build ## Build and run the 1z interpreter
	./zig-out/bin/1z

fmt: build ## Format zig and 1z source files
	zig fmt src/ build.zig
	./zig-out/bin/1z fmt $(ONE_Z_FILES)

test: unit-test integration-test fmt-test ## Run all tests

unit-test: ## Run unit tests
	( time timeout $(TIMEOUT) zig build test $(if $(VERBOSE),--summary all,) )

integration-test: ## Run integration tests
	( time timeout $(TIMEOUT) zig build integration-test $(if $(VERBOSE),--summary all,) )

jit-build: ## Build only the 1z-jit binary
	zig build jit-build

jit-test: ## Run integration tests with JIT auto-compilation
	( time timeout $(TIMEOUT) zig build jit-integration-test $(if $(VERBOSE),--summary all,) )

fmt-test: ## Run formatter tests
	( time timeout $(TIMEOUT) zig build fmt-test $(if $(VERBOSE),--summary all,) )

update-golden: ## Update integration test golden files
	( time timeout $(TIMEOUT) zig build update-golden )

update-fmt-golden: ## Update formatter test golden files
	( time timeout $(TIMEOUT) zig build update-fmt-golden )

BENCHMARK_FILES := $(wildcard tests/benchmark/*.1z)

benchmark: build ## Run benchmarks
	@for f in $(BENCHMARK_FILES); do echo "--- $$f ---"; ./zig-out/bin/1z "$$f"; echo; done

clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'
