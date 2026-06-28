# Benchmark orchestration shortcuts around the Ansible playbook.
# Run from the repo root, e.g. `make bench` or `make bench PARALLEL=4`.
# (ansible.cfg here sets the default inventory, so no -i is needed.)

PLAYBOOK := ansible/benchmark.yml
SECRETS  := ansible/secrets.yml
PARALLEL ?= 4
RUNTIME  ?= lmstudio

.DEFAULT_GOAL := help
.PHONY: help ping check smoke bench context-sweep

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

ping: ## Test SSH connectivity to the Proxmox host
	ansible proxmox -m ping

check: ## Syntax-check the playbook
	ansible-playbook $(PLAYBOOK) --syntax-check

smoke: ## Plumbing test: push suite + reload model, run NO benchmarks
	ansible-playbook $(PLAYBOOK) -e '{"benchmarks": []}'

bench: ## Run the full batch (PARALLEL=4 default; RUNTIME=lmstudio|llamacpp; e.g. make bench RUNTIME=llamacpp)
	ansible-playbook $(PLAYBOOK) -e @$(SECRETS) -e parallel=$(PARALLEL) -e runtime=$(RUNTIME)

context-sweep: ## Run the context-length sweep on top of the batch (PARALLEL/RUNTIME overridable)
	ansible-playbook $(PLAYBOOK) -e @$(SECRETS) -e parallel=$(PARALLEL) -e runtime=$(RUNTIME) -e context_sweep=true
