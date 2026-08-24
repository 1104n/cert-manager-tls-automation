# Security Policy

## Supported Versions

Security fixes are applied to the latest version on the `main` branch.

## Reporting a Vulnerability

Do not open a public issue for a suspected vulnerability involving private keys, certificates, Kubernetes Secrets, or trust configuration.

Use GitHub private vulnerability reporting when available. Otherwise contact the repository owner through a private channel.

## Scope

This project contains examples and automation patterns for:

- Certificate authority hierarchies
- TLS certificates and private keys
- Kubernetes Secrets
- cert-manager issuers and certificates
- trust-manager bundles
- Workload TLS integration

## Secret Handling

Never commit real private keys, production certificates, kubeconfig files, service-account tokens, or production Kubernetes Secrets.

Example values and placeholders must remain non-production data.
