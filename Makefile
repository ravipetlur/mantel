PROJECT := Mantel.xcodeproj
SCHEME := Mantel
DERIVED := build/DerivedData
# One destination, so that xcodebuild doesn't warn about the two it finds for this Mac ("My Mac" and "Any Mac").
DESTINATION := generic/platform=macOS
APP_DEBUG := $(DERIVED)/Build/Products/Debug/Mantel.app
APP_RELEASE := $(DERIVED)/Build/Products/Release/Mantel.app

# A release's version, its tag without the v (1.2.0, or 1.2.0-beta.1). The DMG is build/Mantel-$(VERSION).dmg, and the
# app's CFBundleShortVersionString is the version's leading three numbers (1.2.0), the form macOS expects; a version
# without them keeps project.yml's MARKETING_VERSION. Defaults to project.yml's MARKETING_VERSION, or dev.
VERSION ?= $(or $(shell sed -n -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9A-Za-z.+-]+)"?.*/\1/p' project.yml | head -n 1),dev)
# The Release build's CFBundleVersion (the release workflow passes its run number). Empty keeps project.yml's
# CURRENT_PROJECT_VERSION.
BUILD_NUMBER ?=
SHORT_VERSION = $(shell printf '%s\n' '$(VERSION)' | sed -n -E 's/^([0-9]+\.[0-9]+\.[0-9]+)([^0-9.].*)?$$/\1/p')

.PHONY: generate build build-release dmg test run install clean

generate:
	xcodegen generate --quiet

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(DERIVED) -quiet build

# The Release app, as a release is built. With VERSION and BUILD_NUMBER it is that version.
build-release: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination '$(DESTINATION)' -derivedDataPath $(DERIVED) -quiet \
		$(if $(SHORT_VERSION),MARKETING_VERSION=$(SHORT_VERSION)) $(if $(BUILD_NUMBER),CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)) build

# build/Mantel-$(VERSION).dmg: signed ad hoc, or with the identity in Config/Local.xcconfig if there is one. The release
# workflow signs and notarizes it.
dmg: build-release
	scripts/make-dmg.sh $(APP_RELEASE) '$(VERSION)' build

test:
	swift test --package-path MantelKit

run: build
	-pkill -x Mantel; while pgrep -x Mantel >/dev/null; do sleep 0.1; done
	open $(APP_DEBUG)

install: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination '$(DESTINATION)' -derivedDataPath $(DERIVED) -quiet build
	-pkill -x Mantel; while pgrep -x Mantel >/dev/null; do sleep 0.1; done
	rm -rf /Applications/Mantel.app
	cp -R $(APP_RELEASE) /Applications/Mantel.app
	open /Applications/Mantel.app

clean:
	rm -rf build
