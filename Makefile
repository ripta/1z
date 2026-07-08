.PHONY: all build release run fmt test unit-test integration-test fmt-test update-golden update-fmt-golden clean help

SHELL := /bin/bash

ONE_Z_FILES := $(shell find . -name '*.1z' -not -path './.zig-cache/*' -not -path './zig-out/*')
TIMEOUT := 30

all: build

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
	( time timeout $(TIMEOUT) zig build test )

integration-test: ## Run integration tests
	( time timeout $(TIMEOUT) zig build integration-test )

fmt-test: ## Run formatter tests
	( time timeout $(TIMEOUT) zig build fmt-test )

lint: ## Check src/ and lib/ comments for em-dash and prose double-dash usage
	./scripts/lint-dashes.sh

update-golden: ## Update integration test golden files
	timeout $(TIMEOUT) zig build update-golden

update-fmt-golden: ## Update formatter test golden files
	timeout $(TIMEOUT) zig build update-fmt-golden

clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'
