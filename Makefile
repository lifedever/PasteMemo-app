SHELL := /bin/bash

.PHONY: dev build run test check check-staged install-hooks package

dev:
	bash ./scripts/dev.sh

build:
	swift build

run:
	swift run

test:
	swift test

check:
	bash ./scripts/check.sh --all

check-staged:
	bash ./scripts/check.sh --staged

install-hooks:
	bash ./scripts/install-hooks.sh

package:
	VERSION="$(VERSION)" \
	ARCH="$(ARCH)" \
	CONFIGURATION="$(CONFIGURATION)" \
	BUNDLE_ID="$(BUNDLE_ID)" \
	DIST_DIR="$(DIST_DIR)" \
	CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	bash ./scripts/package.sh
