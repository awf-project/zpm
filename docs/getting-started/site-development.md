---
title: "Local Site Development"
---


This guide walks you through setting up and previewing the zpm documentation site locally.

## What is the Site?

The zpm documentation site is a static site built with [Hugo](https://gohugo.io/) using the [Thulite/Doks](https://getdoks.org/) theme stack. It hosts the zpm documentation at `https://awf-project.github.io/zpm/` and updates automatically when changes are pushed to the `main` branch.

## Prerequisites

Install the following tools:

- **Node.js** v24 or later (for npm dependencies)
- **Hugo** v0.147.8 (for the static site generator)
- **Go** v1.22 (required by Hugo's module system)

### Installing Hugo

**macOS (Homebrew):**
```bash
brew install hugo
```

**Linux (package manager):**
```bash
# Arch
pacman -S hugo

# Ubuntu/Debian
sudo apt-get install hugo

# Fedora
sudo dnf install hugo
```

**Verify installation:**
```bash
hugo version
```

Ensure you have version 0.147.8 or later (ideally 0.147.8 to match the deployment workflow).

## Local Development Workflow

### Start the Development Server

Navigate to the `site/` directory and start the development server with live reload:

```bash
cd site
npm ci              # Install dependencies (run once per clone)
npm run dev         # Start local server at http://localhost:1313
```

The site rebuilds automatically as you edit files in `docs/` or `site/` directories.

### Edit Documentation

Documentation source files are in the repository's `docs/` directory:

```
docs/
  getting-started/      # Beginner tutorials and setup guides
  reference/            # Technical API and tool references
  user-guide/           # Task-focused how-to guides
  ADR/                  # Architecture decision records
```

Edit markdown files directly. The development server detects changes and reloads your browser.

### Build for Production

To build the static site for deployment:

```bash
cd site
npm run build        # Generates public/ directory with optimized HTML/CSS/JS
npm run preview      # Preview the production build locally
```

The output is written to `site/public/`. This is what gets deployed to GitHub Pages.

## Common Tasks

### Add a New Documentation Page

1. Create a markdown file in the appropriate `docs/` subdirectory:
   ```bash
   touch docs/user-guide/new-feature.md
   ```

2. Add Hugo frontmatter at the top:
   ```markdown
   ---
   title: "New Feature Title"
   description: "One-line summary"
   weight: 50
   ---

   # New Feature

   Content here...
   ```

3. Save and the dev server reloads automatically.

### Update the Homepage

The homepage is defined in `site/content/_index.md`. Edit this file to update the lead text, feature cards, or CTA buttons.

### Modify Site Configuration

Site configuration files are in `site/config/_default/`:

- **hugo.toml** — Base URL, theme, module configuration
- **params.toml** — Theme parameters (colors, search, analytics)
- **languages.toml** — Language settings
- **menus/menus.en.toml** — Navigation menu structure

Changes to configuration require restarting `npm run dev`.

## Troubleshooting

### Port 1313 Already in Use

If port 1313 is busy:

```bash
npm run dev -- --port 1314
```

Or kill the existing process:

```bash
lsof -ti:1313 | xargs kill -9
```

### Hugo Module Cache Issues

If you see module resolution errors, clear the cache:

```bash
rm -rf site/resources/
cd site && npm run dev
```

### Dependencies Out of Date

Regenerate `package-lock.json`:

```bash
cd site
rm package-lock.json
npm install --legacy-peer-deps
npm run dev
```

### Markdown Not Rendering

Ensure the file has proper Hugo frontmatter:

```markdown
---
title: "Page Title"
---

# Content starts here
```

Files without frontmatter are not recognized as content.

## Next Steps

- **[Contributing to Docs](../user-guide/contributing-docs.md)** — Guidelines for writing documentation
- **[Site Configuration Reference](../reference/site-config.md)** — Detailed configuration options
