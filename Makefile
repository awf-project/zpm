.DEFAULT_GOAL := help
.PHONY: help build test functional-test fmt lint clean check

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build the server binary
	zig build --summary all

test: ## Run unit tests
	zig build test --summary all

functional-test: build ## Run end-to-end MCP protocol tests
	bash tests/functional_mcp_server_test.sh

fmt: ## Format source code
	zig fmt .

lint: ## Check formatting
	zig fmt --check .

check: lint test functional-test ## Run all checks (lint + test + e2e)

clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache
