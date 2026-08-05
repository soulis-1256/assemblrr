.PHONY: test test-unit test-compose test-integration lint help

help:
	@echo "Targets:"
	@echo "  make test              unit + compose config + shellcheck"
	@echo "  make test-unit         pure shell unit tests"
	@echo "  make test-compose      docker compose config validation"
	@echo "  make test-integration  live watchdog test (needs ASSEMBLRR_ALLOW_LIVE_TEST=1)"
	@echo "  make lint              shellcheck"

test:
	./tests/run.sh all

test-unit:
	./tests/run.sh unit

test-compose:
	./tests/run.sh compose

test-integration:
	./tests/run.sh integration

lint:
	./tests/run.sh lint
