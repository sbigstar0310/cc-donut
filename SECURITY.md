# Security Policy

## Reporting a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/sbigstar0310/ccx/security/advisories/new).
Do not open a public issue for security problems.

## Supported versions

Only the latest `main` (and the newest tag) receives fixes. Installation follows
the default branch, so update with `/ccx:update` before reporting.

## What matters most here

ccx handles an OpenRouter API key. The threat model we care about:

- The key must live only in `~/.claude/ccx/providers/keys.env` (mode 600) or the
  `OPENROUTER_API_KEY` environment variable.
- It must never be printed to logs, statuslines, diagnostics, shell traces, or
  committed to the repository.

If you find a path where the key (or any credential) leaks, that is a security
issue — please report it privately.
