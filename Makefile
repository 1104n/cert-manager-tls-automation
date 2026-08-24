SHELL := /bin/bash

KUBERNETES_VERSION ?= 1.32.0
KUBECONFORM_VERSION ?= v0.7.0
KUBE_LINTER_VERSION ?= v0.8.3

.PHONY: help validate lint security secrets test

help:
	@echo "make validate - validate deployable Kubernetes manifests"
	@echo "make lint     - lint deployable Kubernetes manifests"
	@echo "make security - run Trivy configuration scan"
	@echo "make secrets  - run Gitleaks secret scan"
	@echo "make test     - run all checks"

validate:
	@docker run --rm -v "$$(pwd):/workdir" -w /workdir ghcr.io/yannh/kubeconform:$$(KUBECONFORM_VERSION) -strict -summary -ignore-missing-schemas -kubernetes-version $$(KUBERNETES_VERSION) manifests/*.yaml

lint:
	@docker run --rm -v "$$(pwd):/workdir" -w /workdir stackrox/kube-linter:$$(KUBE_LINTER_VERSION) lint manifests/*.yaml

security:
	@trivy fs --scanners misconfig,secret --severity HIGH,CRITICAL --exit-code 1 .

secrets:
	@gitleaks detect --source . --no-banner

test: validate lint security secrets
