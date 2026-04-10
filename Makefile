.DEFAULT_GOAL := help
.PHONY: help build test ffi-test functional-test functional-test-engine fmt lint clean check ffi-build roundtrip

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

ffi-build: ## Build the Rust FFI static library
	cd ffi/zpm-prolog-ffi && cargo build --release

build: ffi-build ## Build the server binary
	zig build --summary all

test: ## Run unit tests (Zig + Rust)
	zig build test --summary all

ffi-test: ## Run Rust FFI tests only
	cd ffi/zpm-prolog-ffi && cargo test

functional-test: build ## Run end-to-end MCP protocol tests
	bash tests/functional_mcp_server_test.sh

functional-test-engine: build ## Run end-to-end Prolog engine tests
	bash tests/functional_prolog_engine_test.sh

fmt: ## Format source code
	zig fmt .
	cd ffi/zpm-prolog-ffi && cargo fmt

lint: ## Check formatting
	zig fmt --check .
	cd ffi/zpm-prolog-ffi && cargo fmt --check
	cd ffi/zpm-prolog-ffi && cargo clippy -- -D warnings

roundtrip: ## Run Prolog roundtrip example (Zig -> Rust FFI -> scryer-prolog)
	zig build roundtrip

check: lint test functional-test functional-test-engine ## Run all checks (lint + test + e2e)

clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache
