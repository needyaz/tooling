# tooling/mk/tooling.mk: include this from the app's Makefile.
#   include tooling/mk/tooling.mk
# It reads tooling.env (KEY=VALUE lines in the app root) and pulls in the makefile of each footprint.

TOOLING_DIR := $(patsubst %/mk/,%,$(dir $(lastword $(MAKEFILE_LIST))))

-include tooling.env

ifneq ($(filter supabase,$(TOOLING_FOOTPRINTS)),)
include $(TOOLING_DIR)/mk/supabase-local.mk
endif

.PHONY: tooling-check tooling-version

# Fails when the app does not meet the contract (see tooling/README.md).
tooling-check:
	@python3 $(TOOLING_DIR)/bin/tooling-check .

tooling-version:
	@cat $(TOOLING_DIR)/VERSION
