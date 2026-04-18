---
title: "Site Configuration Reference"
---


This reference documents the zpm documentation site configuration, deployment, and customization options.

## Overview

The zpm documentation site is built with [Hugo](https://gohugo.io/) v0.147.8 using the [Thulite/Doks](https://getdoks.org/) theme. Configuration is defined in `site/config/_default/` with production overrides in `site/config/production/`.

## Configuration Files

```
site/config/_default/
  hugo.toml          # Main Hugo configuration (base URL, theme, modules)
  module.toml        # Hugo module configuration (theme, content mounts)
  params.toml        # Theme parameters (colors, navigation, search)
  languages.toml     # Language settings
  markup.toml        # Markdown and syntax highlighting
  menus/
    menus.en.toml    # Navigation menu structure
site/config/production/
  hugo.toml          # Production-specific overrides
```

## hugo.toml (Main Configuration)

### Base Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `baseURL` | `https://awf-project.github.io/zpm/` | Public URL where the site is deployed |
| `title` | `zpm` | Site title (appears in browser tab and header) |
| `description` | `A Prolog inference engine for MCP` | Site description (used in meta tags and search) |
| `languageCode` | `en-us` | Primary language code |
| `defaultContentLanguage` | `en` | Default language for content |
| `theme` | `github.com/thulite/doks/v1` | Theme module name and version |

### Build Settings

| Setting | Value | Description |
|---------|-------|-------------|
| `outputs` | `{...}` | Output formats (HTML, RSS, JSON feeds) |
| `ignoreFiles` | `\.template\.md$` | File patterns to exclude from the build |
| `timeout` | `30s` | Build timeout (prevents hanging builds) |
| `cleanDestinationDir` | `true` | Remove old output before building |

### Module Configuration

Modules define theme dependencies and content mounts. See `module.toml` below.

## module.toml (Theme & Mounts)

### Theme Module

```toml
[[module.imports]]
path = "github.com/thulite/doks/v1"
```

Imports the Doks theme which provides layouts, partials, and assets.

### Content Mounts

Content mounts map external directories into Hugo's content tree:

```toml
[[module.mounts]]
source = "content"
target = "content"

[[module.mounts]]
source = "../docs/getting-started"
target = "content/docs/getting-started"

[[module.mounts]]
source = "../docs/reference"
target = "content/docs/reference"

[[module.mounts]]
source = "../docs/user-guide"
target = "content/docs/user-guide"

[[module.mounts]]
source = "../docs/ADR"
target = "content/docs/adr"
```

This allows documentation in the repository's `docs/` directory to be rendered as part of the site without copying files.

## params.toml (Theme Parameters)

### Site Metadata

```toml
[params]
description = "A Prolog inference engine for MCP"
authors = ["AWF Project"]
```

### Navigation

```toml
[params.navigation]
logo = "/images/logo.png"     # Logo URL
sticky = true                  # Keep navbar sticky while scrolling
background = "light"           # Navbar background (light or dark)
```

### Search

```toml
[params.search]
enable = true                  # Enable site search
algolia = false                # Use Algolia (disabled for GitHub Pages)
```

### Colors & Branding

```toml
[params.colors]
primary = "#2060B2"           # Primary accent color
secondary = "#555555"          # Secondary accent color
```

See [Theme Documentation](https://getdoks.org/) for all available parameters.

## menus.en.toml (Navigation Structure)

Defines the navigation menu visible in the site header and sidebar.

### Menu Structure

```toml
[[main]]
name = "Docs"
url = "/zpm/docs/getting-started/"
weight = 10

[[main]]
name = "GitHub"
url = "https://github.com/awf-project/zpm"
weight = 20

[[docs]]
name = "Getting Started"
url = "/zpm/docs/getting-started/"
weight = 10
```

### Menu Fields

| Field | Description |
|-------|-------------|
| `name` | Display text in the menu |
| `url` | Link target (relative or absolute) |
| `weight` | Sort order (lower numbers appear first) |
| `parent` | Parent menu item (for nested menus) |

## languages.toml (Language Settings)

Currently, only English is enabled:

```toml
[en]
title = "zpm"
description = "A Prolog inference engine for MCP"
languageName = "English"
contentDir = "content"
weight = 1
```

Other languages can be enabled by adding similar blocks and translating content files.

## markup.toml (Markdown Settings)

```toml
[markup]
[markup.goldmark]
[markup.goldmark.renderer]
unsafe = true                  # Allow HTML in markdown
```

Controls markdown rendering behavior. `unsafe = true` allows embedding HTML in markdown files.

## production/hugo.toml (Production Overrides)

```toml
baseURL = "https://awf-project.github.io/zpm/"
[outputs]
[outputs.home]
formats = ["HTML", "RSS", "JSON"]
```

Production configuration ensures:
- Correct base URL for GitHub Pages
- All output formats are generated
- No draft or debug content is included

## Deployment Configuration

### GitHub Actions Workflow

Deployment is automated via `.github/workflows/hugo.yml`:

- **Trigger:** Pushes to `main` branch only
- **Build:** Hugo v0.147.8 with Node.js v24
- **Deploy:** Publishes to GitHub Pages
- **Branch:** Deploys from `gh-pages` branch

### Environment Variables

No environment variables required. GitHub token is automatically provided by GitHub Actions.

### Secrets

No secrets are stored in the site configuration. Deployment uses GitHub's built-in `GITHUB_TOKEN` for authentication.

## Customization Guide

### Change Site Title

Edit `site/config/_default/hugo.toml`:

```toml
title = "New Title"
description = "New description"
```

### Change Primary Color

Edit `site/config/_default/params.toml`:

```toml
[params.colors]
primary = "#FF0000"           # New color in hex
```

### Add Navigation Menu Item

Edit `site/config/_default/menus/menus.en.toml`:

```toml
[[main]]
name = "New Item"
url = "/zpm/docs/new-section/"
weight = 15
```

### Enable Search Engine Indexing

Edit `site/config/_default/params.toml`:

```toml
[params.analytics]
enable = true
google_analytics_id = "G-XXXXXXX"  # Add your Google Analytics ID
```

### Add Custom CSS

Place custom styles in `site/assets/css/custom.scss`. Hugo automatically concatenates them with theme styles.

```scss
// site/assets/css/custom.scss
.custom-class {
  color: $primary-color;
}
```

### Add Custom JavaScript

Place custom scripts in `site/assets/js/custom.js`. Hugo automatically includes them.

```javascript
// site/assets/js/custom.js
document.addEventListener('DOMContentLoaded', function() {
  // Custom behavior
});
```

## Troubleshooting

### Build Fails with Module Error

**Problem:** `failed to resolve module ...`

**Solution:** Ensure `go` is installed (`go version`) and run:
```bash
cd site
rm -rf resources/ && npm run build
```

### Site Looks Different Locally than Production

**Problem:** Local `npm run dev` looks different from production.

**Solution:** Build with production config:
```bash
cd site
HUGO_ENV=production npm run build
npm run preview
```

### Deploy Fails with Permission Error

**Problem:** GitHub Actions deploy job fails with "403 Forbidden".

**Solution:** Ensure GitHub Pages is enabled in repository settings:
1. Go to Settings → Pages
2. Set Source to "GitHub Actions"
3. Re-run the failed workflow

### Search Not Working

**Problem:** Search widget appears but returns no results.

**Solution:** Ensure search is enabled in `params.toml`:
```toml
[params.search]
enable = true
```

## See Also

- [Local Site Development](../getting-started/site-development.md)
- [Contributing to Documentation](../user-guide/contributing-docs.md)
- [Thulite/Doks Theme Documentation](https://getdoks.org/)
