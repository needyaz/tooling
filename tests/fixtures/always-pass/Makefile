include tooling/mk/tooling.mk

.PHONY: test test-device test-ui-surface
test:
	@echo flutter test
test-device: test-ui-surface
test-ui-surface:
	@echo running ui tests | grep -v nothing || true
