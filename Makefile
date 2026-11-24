# Textem build + bundle.
#
# `swift build` produces a bare Mach-O executable, not a .app — and a
# WKWebView shell needs a bundle (Info.plist for the UA/entitlements,
# notifications, code signing). `make bundle` wraps the binary into
# Textem.app so it launches like a real app.

APP        := Textem
BUNDLE_ID  := com.scarcrux.textem
CONFIG     := release
SWIFT      ?= xcrun --toolchain XcodeDefault swift
SWIFT_JOBS ?= $(if $(COMMANDEM_SWIFT_JOBS),$(COMMANDEM_SWIFT_JOBS),4)
SPARKLE_ARTIFACT = $(ARCH_BUILD_ROOT)/$(firstword $(ARCHS))/artifacts/sparkle/Sparkle
SPARKLE_FRAMEWORK = $(SPARKLE_ARTIFACT)/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
ARCHS      ?= arm64 x86_64
DEPLOYMENT_TARGET ?= 13.0
BIN        := scarcrux-textem
ARCH_BUILD_ROOT := .build/textem-arch
UNIVERSAL_BIN := .build/textem-universal/$(BIN)
APP_BUNDLE := $(APP).app
CONTENTS   := $(APP_BUNDLE)/Contents
VERSION    ?= 1.0b6
BUILD_NUMBER ?= 1

.PHONY: all build bundle run clean icloud-heal dmg sign release notarize require-developer-id
.NOTPARALLEL: release notarize

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
	@set -e; for arch in $(ARCHS); do \
	  $(SWIFT) build --jobs $(SWIFT_JOBS) -c $(CONFIG) \
	    --triple "$$arch-apple-macosx$(DEPLOYMENT_TARGET)" \
	    --scratch-path "$(ARCH_BUILD_ROOT)/$$arch"; \
	done
	@mkdir -p $(dir $(UNIVERSAL_BIN))
	@set -e; bins=""; for arch in $(ARCHS); do \
	  bin_dir="$$($(SWIFT) build --jobs $(SWIFT_JOBS) -c $(CONFIG) \
	    --triple "$$arch-apple-macosx$(DEPLOYMENT_TARGET)" \
	    --scratch-path "$(ARCH_BUILD_ROOT)/$$arch" --show-bin-path)"; \
	  bins="$$bins $$bin_dir/$(BIN)"; \
	done; lipo -create $$bins -output $(UNIVERSAL_BIN)

bundle: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $(UNIVERSAL_BIN) $(CONTENTS)/MacOS/$(APP)
	@mkdir -p $(CONTENTS)/Frameworks
	@ditto "$(SPARKLE_FRAMEWORK)" "$(CONTENTS)/Frameworks/Sparkle.framework"
	@cp "$(SPARKLE_ARTIFACT)/LICENSE" "$(CONTENTS)/Resources/Sparkle-LICENSE"
	@# SwiftPM's package-framework path is local to the build machine.
	@install_name_tool -add_rpath '@executable_path/../Frameworks' $(CONTENTS)/MacOS/$(APP)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(CONTENTS)/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(CONTENTS)/Info.plist
	@# Ad-hoc sign so WKWebView/WebKit XPC services launch under a stable
	@# identity. Replace with a real Developer ID for distribution.
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@for arch in $(ARCHS); do lipo $(CONTENTS)/MacOS/$(APP) -verify_arch "$$arch"; done
	@echo "built $(APP_BUNDLE) $(VERSION) ($(BUILD_NUMBER)) for $(ARCHS)"

run: bundle
	open $(APP_BUNDLE)

# Package the bundle into a compressed .dmg for distribution. Unsigned for
# now; Developer ID signing + notarization come before a public release.
DMG := $(APP).dmg
dmg: bundle
	@rm -f $(DMG)
	@hdiutil create -quiet -volname "$(APP)" -srcfolder $(APP_BUNDLE) -ov -format UDZO $(DMG)
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

require-developer-id:
	@test "$(CODESIGN_IDENTITY)" != "-" || { echo "set CODESIGN_IDENTITY to a Developer ID Application certificate"; exit 1; }

release: require-developer-id sign dmg
	@echo "release build ready: $(DMG)"
	@echo "to notarize: make notarize NOTARY_PROFILE=<profile>"

notarize:
	@test -n "$(NOTARY_PROFILE)" || { echo "set NOTARY_PROFILE (xcrun notarytool store-credentials ...)"; exit 1; }
	@codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)
	@rm -f .build/$(APP)-notary.zip
	@ditto -c -k --keepParent $(APP_BUNDLE) .build/$(APP)-notary.zip
	xcrun notarytool submit .build/$(APP)-notary.zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP_BUNDLE)
	xcrun stapler validate $(APP_BUNDLE)
	@rm -f .build/$(APP)-notary.zip $(DMG)
	@hdiutil create -quiet -volname "$(APP)" -srcfolder $(APP_BUNDLE) -ov -format UDZO $(DMG)
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
	xcrun stapler validate $(DMG)
	@echo "notarized + stapled $(DMG)"

clean:
	rm -rf $(APP_BUNDLE) $(DMG)
	rm -rf $(ARCH_BUILD_ROOT) $(dir $(UNIVERSAL_BIN))
	$(SWIFT) package clean 2>/dev/null || true
