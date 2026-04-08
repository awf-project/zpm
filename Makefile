.PHONY: build test fmt lint clean

build:
	zig build --summary all

test:
	zig build test --summary all

fmt:
	zig fmt .

lint:
	zig fmt --check .

clean:
	rm -rf zig-out .zig-cache
