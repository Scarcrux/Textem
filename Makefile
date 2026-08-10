# Textem build + bundle.
#
# `swift build` produces a bare Mach-O executable, not a .app — and a
# WKWebView shell needs a bundle (Info.plist for the UA/entitlements,
# notifications, code signing). `make bundle` wraps the binary into
# Textem.app so it launches like a real app.

APP        := Textem
BUNDLE_ID  := com.scarcrux.textem
CONFIG     := release
BUILD_DIR  := .build/$(CONFIG)
BIN        := scarcrux-textem
APP_BUNDLE := $(APP).app
CONTENTS   := $(APP_BUNDLE)/Contents

.PHONY: all build bundle run clean icloud-heal

all: bundle

# iCloud hygiene (per CLAUDE.md): `.build` must be a symlink to
# `.build.nosync`. If it's missing or materialized back into a real dir,
# re-create the redirect before building so churny build output stays out
# of iCloud and doesn't spawn conflicted copies.
icloud-heal:
	@if [ ! -L .build ]; then \
		if [ -d .build ] && [ ! -d .build.nosync ]; then \
			echo "healing: moving real .build -> .build.nosync"; \
			mv .build .build.nosync; \
		fi; \
		rm -rf .build; \
		mkdir -p .build.nosync; \
		ln -s .build.nosync .build; \
		echo "healed: .build -> .build.nosync"; \
	fi

build: icloud-heal
	swift build -c $(CONFIG)

bundle: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $(BUILD_DIR)/$(BIN) $(CONTENTS)/MacOS/$(APP)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	@# Ad-hoc sign so WKWebView/WebKit XPC services launch under a stable
	@# identity. Replace with a real Developer ID for distribution.
	@codesign --force --deep --sign - $(APP_BUNDLE) 2>/dev/null || true
	@echo "built $(APP_BUNDLE)"

run: bundle
	open $(APP_BUNDLE)

# Package the bundle into a compressed .dmg for distribution. Unsigned for
# now; Developer ID signing + notarization come before a public release.
DMG := $(APP).dmg
dmg: bundle
	@rm -f $(DMG)
	@hdiutil create -volname "$(APP)" -srcfolder $(APP_BUNDLE) -ov -format UDZO $(DMG) >/dev/null
	@echo "built $(DMG)"

# --- Release: Developer ID signing + notarization -----------------
# Requires your credentials (see README). Examples:
#   make sign CODESIGN_IDENTITY="Developer ID Application: You (TEAMID)"
#   make release CODESIGN_IDENTITY="Developer ID Application: You (TEAMID)"
#   make notarize NOTARY_PROFILE=textem-notary   # from notarytool store-credentials
CODESIGN_IDENTITY ?= -
ENTITLEMENTS := Resources/Textem.entitlements

# Hardened runtime is required for notarization. Ad-hoc ("-") is the default
# so this is testable locally; pass a Developer ID for a distributable build.
sign: bundle
	@codesign --force --deep --timestamp --options runtime \
	  $(if $(wildcard $(ENTITLEMENTS)),--entitlements $(ENTITLEMENTS),) \
	  --sign "$(CODESIGN_IDENTITY)" $(APP_BUNDLE)
	@codesign --verify --strict --verbose=2 $(APP_BUNDLE)
	@echo "signed $(APP_BUNDLE) with: $(CODESIGN_IDENTITY)"

release: sign dmg
	@echo "release build ready: $(DMG)"
	@echo "to notarize: make notarize NOTARY_PROFILE=<profile>"

notarize:
	@test -n "$(NOTARY_PROFILE)" || { echo "set NOTARY_PROFILE (xcrun notarytool store-credentials ...)"; exit 1; }
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP_BUNDLE)
	$(MAKE) dmg
	xcrun stapler staple $(DMG)
	@echo "notarized + stapled $(DMG)"

clean:
	rm -rf $(APP_BUNDLE) $(DMG)
	swift package clean 2>/dev/null || true
