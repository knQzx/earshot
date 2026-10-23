CONFIG ?= release
VERSION := $(shell tr -d '[:space:]' < VERSION)
APP := build/Earshot.app
ZIP := build/Earshot-$(VERSION).zip
INSTALL_DIR ?= $(HOME)/Applications
INSTALLED := $(INSTALL_DIR)/Earshot.app
HOOK := $(INSTALLED)/Contents/MacOS/earshot-hook
BUNDLE_ID := io.github.knqzx.earshot
LAUNCH_AGENT := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
SUPPORT_DIR := $(HOME)/Library/Application Support/Earshot
NETWORK_APIS := URLSession|NWConnection|NSURLConnection|CFNetwork|CFStream|import[[:space:]]+Network|/curl([^[:alnum:]_]|$$)|"curl"

.PHONY: build test app zip install uninstall hooks unhooks snapshot loc check-no-network icon clean help signing-identity

help:
	@echo "make build | test | app | zip | install | uninstall | hooks | unhooks"
	@echo "make snapshot | loc | check-no-network | icon | clean | signing-identity"

build:
	scripts/sbuild build -c $(CONFIG)

test:
	scripts/sbuild test

app:
	scripts/bundle.sh $(CONFIG)

signing-identity:
	scripts/signing-identity.sh

zip: app
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo $(ZIP)

define quit_running
	@if pgrep -xq Earshot; then \
		osascript -e 'if application id "$(BUNDLE_ID)" is running then tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true; \
		for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq Earshot || break; sleep 0.3; done; \
		pkill -x Earshot 2>/dev/null || true; \
	fi
endef

install: app
	$(quit_running)
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALLED)"
	ditto $(APP) "$(INSTALLED)"
	open "$(INSTALLED)"
	@echo "installed $(INSTALLED); run 'make hooks' once to connect Claude Code"

uninstall:
	@if [ -x "$(HOOK)" ]; then "$(HOOK)" --uninstall; else echo "no $(HOOK), skipping hook removal"; fi
	$(quit_running)
	-@launchctl bootout gui/$$(id -u)/$(BUNDLE_ID) 2>/dev/null
	rm -f "$(LAUNCH_AGENT)"
	rm -rf "$(INSTALLED)" "$(SUPPORT_DIR)"
	-@defaults delete $(BUNDLE_ID) 2>/dev/null
	@echo "Earshot removed"

hooks:
	@[ -x "$(HOOK)" ] || { echo "Earshot is not installed in $(INSTALL_DIR); run 'make install' first" >&2; exit 1; }
	"$(HOOK)" --install

unhooks:
	@[ -x "$(HOOK)" ] || { echo "Earshot is not installed in $(INSTALL_DIR)" >&2; exit 1; }
	"$(HOOK)" --uninstall

SNAPSHOTS := build/snapshots
MEDIA := collapsed approval-notch finished-notch memory-notch stack blocked missed usage request pill onboarding

snapshot: app
	rm -rf $(SNAPSHOTS)
	mkdir -p $(SNAPSHOTS) docs/media
	$(APP)/Contents/MacOS/Earshot --snapshot $(SNAPSHOTS)
	for f in $(MEDIA); do cp $(SNAPSHOTS)/$$f.png docs/media/$$f.png; done
	cp $(SNAPSHOTS)/panel.png docs/media/expanded.png
	cp $(SNAPSHOTS)/groups-naming.png docs/media/groups.png

loc:
	@for d in Sources/*/; do \
		printf '%6d  %s\n' $$(find "$$d" -name '*.swift' -exec cat {} + | grep -cv '^[[:space:]]*$$') "$$d"; \
	done
	@printf '%6d  total non-blank lines of Swift in Sources/\n' $$(find Sources -name '*.swift' -exec cat {} + | grep -cv '^[[:space:]]*$$')

check-no-network:
	@if grep -rnE --exclude=PolicyCatalog.swift '$(NETWORK_APIS)' Sources; then \
		echo "error: network APIs found in Sources/ (Earshot must not have network code)" >&2; exit 1; \
	else \
		echo "ok: no network APIs in Sources/"; \
	fi

icon:
	scripts/sbuild scripts/make-icon.swift Resources/AppIcon.icns

clean:
	rm -rf build .build
