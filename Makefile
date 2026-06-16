
APP_NAME   = DisplayDeck
BUNDLE     = $(APP_NAME).app

CC         = clang
CFLAGS     = -fobjc-arc -Wall -Wextra -O2 -fstack-protector-strong \
             -mmacosx-version-min=14.0 -MMD -MP
INCLUDES   = -Isrc/app -Isrc/common -Isrc/display -Isrc/power \
             -Isrc/transparency -Isrc/window
FRAMEWORKS = -framework Cocoa -framework CoreGraphics -framework IOKit \
             -framework ServiceManagement -framework UserNotifications \
             -framework CoreDisplay -framework Metal -framework QuartzCore \
             -framework ApplicationServices -framework Carbon
SOURCES    = src/main.m \
             src/app/AppDelegate.m \
             src/common/DDUtil.m \
             src/display/DisplayManager.m src/display/HiDPIInjector.m \
             src/display/Brightness.m src/display/BrightnessBooster.m \
             src/display/ColorTemperature.m \
             src/power/Caffeine.m \
             src/transparency/WindowTransparency.m \
             src/window/WindowPiP.m src/window/WindowManager.m
OBJECTS    = $(SOURCES:.m=.o)
DEPS       = $(SOURCES:.m=.d)
EXECUTABLE = $(APP_NAME)

# Stable code-signing identity. A local self-signed cert keeps the app's code
# identity (and therefore TCC grants like Accessibility) constant across rebuilds —
# ad-hoc signing changes the cdhash every build, which silently invalidates the
# grant. Falls back to ad-hoc if the cert isn't present (CI / other machines).
# Recreate with: make signing-identity
SIGN_KEYCHAIN    = $(HOME)/Library/Keychains/displaydeck-signing.keychain-db
SIGN_KEYCHAIN_PW = displaydeck
SIGN_ID := $(shell security find-identity -p codesigning "$(SIGN_KEYCHAIN)" 2>/dev/null | grep -o "DisplayDeck Self-Signed" | head -1)
ifeq ($(strip $(SIGN_ID)),)
CODESIGN_ID  = -
CODESIGN_KC  =
SIGN_LABEL   = ad-hoc
else
CODESIGN_ID  = DisplayDeck Self-Signed
CODESIGN_KC  = --keychain "$(SIGN_KEYCHAIN)"
SIGN_LABEL   = DisplayDeck Self-Signed (stable)
endif

SA_DIR     = sa
SA_FLAGS   = -O2 -arch arm64e -mmacosx-version-min=11.0
SA_BIN     = $(SA_DIR)/bin

.PHONY: all clean bundle sign install uninstall icon sa zip signing-identity

all: bundle sign

-include $(DEPS)

%.o: %.m
	$(CC) $(CFLAGS) $(INCLUDES) -c $< -o $@

$(EXECUTABLE): $(OBJECTS)
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(OBJECTS) -o $@

$(SA_BIN)/loader: $(SA_DIR)/loader.m
	@mkdir -p $(SA_BIN)
	@$(CC) $(SA_FLAGS) -framework Cocoa $(SA_DIR)/loader.m -o $@
	@codesign -f -s - $@

$(SA_BIN)/payload: $(SA_DIR)/payload.m
	@mkdir -p $(SA_BIN)
	@$(CC) $(SA_FLAGS) -shared -fPIC -F /System/Library/PrivateFrameworks \
	    -framework SkyLight -framework Foundation $(SA_DIR)/payload.m -o $@
	@codesign -f -s - $@

sa: $(SA_BIN)/loader $(SA_BIN)/payload
	@echo "Built scripting addition (arm64e)"

AppIcon.icns: tools/build_icon.m
	@$(CC) -fobjc-arc -O0 -mmacosx-version-min=14.0 -framework Cocoa \
	    tools/build_icon.m -o /tmp/dd-build-icon
	@/tmp/dd-build-icon AppIcon.iconset
	@iconutil -c icns AppIcon.iconset -o AppIcon.icns
	@rm -rf AppIcon.iconset /tmp/dd-build-icon
	@echo "Built AppIcon.icns"

icon: AppIcon.icns

