SHELL := /bin/bash

.PHONY: dev build run test package

dev:
	bash ./scripts/dev.sh

build:
	swift build

run:
	swift run

test:
	swift test

package:
	VERSION="$(VERSION)" \
	ARCH="$(ARCH)" \
	CONFIGURATION="$(CONFIGURATION)" \
	BUNDLE_ID="$(BUNDLE_ID)" \
	DIST_DIR="$(DIST_DIR)" \
	CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	bash ./scripts/package.sh
