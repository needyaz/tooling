# tooling/mk/supabase-local.mk: the local Supabase stack. Included by tooling.mk when TOOLING_FOOTPRINTS
# has `supabase`. Settings come from tooling.env, which bin/supabase-local reads itself.

TOOLING_DIR ?= tooling

.PHONY: local-up local-down local-status local-functions

local-up:
	@$(TOOLING_DIR)/bin/supabase-local up

local-down:
	@$(TOOLING_DIR)/bin/supabase-local down

local-status:
	@$(TOOLING_DIR)/bin/supabase-local status

# Serves the app's edge functions on the local stack. Refuses any explicit ENV other than local.
local-functions:
	@if [ "$(origin ENV)" = "command line" ] && [ "$(ENV)" != local ]; then echo "✗ local-functions only serves the local stack (ENV=local); got ENV=$(ENV)"; exit 1; fi
	@$(TOOLING_DIR)/bin/supabase-local functions-up
