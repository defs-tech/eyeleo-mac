# EyeLeo for macOS — build
#
# A menu-bar utility does not need an .xcodeproj: one clang invocation, a resource copy and an
# ad-hoc signature are the whole build. xcodeproj files also conflict badly in merges.
#
#   make            build build/EyeLeo.app (ad-hoc signed, sandboxed)
#   make test       build and run the core unit tests
#   make run        build, then launch the app
#   make install    copy the built app to $(DESTDIR), by default /Applications
#   make uninstall  remove it from there again
#   make measure    report footprint, resident memory and cold-start time
#   make clean      remove build products
#
# Deployment target is macOS 26.0 only, per the decision to skip compatibility shims.

APP        := EyeLeo
BUILD      := build
APP_BUNDLE := $(BUILD)/$(APP).app
CONTENTS   := $(APP_BUNDLE)/Contents
MACOS_DIR  := $(CONTENTS)/MacOS
RES_DIR    := $(CONTENTS)/Resources

# Where "make install" puts the app. Overridable so the target can be exercised against a scratch
# directory instead of the real /Applications:  make install DESTDIR=/tmp/check
DESTDIR    ?= /Applications

SOURCES := $(wildcard src/*.m)
HEADERS := $(wildcard src/*.h)
RESOURCES := $(wildcard Resources/*.png) $(wildcard Resources/*.icns) $(wildcard Resources/Personages/*.png)
LOCALES := $(wildcard en.lproj/*.strings) $(wildcard ru.lproj/*.strings)

# The tea schedule template. Copied into the app on the first run, after which the user's own copy is
# the one read. It is a template and not a runtime asset: nothing in the bundle loads it, it is only
# ever copied out of.
TEA_CONF := tea.conf

CC := clang

# What the release builds are made for, as opposed to what a local build makes. A local build keeps the
# defaults, so `make` on any machine keeps producing what it always did; the release workflow overrides
# both. Nothing here needs a source change: the newest API in the project is SMAppService, which is
# macOS 13, and there are no third-party dependencies at all, only system frameworks.
#
# ARCHS left empty means "whatever this machine is", which is what a build for your own Mac wants. A
# universal build passes both, and the runner's SDK has both slices to link against, so nothing extra
# has to be installed for it.
ARCHS              ?=
DEPLOYMENT_TARGET ?= 26.0

ifneq ($(strip $(ARCHS)),)
ARCH_FLAGS := $(foreach a,$(ARCHS),-arch $(a))
endif

# -Os rather than -O2: this binary is loaded once and runs for hours, so code size is worth more
# than a fraction of a percent of speed. No Swift, so no runtime to drag in.
CFLAGS := -std=gnu11 -Os -fobjc-arc -mmacosx-version-min=$(DEPLOYMENT_TARGET) \
          -Wall -Wextra -Wno-unused-parameter -Werror=incompatible-pointer-types \
          -fvisibility=hidden -funsigned-char \
          $(ARCH_FLAGS) \
          -I src
LDFLAGS := -Wl,-dead_strip $(ARCH_FLAGS)
FRAMEWORKS := -framework AppKit -framework CoreGraphics -framework QuartzCore \
              -framework AudioToolbox -framework ServiceManagement \
              -framework Foundation

.PHONY: all test smoke run install uninstall measure clean

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(SOURCES) $(HEADERS) Info.plist entitlements.plist $(RESOURCES) $(LOCALES) $(TEA_CONF)
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR) $(RES_DIR)/Personages $(RES_DIR)/en.lproj $(RES_DIR)/ru.lproj
	@cp Info.plist $(CONTENTS)/Info.plist
	@# LaunchServices reads this key and refuses to launch the app on anything older, so it has to follow
	@# DEPLOYMENT_TARGET rather than sitting at the local default. The source Info.plist is untouched.
	@plutil -replace LSMinimumSystemVersion -string "$(DEPLOYMENT_TARGET)" $(CONTENTS)/Info.plist
	@cp Resources/*.png Resources/*.icns $(RES_DIR)/
	@cp Resources/Personages/*.png $(RES_DIR)/Personages/
	@# the whole .lproj directory has to be copied: macOS only treats Resources/<lang>.lproj/ as
	@# a localization, a flat Localizable.strings beside it is ignored
	@cp -R en.lproj $(RES_DIR)/
	@cp -R ru.lproj $(RES_DIR)/
	@# at the top of Resources rather than beside the executable, so a path built from the bundle works
	@cp $(TEA_CONF) $(RES_DIR)/
	@$(CC) $(CFLAGS) $(LDFLAGS) -o $(MACOS_DIR)/$(APP) $(SOURCES) $(FRAMEWORKS)
	@codesign --force --sign - --entitlements entitlements.plist --timestamp=none $(APP_BUNDLE)
	@echo "built $(APP_BUNDLE)"

# The tests link the core against a stub detector, so they run without a window server.
$(BUILD)/ebtest: tests/ebtest.m tests/ebdetect_stub.c src/ebcore.m src/ebtext.m src/ebgeometry.m src/ebassets.m src/ebexercise.m src/ebtea.m $(HEADERS)
	@mkdir -p $(BUILD)
	@$(CC) -std=gnu11 -O1 -g -fobjc-arc -mmacosx-version-min=$(DEPLOYMENT_TARGET) -I src \
	    -Wall -Wextra -Wno-unused-parameter \
	    -o $@ tests/ebtest.m tests/ebdetect_stub.c src/ebcore.m src/ebtext.m src/ebgeometry.m \
	    src/ebassets.m src/ebexercise.m src/ebtea.m \
	    -framework Foundation -framework AppKit -framework QuartzCore

test: $(BUILD)/ebtest
	@$(BUILD)/ebtest

# End-to-end check of the built app, not just the core.
smoke: $(APP_BUNDLE)
	@./tools/smoke.sh

run: $(APP_BUNDLE)
	@open $(APP_BUNDLE)

# Install into DESTDIR. Three things here are there because each one has a real failure behind it.
#
# The running check comes first because EyeLeo refuses to start a second instance: it counts running
# applications by bundle identifier and exits silently if it finds another. Copying over a bundle that
# is currently executing also leaves the live process reading a directory that no longer holds it.
#
# The rm -rf comes before the copy because ditto merges into an existing directory rather than
# replacing it, so a file deleted from the source between builds would survive in the installed copy.
#
# The signature check is last because the copy is the step that can corrupt it.
install: $(APP_BUNDLE)
	@if pgrep -f "$(APP).app/Contents/MacOS/$(APP)" >/dev/null 2>&1; then \
	    echo "EyeLeo is running; quit it before installing." >&2; \
	    echo "  pkill -f '$(APP).app/Contents/MacOS/$(APP)'" >&2; \
	    exit 1; \
	fi
	@if [ ! -d "$(DESTDIR)" ]; then \
	    echo "no such directory: $(DESTDIR)" >&2; exit 1; \
	fi
	@if [ ! -w "$(DESTDIR)" ]; then \
	    echo "cannot write to $(DESTDIR)." >&2; \
	    echo "Copy the already built bundle rather than re-running the build as root:" >&2; \
	    echo "  sudo ditto $(APP_BUNDLE) $(DESTDIR)/$(APP).app" >&2; \
	    exit 1; \
	fi
	@rm -rf "$(DESTDIR)/$(APP).app"
	@ditto "$(APP_BUNDLE)" "$(DESTDIR)/$(APP).app"
	@codesign --verify --strict "$(DESTDIR)/$(APP).app"
	@echo "installed $(DESTDIR)/$(APP).app"
	@echo "Settings and tea.conf are in the sandbox container and were not touched."

# Remove it again. The sandbox container is deliberately left alone: it holds the user's settings and
# their tea schemes, and deleting the app is not a request to delete those.
uninstall:
	@rm -rf "$(DESTDIR)/$(APP).app"
	@echo "removed $(DESTDIR)/$(APP).app"

measure: $(APP_BUNDLE)
	@./tools/measure.sh

clean:
	@rm -rf $(BUILD)
