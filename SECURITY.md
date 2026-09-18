# Security Policy

## Supported versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a vulnerability

Please do **not** open a public issue for security vulnerabilities.

Use GitHub's **private vulnerability reporting** (Security tab → Report a vulnerability) or contact the repository owner directly.

Please include:

- A description of the issue and its potential impact.
- Steps to reproduce, if applicable.
- The macOS version and plugin version you tested with.

## What to expect

- Acknowledgement of your report within a reasonable time.
- No public disclosure before a fix or mitigation is available.
- Credit in the release notes if you wish.

## Scope notes

This plugin runs locally, collects no telemetry, opens no network connections, and sends data only to DynamicLake over its local plugin socket for rendering. Normal logs omit full file paths.
