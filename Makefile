# Сборка и установка petable на этот Mac.
#
#   make install          — Release-сборка → /Applications/petable.app → запуск
#   make run              — демон + install: закрыть старую копию, поставить
#                           свежую в /Applications, открыть (одна иконка)
#   make build            — только Release-сборка
#   make test             — юнит-тесты GraphCore
#   make clean            — удалить build/
#   make daemon-install   — собрать petable-daemon, поставить LaunchAgent, включить
#   make daemon-uninstall — выключить и снять LaunchAgent
#   make daemon-status    — состояние демона в launchd

APP        := petable
PROJECT    := petable.xcodeproj
SCHEME     := petable
DERIVED    := build/DerivedData
APP_BUNDLE := $(DERIVED)/Build/Products/Release/$(APP).app
INSTALL_DIR := /Applications

# Демон (П0): бинарь — в стабильном пути (НЕ внутри worktree: сборки
# из разных worktree не должны ронять plist), Mach-сервис — в LaunchAgents.
DAEMON_LABEL := com.egorproskurin.petable.daemon
DAEMON_DIR   := $(HOME)/Library/Application Support/Petable
DAEMON_BIN   := $(DAEMON_DIR)/petable-daemon
DAEMON_PLIST := $(HOME)/Library/LaunchAgents/$(DAEMON_LABEL).plist
UID          := $(shell id -u)

.PHONY: build install run test clean daemon-install daemon-uninstall daemon-status

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

# install уже закрывает старую копию и открывает свежую из /Applications.
# Раньше здесь был второй `open` сборки из build/ — В ДОКЕ ПОЯВЛЯЛИСЬ ДВЕ
# КОПИИ приложения (два разных пути = два процесса).
run: daemon-install install

test:
	swift test

clean:
	rm -rf build

daemon-install:
	swift build -c release --product petable-daemon
	@# Стабильная подпись (как у приложения): TCC/Keychain-разрешения
	@# демона переживают пересборку; нет identity — ad-hoc fallback.
	-@codesign --force --sign "Apple Development" .build/release/petable-daemon 2>/dev/null \
	  || codesign --force --sign - .build/release/petable-daemon
	@# Снять старый инстанс, если был (иначе копия поверх работающего бинаря).
	-@launchctl bootout gui/$(UID)/$(DAEMON_LABEL) 2>/dev/null; true
	mkdir -p "$(DAEMON_DIR)"
	cp .build/release/petable-daemon "$(DAEMON_BIN)"
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0">' \
	  '<dict>' \
	  '  <key>Label</key><string>$(DAEMON_LABEL)</string>' \
	  '  <key>Program</key><string>$(DAEMON_BIN)</string>' \
	  '  <key>MachServices</key><dict><key>$(DAEMON_LABEL)</key><true/></dict>' \
	  '  <key>StandardErrorPath</key><string>$(DAEMON_DIR)/daemon.log</string>' \
	  '</dict>' \
	  '</plist>' > "$(DAEMON_PLIST)"
	launchctl bootstrap gui/$(UID) "$(DAEMON_PLIST)"
	@echo "✓ Демон включён: $(DAEMON_LABEL) (запустится по первому XPC-обращению)"
	@echo "  Лог: $(DAEMON_DIR)/daemon.log · статус: make daemon-status"

daemon-uninstall:
	-@launchctl bootout gui/$(UID)/$(DAEMON_LABEL) 2>/dev/null; true
	rm -f "$(DAEMON_PLIST)" "$(DAEMON_BIN)"
	@echo "✓ Демон выключен и снят"

daemon-status:
	@launchctl print gui/$(UID)/$(DAEMON_LABEL) 2>/dev/null \
	  | grep -E "state|pid|path|last exit" \
	  || echo "демон не установлен (make daemon-install)"