bundle: $(EXECUTABLE) AppIcon.icns sa
	@mkdir -p "$(BUNDLE)/Contents/MacOS"
	@mkdir -p "$(BUNDLE)/Contents/Resources/sa"
	@cp $(EXECUTABLE) "$(BUNDLE)/Contents/MacOS/$(EXECUTABLE)"
	@cp resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
	@cp AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	@cp $(SA_BIN)/loader $(SA_BIN)/payload "$(BUNDLE)/Contents/Resources/sa/"
	@/bin/echo -n "APPL????" > "$(BUNDLE)/Contents/PkgInfo"
	@echo "Built $(BUNDLE)"

sign: bundle
	@if [ "$(CODESIGN_ID)" != "-" ]; then \
	    security unlock-keychain -p "$(SIGN_KEYCHAIN_PW)" "$(SIGN_KEYCHAIN)" 2>/dev/null || true; fi
	@codesign --force --sign "$(CODESIGN_ID)" $(CODESIGN_KC) "$(BUNDLE)/Contents/MacOS/$(EXECUTABLE)"
	@codesign --force --sign "$(CODESIGN_ID)" $(CODESIGN_KC) "$(BUNDLE)"
	@echo "Signed $(BUNDLE) ($(SIGN_LABEL))"

# One-time: create the local self-signed code-signing identity. Survives rebuilds,
# so the Accessibility (and other TCC) grants stick instead of re-prompting.
signing-identity:
	@OSSL=$$(command -v /opt/homebrew/bin/openssl || command -v openssl); \
	KC="$(SIGN_KEYCHAIN)"; PW="$(SIGN_KEYCHAIN_PW)"; \
	security delete-keychain "$$KC" 2>/dev/null || true; \
	security create-keychain -p "$$PW" "$$KC"; \
	security set-keychain-settings "$$KC"; \
	security unlock-keychain -p "$$PW" "$$KC"; \
	printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=DisplayDeck Self-Signed\n[v3]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > /tmp/dd.cnf; \
	$$OSSL req -x509 -newkey rsa:2048 -keyout /tmp/dd.key -out /tmp/dd.crt -days 7300 -nodes -config /tmp/dd.cnf -extensions v3 2>/dev/null; \
	$$OSSL pkcs12 -export -legacy -inkey /tmp/dd.key -in /tmp/dd.crt -out /tmp/dd.p12 -name "DisplayDeck Self-Signed" -passout pass:"$$PW" 2>/dev/null; \
	security import /tmp/dd.p12 -k "$$KC" -P "$$PW" -T /usr/bin/codesign -A; \
	security set-key-partition-list -S apple-tool:,apple:,unsigned: -s -k "$$PW" "$$KC" >/dev/null 2>&1; \
	EX=$$(security list-keychains -d user | sed 's/"//g' | xargs); security list-keychains -d user -s "$$KC" $$EX; \
	rm -f /tmp/dd.key /tmp/dd.crt /tmp/dd.p12 /tmp/dd.cnf; \
	echo "Created signing identity:"; security find-identity -p codesigning "$$KC"

install: all
	@rm -rf "/Applications/$(BUNDLE)"
	@cp -R "$(BUNDLE)" /Applications/
	@echo "Installed to /Applications/$(BUNDLE)"

zip: all
	@rm -f "$(APP_NAME).app.zip"
	@ditto -c -k --keepParent "$(BUNDLE)" "$(APP_NAME).app.zip"
	@echo "Wrote $(APP_NAME).app.zip ($$(shasum -a 256 "$(APP_NAME).app.zip" | cut -d' ' -f1))"

uninstall:
	@rm -rf "/Applications/$(BUNDLE)"
	@echo "Removed /Applications/$(BUNDLE)"
	@if [ -e /Library/DisplayDeck ] || [ -e /etc/sudoers.d/displaydeck ]; then \
	    echo "Removing scripting addition (requires admin)…"; \
	    sudo rm -rf /Library/DisplayDeck /etc/sudoers.d/displaydeck && \
	    echo "Removed scripting addition + sudoers entry"; \
	fi

clean:
	@rm -f $(OBJECTS) $(DEPS)
	@find . -name '*.o' -o -name '*.d' | xargs rm -f 2>/dev/null || true
	@rm -f $(EXECUTABLE) AppIcon.icns
	@rm -rf "$(BUNDLE)" AppIcon.iconset $(SA_BIN)
	@echo "Cleaned"
