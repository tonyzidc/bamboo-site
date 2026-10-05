# Bamboo-Site — developer tasks.
#
#   make lint           shellcheck every script (requires shellcheck)
#   make test           run the dependency-free test suite
#   make check          lint + test
#   make install-local  install this checkout to /opt/bamboo-site via install.sh --local
#   make help           show this message

SHELL := /usr/bin/env bash

SHELL_FILES := install.sh bin/bamboo-site $(wildcard lib/*.sh) $(wildcard commands/*.sh) $(wildcard tests/*.sh)

.PHONY: help lint test check install-local

help:
	@sed -n 's/^# \{0,1\}//p' Makefile | sed -n '1,8p'

lint:
	@command -v shellcheck >/dev/null 2>&1 || { \
		echo "shellcheck is not installed. Install it with 'brew install shellcheck' (macOS) or 'sudo apt-get install shellcheck' (Ubuntu), then re-run 'make lint'." >&2; \
		exit 1; \
	}
	@bash -n install.sh && bash -n bin/bamboo-site && echo "syntax OK: entrypoints"
	@for f in $(SHELL_FILES); do bash -n "$$f" || exit 1; done
	@echo "syntax OK: all scripts"
	@shellcheck -x $(SHELL_FILES) && echo "shellcheck OK"

test:
	@bash tests/run.sh

check: lint test

install-local:
	sudo ./install.sh --local
