# Proxmox LXC Scripts — development helpers
#
# Targets:
#   make lint   — run ShellCheck on all scripts
#   make test   — run bats unit tests (bash 4+ required for assoc arrays)
#   make check  — syntax check + lint + tests (used by CI)

BASH ?= $(shell bash -c 'command -v bash 2>/dev/null; command -v /opt/homebrew/bin/bash 2>/dev/null; command -v /usr/local/bin/bash 2>/dev/null' | while read -r b; do if "$$b" -c 'bash -n /dev/null' 2>/dev/null && "$$b" --version 2>/dev/null | grep -q "version 4\|version 5"; then echo "$$b"; break; fi; done)

SCRIPTS := dashboard-discover.sh install-avahi-all-lxcs.sh

.PHONY: lint test check

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not found. Install with: brew install shellcheck (macOS) or apt install shellcheck (Debian)"; exit 1; }
	shellcheck --severity=warning $(SCRIPTS)

test:
	@command -v bats >/dev/null 2>&1 || { echo "bats not found. Install with: brew install bats-core (macOS)"; exit 1; }
	BASH=$(BASH) bats tests/

check: lint
	@bash -n dashboard-discover.sh
	@bash -n install-avahi-all-lxcs.sh
	@command -v bats >/dev/null 2>&1 || { echo "bats not found. Install with: brew install bats-core (macOS)"; exit 1; }
	BASH=$(BASH) bats tests/