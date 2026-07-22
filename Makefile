# Сборка и установка petable на этот Mac.
#
#   make install   — Release-сборка → /Applications/petable.app → запуск
#   make run       — Release-сборка и запуск из build/ (без установки)
#   make build     — только Release-сборка
#   make test      — юнит-тесты GraphCore
#   make clean     — удалить build/

APP        := petable
PROJECT    := petable.xcodeproj
SCHEME     := petable
DERIVED    := build/DerivedData
APP_BUNDLE := $(DERIVED)/Build/Products/Release/$(APP).app
INSTALL_DIR := /Applications

.PHONY: build install run test clean

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination "platform=macOS,arch=$(shell uname -m)" \
		-derivedDataPath $(DERIVED) build -quiet
	@echo "✓ Собрано: $(APP_BUNDLE)"

install: build
	@# Закрыть запущенную копию, иначе copy поверх работающего .app даёт битый бандл.
	-@pkill -x $(APP) 2>/dev/null; sleep 0.5; true
	rm -rf "$(INSTALL_DIR)/$(APP).app"
	ditto "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP).app"
	@echo "✓ Установлено: $(INSTALL_DIR)/$(APP).app"
	open "$(INSTALL_DIR)/$(APP).app"

run: build
	open "$(APP_BUNDLE)"

test:
	swift test

clean:
	rm -rf build
