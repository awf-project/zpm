.DEFAULT_GOAL := help
.PHONY: help build test functional-test fmt lint clean check docs docs-serve docs-clean

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

check: lint test functional-test ## Run all checks

clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache

docs: ## Build the Hugo static site
	cd site && npm ci && npx hugo --minify

docs-serve: ## Start Hugo development server with live reload
	cd site && npm ci && npm run dev

docs-clean: ## Remove Hugo build artifacts
	rm -rf site/public site/resources site/.hugo_build.lock
