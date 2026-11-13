# tooling/mk/tooling.mk: include this from the app's Makefile.
#   include tooling/mk/tooling.mk
# It reads tooling.env (KEY=VALUE lines in the app root) and pulls in the makefile of each footprint.

TOOLING_DIR := $(patsubst %/mk/,%,$(dir $(lastword $(MAKEFILE_LIST))))

-include tooling.env

# A bare `make` must not start real work. Unless the app set a default goal before this include (or sets
# one after it), the default goal is tooling-help, not the first target a footprint defines.
ifeq ($(.DEFAULT_GOAL),)
.DEFAULT_GOAL := tooling-help
endif

ifneq ($(filter ios flutter,$(TOOLING_FOOTPRINTS)),)
include $(TOOLING_DIR)/mk/ios.mk
endif

ifneq ($(filter supabase,$(TOOLING_FOOTPRINTS)),)
include $(TOOLING_DIR)/mk/supabase-local.mk
endif

.PHONY: tooling-help tooling-check tooling-version

tooling-help:
	@echo "tooling $$(cat $(TOOLING_DIR)/VERSION). Standard targets: setup test test-device local-up local-down screenshots listing beta release deploy-backend (an app defines the ones its footprints need). Also: tooling-check tooling-version."

# Fails when the app does not meet the contract (see tooling/README.md).
tooling-check:
	@python3 $(TOOLING_DIR)/bin/tooling-check .

tooling-version:
	@cat $(TOOLING_DIR)/VERSION
