# Makefile for DisplayDisabler.app
# Build:   make
# Clean:   make clean
# Install: make install (copies to /Applications)

APP_NAME   = DisplayDisabler
BUNDLE     = $(APP_NAME).app

CC         = clang
CFLAGS     = -fobjc-arc -Wall -Wextra -O2 -fstack-protector-strong \
             -mmacosx-version-min=14.0 -MMD -MP
FRAMEWORKS = -framework Cocoa -framework CoreGraphics -framework IOKit \
             -framework ServiceManagement -framework UserNotifications \
             -framework CoreDisplay
SOURCES    = main.m AppDelegate.m DisplayManager.m Brightness.m HiDPIInjector.m
OBJECTS    = $(SOURCES:.m=.o)
DEPS       = $(SOURCES:.m=.d)
EXECUTABLE = $(APP_NAME)

.PHONY: all clean bundle sign install uninstall icon

all: bundle sign

-include $(DEPS)

%.o: %.m
	$(CC) $(CFLAGS) -c $< -o $@

$(EXECUTABLE): $(OBJECTS)
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(OBJECTS) -o $@

# Render AppIcon.icns from the "display" SF Symbol on a dark rounded-rect
# background. One-shot build-time helper; the .icns is committed to the
# repo so CI / downstream builders don't need to re-run it.
AppIcon.icns: build_icon.m
	@$(CC) -fobjc-arc -O0 -mmacosx-version-min=14.0 -framework Cocoa \
	    build_icon.m -o /tmp/dd-build-icon
	@/tmp/dd-build-icon AppIcon.iconset
	@iconutil -c icns AppIcon.iconset -o AppIcon.icns
	@rm -rf AppIcon.iconset /tmp/dd-build-icon
	@echo "Built AppIcon.icns"

icon: AppIcon.icns

bundle: $(EXECUTABLE) AppIcon.icns
	@mkdir -p "$(BUNDLE)/Contents/MacOS"
	@mkdir -p "$(BUNDLE)/Contents/Resources"
	@cp $(EXECUTABLE) "$(BUNDLE)/Contents/MacOS/$(EXECUTABLE)"
	@cp Info.plist "$(BUNDLE)/Contents/Info.plist"
	@cp AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"
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
	@rm -rf "$(BUNDLE)" AppIcon.iconset
	@echo "Cleaned"
