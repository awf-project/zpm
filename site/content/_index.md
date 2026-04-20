---
title: "ZPM — Zig Prolog MCP Server"
description: "A Prolog inference engine for the Model Context Protocol, enabling deterministic logical reasoning for AI agents."
lead: "Expose a Prolog knowledge base to AI agents via the Model Context Protocol."
date: 2026-04-18
draft: false
---

## What is ZPM?

ZPM is a [Model Context Protocol](https://modelcontextprotocol.io/) server written in Zig that embeds a Trealla Prolog engine. It lets AI agents store facts, define rules, and run logical queries — bringing deterministic Prolog reasoning into MCP-compatible workflows.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/awf-project/zpm/main/scripts/install.sh | sh
```

Or build from source:

```bash
git clone https://github.com/awf-project/zpm.git
cd zpm
make build
```

## Quick Start

Add ZPM to your MCP client configuration:

```json
{
  "mcpServers": {
    "zpm": {
      "command": "zpm",
      "args": ["serve"]
    }
  }
}
```

Then assert facts and run queries through your AI agent:

```prolog
% Store a fact
depends_on(zpm, trealla_prolog).

% Query relationships
?- depends_on(zpm, X).
```
