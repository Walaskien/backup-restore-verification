# COMPOSE can be pointed at docker-compose v1 if v2 is not installed.
COMPOSE ?= docker compose
SHELLCHECK ?= shellcheck
PROMTOOL ?= docker run --rm -v "$(CURDIR)/prometheus:/etc/prometheus:ro" --entrypoint promtool prom/prometheus:v2.55.1
export COMPOSE_PROJECT_NAME := brv

.PHONY: up down clean backup verify orders lint test rules e2e

# The metrics directory has to exist before compose starts, otherwise docker
# creates it as root and the scripts cannot write to it.
up:
	mkdir -p data/backups/primary data/backups/secondary data/metrics
	$(COMPOSE) up -d
	@until docker exec brv-postgres pg_isready -q -h 127.0.0.1 -U app -d appdb; do sleep 1; done

down:
	$(COMPOSE) down -v

clean: down
	rm -rf data

backup:
	scripts/backup.sh

verify:
	scripts/verify-restore.sh

orders:
	scripts/add-orders.sh 100

lint:
	$(SHELLCHECK) -x scripts/*.sh tests/*.sh
	ruff check .
	ruff format --check .

test:
	pytest -q

rules:
	$(PROMTOOL) check config /etc/prometheus/prometheus.yml
	$(PROMTOOL) check rules /etc/prometheus/rules/backup.yml
	$(PROMTOOL) test rules /etc/prometheus/tests/backup_test.yml

e2e: up
	tests/e2e_happy_path.sh
	tests/e2e_corrupted_backup.sh
