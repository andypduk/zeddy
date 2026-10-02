.PHONY: all build app test smoke install clean

all: build

build:
	swift build -c release

app:
	./scripts/package_app.sh

test:
	swift test

smoke:
	./smoke_test.sh

install: build
	mkdir -p ~/.local/bin
	cp .build/release/zeddy ~/.local/bin/zeddy
	cp .build/release/zeddy-mcp ~/.local/bin/zeddy-mcp
	cp .build/release/zeddy-daemon ~/.local/bin/zeddy-daemon
	@echo "Installed zeddy, zeddy-mcp, zeddy-daemon to ~/.local/bin"

clean:
	rm -rf .build dist
