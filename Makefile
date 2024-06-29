# Makefile for DisplayDisabler.app
# Build:   make
# Clean:   make clean
# Install: make install (copies to /Applications)

APP_NAME   = DisplayDisabler
BUNDLE     = $(APP_NAME).app

CC         = clang
CFLAGS     = -fobjc-arc -Wall -O2 -mmacosx-version-min=13.0 -MMD -MP
FRAMEWORKS = -framework Cocoa -framework CoreGraphics -framework IOKit \
             -framework ServiceManagement -framework UserNotifications
SOURCES    = main.m AppDelegate.m DisplayManager.m
OBJECTS    = $(SOURCES:.m=.o)
DEPS       = $(SOURCES:.m=.d)
EXECUTABLE = $(APP_NAME)

.PHONY: all clean bundle sign install uninstall

all: bundle sign

-include $(DEPS)

%.o: %.m
	$(CC) $(CFLAGS) -c $< -o $@

$(EXECUTABLE): $(OBJECTS)
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(OBJECTS) -o $@

bundle: $(EXECUTABLE)
	@mkdir -p "$(BUNDLE)/Contents/MacOS"
	@mkdir -p "$(BUNDLE)/Contents/Resources"
	@cp $(EXECUTABLE) "$(BUNDLE)/Contents/MacOS/$(EXECUTABLE)"
	@cp Info.plist "$(BUNDLE)/Contents/Info.plist"
	@/bin/echo -n "APPL????" > "$(BUNDLE)/Contents/PkgInfo"
	@echo "Built $(BUNDLE)"

sign: bundle
	@codesign --force --sign - --deep "$(BUNDLE)" 2>/dev/null
	@echo "Signed $(BUNDLE) (ad-hoc)"

install: all
	@cp -R "$(BUNDLE)" /Applications/
	@echo "Installed to /Applications/$(BUNDLE)"

uninstall:
	@rm -rf "/Applications/$(BUNDLE)"
	@echo "Removed /Applications/$(BUNDLE)"

clean:
	@rm -f $(OBJECTS) $(DEPS) $(EXECUTABLE)
	@rm -rf "$(BUNDLE)"
	@echo "Cleaned"
