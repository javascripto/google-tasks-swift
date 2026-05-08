APP_NAME := google-tasks
SELFTEST_NAME := google-tasks-selftest
BUILD_DIR := build
DIST_DIR := dist
SWIFT_BUILD_DIR := $(BUILD_DIR)/swift
RUN_STATE_DIR := $(BUILD_DIR)/run
RUN_LOG := $(RUN_STATE_DIR)/$(APP_NAME).log
PID_FILE := $(RUN_STATE_DIR)/$(APP_NAME).pid
ENV_FILE := .env.local
APP_BUNDLE := $(DIST_DIR)/GoogleTasks.app
APP_EXECUTABLE := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
APP_ICON := $(BUILD_DIR)/AppIcon.icns
APP_ICONSET := $(BUILD_DIR)/AppIcon.iconset

.PHONY: build run stop clean selftest package-app icon bundle

icon:
	@mkdir -p "$(BUILD_DIR)"
	@if [ ! -f "$(APP_ICON)" ]; then \
		rm -rf "$(APP_ICONSET)"; \
		swift run --scratch-path "$(SWIFT_BUILD_DIR)" google-tasks-icon "$(APP_ICONSET)"; \
		iconutil -c icns "$(APP_ICONSET)" -o "$(APP_ICON)"; \
	else \
		echo "Icon already exists: $(APP_ICON)"; \
	fi

build:
	swift build --scratch-path "$(SWIFT_BUILD_DIR)"

package-app: icon build
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp "$$(swift build --scratch-path "$(SWIFT_BUILD_DIR)" --show-bin-path)/$(APP_NAME)" "$(APP_EXECUTABLE)"
	cp "$(APP_ICON)" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	chmod +x "$(APP_EXECUTABLE)"
	printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'  <key>CFBundleExecutable</key>' \
		'  <string>$(APP_NAME)</string>' \
		'  <key>CFBundleIdentifier</key>' \
		'  <string>dev.yuri.google-tasks</string>' \
		'  <key>CFBundleName</key>' \
		'  <string>Google Tasks</string>' \
		'  <key>CFBundleIconFile</key>' \
		'  <string>AppIcon.icns</string>' \
		'  <key>CFBundleIconName</key>' \
		'  <string>AppIcon</string>' \
		'  <key>CFBundlePackageType</key>' \
		'  <string>APPL</string>' \
		'  <key>CFBundleShortVersionString</key>' \
		'  <string>0.1.0</string>' \
		'  <key>CFBundleVersion</key>' \
		'  <string>1</string>' \
		'  <key>LSMinimumSystemVersion</key>' \
		'  <string>14.0</string>' \
		'</dict>' \
		'</plist>' \
		> "$(APP_BUNDLE)/Contents/Info.plist"

run: stop package-app
	mkdir -p "$(RUN_STATE_DIR)"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(APP_BUNDLE)"
	open "$(APP_BUNDLE)"
	@sleep 1
	@PID=$$(pgrep -f "GoogleTasks.app/Contents/MacOS/$(APP_NAME)" | head -n 1); \
		if [ -n "$$PID" ]; then \
			echo $$PID > "$(PID_FILE)"; \
			echo "$(APP_NAME) running with PID $$PID"; \
		else \
			echo "$(APP_NAME) launched via open; PID not found yet"; \
		fi
	@echo "Log: $(RUN_LOG)"
	@echo "Bundle: $(APP_BUNDLE)"

stop:
	@if [ -f "$(PID_FILE)" ]; then \
		PID=$$(cat "$(PID_FILE)"); \
		if kill -0 "$$PID" 2>/dev/null; then \
			echo "Stopping $(APP_NAME) PID $$PID"; \
			kill "$$PID"; \
		fi; \
		rm -f "$(PID_FILE)"; \
	fi
	@pkill -f ".build/.*/$(APP_NAME)" 2>/dev/null || true
	@pkill -f "$(SWIFT_BUILD_DIR)/.*/$(APP_NAME)" 2>/dev/null || true
	@pkill -f "GoogleTasks.app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true

clean: stop
	rm -rf "$(BUILD_DIR)" "$(DIST_DIR)" .build

selftest:
	swift run --scratch-path "$(SWIFT_BUILD_DIR)" $(SELFTEST_NAME)

bundle: package-app
	@echo "App bundle criado: $(APP_BUNDLE)"
