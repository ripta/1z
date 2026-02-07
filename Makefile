.PHONY: all build release run test integration-test fmt-test update-golden update-fmt-golden clean help

all: build

build: ## Build the project (default)
	zig build

release: ## Build with optimizations
	zig build --release

run: build ## Build and run the 1z interpreter
	./zig-out/bin/1z

test: ## Run unit tests
	zig build test

integration-test: ## Run integration tests
	zig build integration-test

fmt-test: ## Run formatter tests
	zig build fmt-test

update-golden: ## Update integration test golden files
	zig build update-golden

update-fmt-golden: ## Update formatter test golden files
	zig build update-fmt-golden

clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'
