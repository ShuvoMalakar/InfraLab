# InfraLab control. Each service is an independent compose project.
#   make up                     # start everything in SERVICES order
#   make up SERVICE=kafka       # start one service
#   make down SERVICE=kafka     # stop one (keeps data)
#   make nuke SERVICE=kafka     # stop AND delete its volumes
#   make status                 # what's up (containers, clusters, VM)
#   make status-page            # install the 30s timer + start the web status page (:8090)
#   make ps | logs SERVICE=kafka | health | smoke

SERVICES := redis-cluster kafka status-page
SERVICE  ?=
TARGETS  := $(if $(SERVICE),$(SERVICE),$(SERVICES))
ENV_FILE := $(CURDIR)/.env

compose = docker compose --env-file "$(ENV_FILE)" -p $(1) -f services/$(1)/docker-compose.yml

.PHONY: up down restart nuke status status-page ps logs pull health smoke check-env

check-env:
	@test -f "$(ENV_FILE)" || { echo "Missing .env — run bootstrap/vm-setup.sh or cp .env.example .env"; exit 1; }
	@docker network inspect infra-net >/dev/null 2>&1 || docker network create infra-net >/dev/null

up: check-env
	@for s in $(TARGETS); do echo "==> up $$s"; $(call compose,$$s) up -d --remove-orphans || exit 1; done

down: check-env
	@for s in $(TARGETS); do echo "==> down $$s"; $(call compose,$$s) down --remove-orphans; done

restart: down up

nuke: check-env
	@test -n "$(SERVICE)" || { echo "nuke requires SERVICE=<name>"; exit 1; }
	@read -p "Delete ALL data volumes of $(SERVICE)? [y/N] " a; [ "$$a" = "y" ] || exit 1
	$(call compose,$(SERVICE)) down -v --remove-orphans

pull: check-env
	@for s in $(TARGETS); do $(call compose,$$s) pull; done

status:
	@./scripts/status.sh

status-page: check-env
	sudo ./scripts/install-status-timer.sh
	$(call compose,status-page) up -d
	@echo "Public URL: http://$$(curl -fs -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip || echo '<VM-external-IP>'):8090"
	@echo "(needs the GCP firewall rule infralab-status-public, see README)"

ps:
	@docker ps --filter network=infra-net --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

logs: check-env
	@test -n "$(SERVICE)" || { echo "logs requires SERVICE=<name>"; exit 1; }
	$(call compose,$(SERVICE)) logs -f --tail=200

health:
	@./scripts/healthcheck.sh

smoke:
	@./scripts/smoke-test.sh
