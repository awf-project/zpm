---
title: "Contributing to the zpm Documentation Site"
---


This guide covers the workflows for adding or updating documentation content on the zpm site.

## Before You Start

- Ensure you can [run the site locally](../getting-started/site-development.md)
- Read the [site configuration reference](../reference/site-config.md) to understand the structure
- Familiarize yourself with the [Diátaxis documentation framework](#documentation-types)

## Documentation Types

The zpm documentation follows the [Diátaxis framework](https://diataxis.fr/), which organizes documentation into four types:

### 1. **Tutorials** (Learning-Oriented)

Location: `docs/getting-started/`

**Purpose:** Help new users learn foundational concepts.

**Characteristics:**
- Practical, hands-on approach
- Assume minimal prior knowledge
- Include working examples and expected output
- End with a complete, working result

**Example:** "Getting Started with MCP Server" teaches how to build and run zpm from scratch.

**Template:**
```markdown
---
title: "Tutorial Title"
description: "What the learner will accomplish"
weight: 10
---

# Tutorial Title

## What You'll Learn

- Concept A
- Concept B

## Prerequisites

- Item 1
- Item 2

## Step-by-Step

### Step 1: Do Something

Instructions...

### Step 2: Do Something Else

Instructions...

## Summary

What was accomplished and next steps.
```

### 2. **How-To Guides** (Task-Oriented)

Location: `docs/user-guide/`

**Purpose:** Help users accomplish specific tasks.

**Characteristics:**
- Assume some prior knowledge (reader knows what they want to do)
- Focus on the specific task, not comprehensive explanation
- Provide concrete steps and code examples
- Be concise and avoid tangents

**Example:** "Updating Facts" assumes the reader knows what facts are and wants to update one.

**Template:**
```markdown
---
title: "How to [Task]"
description: "Accomplish [specific task] with zpm"
weight: 20
---

# How to [Task]

## Overview

Brief description of the task and when to use it.

## Steps

1. **First step**

   Command or code example:
   ```bash
   command here
   ```

2. **Second step**

   Explanation and example:
   ```json
   { "example": "json" }
   ```

## Troubleshooting

Common issues and solutions.

## See Also

- Related task link
- Conceptual explanation link
```

### 3. **Reference Documentation** (Information-Oriented)

Location: `docs/reference/`

**Purpose:** Provide complete technical specifications.

**Characteristics:**
- Comprehensive coverage of all options, flags, arguments
- Organized for lookup (tables, structured lists)
- Minimal explanation — let the user refer elsewhere to understand concepts
- Include examples but don't explain why

**Example:** "CLI Reference" lists all commands, flags, and options systematically.

**Template:**
```markdown
---
title: "[Component] Reference"
description: "Complete specification of [component]"
weight: 50
---

# [Component] Reference

## Overview

One sentence: what does this component do?

## Syntax

```
command [options] [arguments]
```

## Commands

| Command | Description | Example |
|---------|-------------|---------|
| `cmd1` | Does X | `zpm cmd1 --flag value` |

## Flags

| Flag | Type | Description |
|------|------|-------------|
| `--flag` | string | Does Y |

## Examples

### Example 1

Code block showing usage.

## See Also

- Link to how-to guide for common tasks
- Link to explanation for concepts
```

### 4. **Explanations** (Understanding-Oriented)

Location: `docs/ADR/` (for architectural decisions) or new `docs/explanation/` (for concepts)

**Purpose:** Build deep understanding of concepts and design decisions.

**Characteristics:**
- Explain *why* things are designed a certain way
- Discuss trade-offs and alternatives
- Can be opinionated (contrast with reference, which is neutral)
- Don't provide step-by-step instructions

**Example:** "ADR-0003" explains *why* write-ahead journals were chosen for persistence.

**Template:**
```markdown
---
title: "Understanding [Concept]"
description: "Why [component] is designed this way"
weight: 10
---

# Understanding [Concept]

## Problem

What problem does this solve?

## Solution

Why this approach was chosen.

## Trade-offs

What are the costs and benefits?

### Alternative A

What we didn't choose and why.

### Alternative B

What we didn't choose and why.

## Further Reading

- Related concept link
- How-to guide using this concept
```

## Adding New Content

### Step 1: Determine the Documentation Type

Ask yourself: "Is the reader trying to **learn** a concept, accomplish a **task**, **look up** a specification, or **understand** the design?"

- **Learn** → Tutorial (getting-started/)
- **Accomplish task** → How-To (user-guide/)
- **Look up** → Reference (reference/)
- **Understand design** → Explanation (ADR/ or docs/explanation/)

### Step 2: Create the File

Create a markdown file in the appropriate directory with a descriptive name:

```bash
docs/{category}/{descriptive-name}.md
```

Examples:
- `docs/getting-started/first-query.md`
- `docs/user-guide/define-rules.md`
- `docs/reference/tool-api.md`

### Step 3: Add Hugo Frontmatter

Every page needs frontmatter (metadata at the top):

```markdown
---
title: "Display Title"
description: "One-line summary (appears in search results)"
weight: 50
---
```

**weight:** Controls menu order. Lower numbers appear first. Use increments of 10 (10, 20, 30, etc.) to allow insertion between existing pages.

### Step 4: Write Content

Follow the template for your documentation type (see templates above).

### Step 5: Link to Navigation Menu

Open `site/config/_default/menus/menus.en.toml` and add an entry:

```toml
[[docs]]
name = "New Page Title"
url = "/zpm/docs/category/new-page/"
parent = "Category Name"
weight = 50
```

### Step 6: Test Locally

```bash
cd site
npm run dev
```

Navigate to your new page and verify it renders correctly.

### Step 7: Commit and Push

```bash
git add docs/{category}/{name}.md site/config/_default/menus/menus.en.toml
git commit -m "docs: add page title"
git push origin your-branch
```

## Writing Standards

### Tone

- **Clear and direct** — Avoid jargon unless defined
- **Active voice** — "Click the button" not "The button is to be clicked"
- **Imperative** — "Run the command" not "You should run the command"
- **Concise** — Every sentence adds value

### Formatting

- **Code blocks** — Use triple backticks with language (bash, json, yaml, etc.)
- **Inline code** — Use backticks for commands, flags, file names: `` `zpm` ``, `` `--flag` ``
- **Emphasis** — Use *italics* for emphasis, **bold** for strong emphasis
- **Lists** — Use ordered lists (1., 2., 3.) for step-by-step; unordered (-) for unordered items
- **Headings** — Use # H1 for page title, ## H2 for main sections, ### H3 for subsections

### Examples

- Always show expected output or result
- Include error messages if applicable
- Use realistic file names and values
- Test examples before committing

### Cross-References

Link to related pages using relative paths:

```markdown
[See the getting started guide](../getting-started/mcp-server.md)
[View the reference](../reference/cli.md)
```

## Before Submitting

- [ ] Documentation type matches content (tutorial vs. how-to vs. reference)
- [ ] Frontmatter includes title, description, and weight
- [ ] Content follows the appropriate template
- [ ] Examples are tested and working
- [ ] Markdown is valid (use `npm run build` to check)
- [ ] Internal links use relative paths and work locally
- [ ] No broken references to undefined terms
- [ ] Tone is consistent with existing docs
- [ ] Menu entry added if needed (site/config/_default/menus/menus.en.toml)

## Questions?

Refer to the [Diátaxis framework](https://diataxis.fr/) for deeper guidance on documentation types.
