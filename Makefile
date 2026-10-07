# EyeLeo for macOS — build
#
# A menu-bar utility does not need an .xcodeproj: one clang invocation, a resource copy and an
# ad-hoc signature are the whole build. xcodeproj files also conflict badly in merges.
#
#   make            build build/EyeLeo.app (ad-hoc signed, sandboxed)
#   make test       build and run the core unit tests
#   make run        build, then launch the app
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

SOURCES := $(wildcard src/*.m)
HEADERS := $(wildcard src/*.h)
RESOURCES := $(wildcard Resources/*.png) $(wildcard Resources/*.icns) $(wildcard Resources/Personages/*.png)
LOCALES := $(wildcard en.lproj/*.strings) $(wildcard ru.lproj/*.strings)

CC := clang
# -Os rather than -O2: this binary is loaded once and runs for hours, so code size is worth more
# than a fraction of a percent of speed. No Swift, so no runtime to drag in.
CFLAGS := -std=gnu11 -Os -fobjc-arc -mmacosx-version-min=26.0 \
          -Wall -Wextra -Wno-unused-parameter -Werror=incompatible-pointer-types \
          -fvisibility=hidden -funsigned-char \
          -I src
LDFLAGS := -Wl,-dead_strip
FRAMEWORKS := -framework AppKit -framework CoreGraphics -framework QuartzCore \
              -framework AudioToolbox -framework ServiceManagement \
              -framework Foundation

.PHONY: all test smoke run measure clean

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(SOURCES) $(HEADERS) Info.plist entitlements.plist $(RESOURCES) $(LOCALES)
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR) $(RES_DIR)/Personages $(RES_DIR)/en.lproj $(RES_DIR)/ru.lproj
	@cp Info.plist $(CONTENTS)/Info.plist
	@cp Resources/*.png Resources/*.icns $(RES_DIR)/
	@cp Resources/Personages/*.png $(RES_DIR)/Personages/
	@# the whole .lproj directory has to be copied: macOS only treats Resources/<lang>.lproj/ as
	@# a localization, a flat Localizable.strings beside it is ignored
	@cp -R en.lproj $(RES_DIR)/
	@cp -R ru.lproj $(RES_DIR)/
	@$(CC) $(CFLAGS) $(LDFLAGS) -o $(MACOS_DIR)/$(APP) $(SOURCES) $(FRAMEWORKS)
	@codesign --force --sign - --entitlements entitlements.plist --timestamp=none $(APP_BUNDLE)
	@echo "built $(APP_BUNDLE)"

# The tests link the core against a stub detector, so they run without a window server.
$(BUILD)/ebtest: tests/ebtest.m tests/ebdetect_stub.c src/ebcore.m src/ebtext.m src/ebgeometry.m src/ebassets.m src/ebexercise.m src/ebtea.m $(HEADERS)
	@mkdir -p $(BUILD)
	@$(CC) -std=gnu11 -O1 -g -fobjc-arc -mmacosx-version-min=26.0 -I src \
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

measure: $(APP_BUNDLE)
	@./tools/measure.sh

clean:
	@rm -rf $(BUILD)
