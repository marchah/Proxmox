# Benchmark orchestration shortcuts around the Ansible playbook.
# Run from the repo root, e.g. `make bench` or `make bench GPU=2 SUITE=short`.
# (ansible.cfg here sets the default inventory, so no -i is needed.)

PLAYBOOK := ansible/benchmark.yml
SECRETS  := ansible/secrets.yml
# GPU=1 benchmarks CT 120 (0000:03:00.0), GPU=2 CT 123 (0000:83:00.0). PARALLEL
# defaults per GPU in ansible/benchmark.yml (GPU 1: 4, GPU 2: 1).
GPU      ?= 1
PARALLEL ?=
RUNTIME  ?= llamacpp
# SUITE=full adds the agent-session and document-ingestion workloads to the batch;
# SUITE=short is the regression items only. AGENT=false or INGEST=false drops one.
SUITE    ?= full
AGENT    ?= true
INGEST   ?= true
SELECT   := -e suite=$(SUITE) -e run_agent_sessions=$(AGENT) -e run_doc_ingest=$(INGEST)
TARGET   := -e gpu=$(GPU) $(if $(PARALLEL),-e parallel=$(PARALLEL)) -e runtime=$(RUNTIME)

.DEFAULT_GOAL := help
.PHONY: help ping check smoke bench context-sweep

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

ping: ## Test SSH connectivity to the Proxmox host
	ansible proxmox -m ping

check: ## Syntax-check the playbook
	ansible-playbook $(PLAYBOOK) --syntax-check

smoke: ## Plumbing test: push suite + reload model, run NO benchmarks (GPU, PARALLEL overridable)
	ansible-playbook $(PLAYBOOK) $(TARGET) -e '{"benchmarks": []}'

bench: ## Run the batch (GPU=1|2, SUITE=full|short, AGENT/INGEST=false, PARALLEL)
	ansible-playbook $(PLAYBOOK) -e @$(SECRETS) $(TARGET) $(SELECT)

context-sweep: ## Run the context-length sweep on top of the batch (same flags as bench)
	ansible-playbook $(PLAYBOOK) -e @$(SECRETS) $(TARGET) $(SELECT) -e context_sweep=true
