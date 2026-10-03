.PHONY: all build app dmg extension test smoke stress install clean

all: build

build:
	swift build -c release

app:
	./scripts/package_app.sh

dmg:
	./scripts/package_dmg.sh

extension:
	./scripts/install_zed_extension.sh

test:
	swift test

smoke:
	./smoke_test.sh

stress:
	./stress_test.sh

install: build extension
	mkdir -p ~/.local/bin
	cp .build/release/zeddy ~/.local/bin/zeddy
	cp .build/release/zeddy-mcp ~/.local/bin/zeddy-mcp
	cp .build/release/zeddy-daemon ~/.local/bin/zeddy-daemon
	@echo "Installed zeddy, zeddy-mcp, zeddy-daemon to ~/.local/bin and Zed extension to ~/Library/Application Support/Zed/extensions/installed/zeddy"

clean:
	rm -rf .build dist
