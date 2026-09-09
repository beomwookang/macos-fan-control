CC      ?= clang
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter -std=c11 -arch arm64 -arch x86_64 -mmacosx-version-min=11.0
LDFLAGS ?= -framework IOKit -framework CoreFoundation
PREFIX  ?= /usr/local

BIN  = build/fanctl
SRC  = src/smc.c src/fanctl.c
APP  = build/Fanctl.app

all: $(BIN) $(APP)

$(BIN): $(SRC) src/smc.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS)
	@strip -x $@ 2>/dev/null || true
	@ls -lh $@

# The menu bar app. Built as a bare bundle rather than through Xcode so the
# whole project stays `make && sudo ./install.sh`. Ad-hoc signed: it is only
# ever installed locally, and the login item is a LaunchAgent rather than
# SMAppService precisely so no Developer ID is needed.
SWIFT = app/main.swift app/CurveEditor.swift

$(APP): $(SWIFT) app/Info.plist app/Fanctl.icns
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS
	swiftc -O -target arm64-apple-macos13.0   -o build/.Fanctl-arm64  $(SWIFT)
	swiftc -O -target x86_64-apple-macos13.0  -o build/.Fanctl-x86_64 $(SWIFT)
	lipo -create -output $(APP)/Contents/MacOS/Fanctl build/.Fanctl-arm64 build/.Fanctl-x86_64
	@rm -f build/.Fanctl-arm64 build/.Fanctl-x86_64
	cp app/Info.plist $(APP)/Contents/Info.plist
	@mkdir -p $(APP)/Contents/Resources
	cp app/Fanctl.icns $(APP)/Contents/Resources/Fanctl.icns
	codesign --force --sign - $(APP)
	@echo "built $(APP)"

app: $(APP)

clean:
	rm -rf build

install: $(BIN)
	./install.sh

uninstall:
	./uninstall.sh

.PHONY: all app clean install uninstall
