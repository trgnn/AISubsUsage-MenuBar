APP_NAME=AISubsUsage-MenuBar
BIN_NAME=AISubsUsageMenuBar
BUILD_DIR=build
# Command Line Tools ship the Swift Testing macro plugin outside the default
# search path; pass it explicitly when present (Xcode finds it on its own).
TESTING_PLUGINS=$(wildcard $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing)
TEST_FLAGS=$(if $(TESTING_PLUGINS),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

.PHONY: run app install test check clean

run:
	swift run

app:
	swift build -c release
	mkdir -p $(BUILD_DIR)/$(APP_NAME).app/Contents/MacOS $(BUILD_DIR)/$(APP_NAME).app/Contents/Resources
	cp .build/release/$(BIN_NAME) $(BUILD_DIR)/$(APP_NAME).app/Contents/MacOS/$(BIN_NAME)
	cp packaging/Info.plist $(BUILD_DIR)/$(APP_NAME).app/Contents/Info.plist
	cp packaging/AppIcon.icns $(BUILD_DIR)/$(APP_NAME).app/Contents/Resources/AppIcon.icns
	echo -n "APPL????" > $(BUILD_DIR)/$(APP_NAME).app/Contents/PkgInfo
	cp -R Resources/*.png Resources/*.svg $(BUILD_DIR)/$(APP_NAME).app/Contents/Resources/ 2>/dev/null || true
	@echo "Built $(BUILD_DIR)/$(APP_NAME).app (run 'make install' to copy to /Applications)"

install: app
	cp -R $(BUILD_DIR)/$(APP_NAME).app /Applications/
	@echo "Installed to /Applications/$(APP_NAME).app"

test:
	swift test $(TEST_FLAGS)

# Everything to run before pushing: tests, release bundle, repo hygiene.
check: test app
	scripts/check.sh

clean:
	rm -rf .build $(BUILD_DIR)
