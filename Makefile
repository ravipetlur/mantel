PROJECT := Mantel.xcodeproj
SCHEME := Mantel
FIXTURE_SCHEME := MantelTestItem
DERIVED := build/DerivedData
APP_DEBUG := $(DERIVED)/Build/Products/Debug/Mantel.app
APP_RELEASE := $(DERIVED)/Build/Products/Release/Mantel.app
FIXTURE_DEBUG := $(DERIVED)/Build/Products/Debug/MantelTestItem.app

.PHONY: generate build test run install install-fixtures clean

generate:
	xcodegen generate --quiet

# The app, and the test item the probes change in its place (Debug only).
build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -quiet build
	xcodebuild -project $(PROJECT) -scheme $(FIXTURE_SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -quiet build

test:
	swift test --package-path MantelKit

run: build
	-pkill -x Mantel; while pgrep -x Mantel >/dev/null; do sleep 0.1; done
	open $(APP_DEBUG)

install: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) -quiet build
	-pkill -x Mantel; while pgrep -x Mantel >/dev/null; do sleep 0.1; done
	rm -rf /Applications/Mantel.app
	cp -R $(APP_RELEASE) /Applications/Mantel.app
	open /Applications/Mantel.app

# The test item for the platform test, in /Applications, where the system honours the allowlist. It is not started: open it,
# or run `mantel probe` with the test item as the app to change.
install-fixtures: generate
	xcodebuild -project $(PROJECT) -scheme $(FIXTURE_SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -quiet build
	-pkill -x MantelTestItem; while pgrep -x MantelTestItem >/dev/null; do sleep 0.1; done
	rm -rf /Applications/MantelTestItem.app
	cp -R $(FIXTURE_DEBUG) /Applications/MantelTestItem.app

clean:
	rm -rf build
