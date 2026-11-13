# tooling/mk/ios.mk: iOS UI tests. Included by tooling.mk when TOOLING_FOOTPRINTS has `ios` or `flutter`.
#
#   EXTRA_UI_TESTS   space-separated XCUITest ids, for example `RunnerUITests/AboutUITests`
#                    (Target/Class or Target/Class/method)
#   IOS_WORKSPACE    default ios/Runner.xcworkspace
#   IOS_SCHEME       default Runner
#
# Both settings usually live in tooling.env.

TOOLING_DIR ?= tooling
IOS_WORKSPACE ?= ios/Runner.xcworkspace
IOS_SCHEME ?= Runner

.PHONY: test-ui-extra

# Runs each id in EXTRA_UI_TESTS as its own `xcuitest ui-extra` run (full log kept, simulator from
# ios-sim), so new UI test classes run without an app listing them in a fixed -only-testing list. Call it
# from the app's stack-wrapped test-device recipe so the tests get the local stack:
#   tooling/bin/with-local-stack -- make test-ui-extra
# The values reach the shell through the environment, never spliced into the command line, and every id is
# validated before anything runs.
test-ui-extra: export TOOLING_UI_IDS := $(EXTRA_UI_TESTS)
test-ui-extra: export TOOLING_IOS_WORKSPACE := $(IOS_WORKSPACE)
test-ui-extra: export TOOLING_IOS_SCHEME := $(IOS_SCHEME)
test-ui-extra:
	@set -u -f; \
	for id in $$TOOLING_UI_IDS; do \
	  case "$$id" in \
	    *[!A-Za-z0-9_/]*|/*|*/|*//*) bad=1 ;; \
	    *) n=$$(printf %s "$$id" | tr -cd / | wc -c); if [ $$n -ge 1 ] && [ $$n -le 2 ]; then bad=0; else bad=1; fi ;; \
	  esac; \
	  if [ $$bad -ne 0 ]; then echo "✗ test-ui-extra: invalid test id '$$id' (expected Target/Class or Target/Class/method, letters, digits and _ only)"; exit 1; fi; \
	done; \
	if [ -z "$$(printf %s $$TOOLING_UI_IDS)" ]; then echo "no extra UI tests"; exit 0; fi; \
	udid=$$(bash $(TOOLING_DIR)/bin/ios-sim) || exit 1; \
	rc=0; \
	for id in $$TOOLING_UI_IDS; do \
	  $(TOOLING_DIR)/bin/xcuitest ui-extra -- -workspace "$$TOOLING_IOS_WORKSPACE" -scheme "$$TOOLING_IOS_SCHEME" -destination "id=$$udid" -only-testing:"$$id" || rc=$$?; \
	done; \
	exit $$rc
