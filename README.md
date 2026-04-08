# zpm

A Zig package manager library built with hexagonal architecture.

## Installation

### From Source

```bash
git clone https://github.com/YOUR_ORG/zpm.git
cd zpm
zig build --summary all
```

### Prerequisites

- Zig 0.15.2+

## Usage

### As a Library

Add zpm as a dependency in your `build.zig.zon`, then import it in your build:

```zig
const zpm = b.dependency("zpm", .{
    .target = target,
    .optimize = optimize,
});
your_module.addImport("zpm", zpm.module("zpm"));
```

```zig
const zpm = @import("zpm");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try zpm.greet("World", stdout);
}
```

## Development

### Build

```bash
make build
```

### Test

```bash
make test
```

### Lint

```bash
make lint
```

### Format

```bash
make fmt
```

### Clean

```bash
make clean
```

## Project Structure

```
zpm/
├── src/
│   ├── domain/            # Business logic (no external deps)
│   ├── application/       # Use cases, services
│   ├── infrastructure/    # Adapters (I/O, network)
│   ├── interfaces/        # CLI entry point, config parsing
│   ├── domain.zig         # Domain barrel export
│   ├── application.zig    # Application barrel export
│   ├── infrastructure.zig # Infrastructure barrel export
│   ├── interfaces.zig     # Interfaces barrel export
│   └── root.zig           # Library entry point
├── build.zig
├── build.zig.zon
└── Makefile
```

## License

EUPL v1.2 - see [LICENSE](LICENSE) for details.
