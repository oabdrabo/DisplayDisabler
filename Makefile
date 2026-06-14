
APP_NAME   = DisplayDisabler
BUNDLE     = $(APP_NAME).app

CC         = clang
CFLAGS     = -fobjc-arc -Wall -Wextra -O2 -fstack-protector-strong \
             -mmacosx-version-min=14.0 -MMD -MP
FRAMEWORKS = -framework Cocoa -framework CoreGraphics -framework IOKit \
             -framework ServiceManagement -framework UserNotifications \
             -framework CoreDisplay
SOURCES    = main.m AppDelegate.m DisplayManager.m Brightness.m HiDPIInjector.m \
             WindowTransparency.m
OBJECTS    = $(SOURCES:.m=.o)
DEPS       = $(SOURCES:.m=.d)
EXECUTABLE = $(APP_NAME)

SA_FLAGS   = -O2 -arch arm64e -mmacosx-version-min=11.0
SA_BIN     = sa/bin

.PHONY: all clean bundle sign install uninstall icon sa

all: bundle sign

-include $(DEPS)

%.o: %.m
	$(CC) $(CFLAGS) -c $< -o $@

$(EXECUTABLE): $(OBJECTS)
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(OBJECTS) -o $@

$(SA_BIN)/loader: sa/loader.m
	@mkdir -p $(SA_BIN)
	@$(CC) $(SA_FLAGS) -framework Cocoa sa/loader.m -o $@
	@codesign -f -s - $@

$(SA_BIN)/payload: sa/payload.m
	@mkdir -p $(SA_BIN)
	@$(CC) $(SA_FLAGS) -shared -fPIC -F /System/Library/PrivateFrameworks \
	    -framework SkyLight -framework Foundation sa/payload.m -o $@
	@codesign -f -s - $@

sa: $(SA_BIN)/loader $(SA_BIN)/payload
	@echo "Built scripting addition (arm64e)"

AppIcon.icns: build_icon.m
	@$(CC) -fobjc-arc -O0 -mmacosx-version-min=14.0 -framework Cocoa \
	    build_icon.m -o /tmp/dd-build-icon
	@/tmp/dd-build-icon AppIcon.iconset
	@iconutil -c icns AppIcon.iconset -o AppIcon.icns
	@rm -rf AppIcon.iconset /tmp/dd-build-icon
	@echo "Built AppIcon.icns"

icon: AppIcon.icns

bundle: $(EXECUTABLE) AppIcon.icns sa
	@mkdir -p "$(BUNDLE)/Contents/MacOS"
	@mkdir -p "$(BUNDLE)/Contents/Resources/sa"
	@cp $(EXECUTABLE) "$(BUNDLE)/Contents/MacOS/$(EXECUTABLE)"
	@cp Info.plist "$(BUNDLE)/Contents/Info.plist"
	@cp AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	@cp $(SA_BIN)/loader $(SA_BIN)/payload sa/install.sh "$(BUNDLE)/Contents/Resources/sa/"
	@/bin/echo -n "APPL????" > "$(BUNDLE)/Contents/PkgInfo"
	@echo "Built $(BUNDLE)"

sign: bundle
	@codesign --force --sign - "$(BUNDLE)/Contents/MacOS/$(EXECUTABLE)"
	@codesign --force --sign - "$(BUNDLE)"
	@echo "Signed $(BUNDLE) (ad-hoc)"

install: all
	@cp -R "$(BUNDLE)" /Applications/
	@echo "Installed to /Applications/$(BUNDLE)"

uninstall:
	@rm -rf "/Applications/$(BUNDLE)"
	@echo "Removed /Applications/$(BUNDLE)"

clean:
	@rm -f $(OBJECTS) $(DEPS) $(EXECUTABLE) AppIcon.icns
	@rm -rf "$(BUNDLE)" AppIcon.iconset $(SA_BIN)
	@echo "Cleaned"
