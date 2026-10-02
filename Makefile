# Device signing: DEVELOPMENT_TEAM in Config/Local.xcconfig; DEVICE_UDID defaults to the first connected iPhone.
SCHEME  := VPNSpawner
DERIVED := build/install
APP     := VPNSpawner.app
APP_ID  := com.example.vpnspawner
DEVICE_UDID ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /connected/ {for (i=1;i<=NF;i++) if ($$i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$$/ || $$i ~ /^[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}$$/) {print $$i; exit}}')

.PHONY: help project test check device release screenshots

.DEFAULT_GOAL := help

help:
	@echo "make project      generate VPNSpawner.xcodeproj from project.yml"
	@echo "make test         controller unit tests (venv; skips tests/test_real_*, which create cloud resources)"
	@echo "make check        test + Release build for a generic iPhone"
	@echo "make device       Release build onto the paired iPhone"
	@echo "make release      check, then archive + upload to App Store Connect"
	@echo "make release BUILD=202610021830   same, with the build number pinned"
	@echo "make screenshots  SHOTS=<dir>  resize to the App Store slots"

project:
	xcodegen generate

test:
	venv/bin/python -m pytest tests -q --ignore-glob='tests/test_real_*'

check: test project
	xcodebuild -project $(SCHEME).xcodeproj -scheme $(SCHEME) -configuration Release \
	  -destination 'generic/platform=iOS' -derivedDataPath build/check -allowProvisioningUpdates -quiet build
	@echo "Release build OK"

device: project
	@test -n "$(DEVICE_UDID)" || { echo "No iPhone connected; set DEVICE_UDID (xcrun devicectl list devices)"; exit 1; }
	xcodebuild -project $(SCHEME).xcodeproj -scheme $(SCHEME) -configuration Release -destination 'generic/platform=iOS' \
	  -derivedDataPath $(DERIVED) -allowProvisioningUpdates build
	xcrun devicectl device install app --device $(DEVICE_UDID) $(DERIVED)/Build/Products/Release-iphoneos/$(APP)
	xcrun devicectl device process launch --device $(DEVICE_UDID) --terminate-existing $(APP_ID)

# Archive, sign for the App Store and upload — no Xcode Organizer.
# Needs Config/Local.xcconfig (Team ID) and the app record in App Store Connect.
release: check
	@git diff --quiet HEAD -- || echo "warning: uncommitted changes are going into this build"
	scripts/release-ios.sh $(BUILD)

screenshots:
	scripts/store-screenshots.sh $(SHOTS)
