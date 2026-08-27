SHELL := /bin/bash
.DEFAULT_GOAL := help

KUBERNETES_VERSION ?= 1.32.0
KUBECONFORM_VERSION ?= v0.7.0
KUBE_LINTER_VERSION ?= v0.8.3

# Timeouts to prevent hanging processes
DOCKER_TIMEOUT ?= 300s
TRIVY_TIMEOUT ?= 300s

.PHONY: help validate lint security secrets test test-parallel test-serial pull-images clean

help:
	@echo "Makefile targets for cert-manager-tls-automation"
	@echo ""
	@echo "make validate       - validate deployable Kubernetes manifests (kubeconform)"
	@echo "make lint           - lint deployable Kubernetes manifests (kube-linter)"
	@echo "make security       - run Trivy configuration scan"
	@echo "make secrets        - run Gitleaks secret scan"
	@echo "make test           - run all checks sequentially (default)"
	@echo "make test-parallel  - run all checks in parallel for faster execution"
	@echo "make test-serial    - explicitly run all checks sequentially"
	@echo "make pull-images    - pre-pull Docker images for faster test execution"
	@echo "make clean          - clean up temporary files and Docker images"

# Pre-pull images to avoid repeated downloads during test runs
pull-images:
	@echo "Pre-pulling Docker images..."
	docker pull ghcr.io/yannh/kubeconform:$(KUBECONFORM_VERSION)
	docker pull stackrox/kube-linter:$(KUBE_LINTER_VERSION)
	@echo "Images pulled successfully"

validate:
	@echo "Running kubeconform validation..."
	@docker run --rm \
		--timeout $(DOCKER_TIMEOUT) \
		-v "$$(pwd):/workdir" \
		-w /workdir \
		ghcr.io/yannh/kubeconform:$(KUBECONFORM_VERSION) \
		-strict \
		-summary \
		-ignore-missing-schemas \
		-kubernetes-version $(KUBERNETES_VERSION) \
		manifests/*.yaml
	@echo "✓ Validation passed"

lint:
	@echo "Running kube-linter checks..."
	@docker run --rm \
		--timeout $(DOCKER_TIMEOUT) \
		-v "$$(pwd):/workdir" \
		-w /workdir \
		stackrox/kube-linter:$(KUBE_LINTER_VERSION) \
		lint manifests/*.yaml
	@echo "✓ Linting passed"

security:
	@echo "Running Trivy security scan..."
	@timeout $(TRIVY_TIMEOUT) trivy fs \
		--scanners misconfig,secret \
		--severity HIGH,CRITICAL \
		--exit-code 1 \
		.
	@echo "✓ Security scan passed"

secrets:
	@echo "Running Gitleaks secret detection..."
	@gitleaks detect --source . --no-banner
	@echo "✓ Secret scan passed"

# Serial execution (default) - runs checks one after another
test-serial: validate lint security secrets
	@echo ""
	@echo "✓ All checks passed (serial execution)"

# Parallel execution - runs checks concurrently for faster overall execution
test-parallel:
	@echo "Running all checks in parallel..."
	@trap "kill $$(jobs -p)" EXIT; \
	$(MAKE) validate & \
	$(MAKE) lint & \
	$(MAKE) security & \
	$(MAKE) secrets & \
	wait
	@echo ""
	@echo "✓ All checks passed (parallel execution)"

# Default to serial execution for safety and clearer output
test: test-serial

clean:
	@echo "Cleaning up..."
	@docker rmi ghcr.io/yannh/kubeconform:$(KUBECONFORM_VERSION) stackrox/kube-linter:$(KUBE_LINTER_VERSION) 2>/dev/null || true
	@echo "✓ Cleanup complete"
