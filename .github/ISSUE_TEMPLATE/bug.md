---
name: Bug
about: Something is broken or gives a wrong verdict
title: ""
labels: ["bug", "needs-triage"]
---

## What happens
<!-- One or two short sentences. Name the command and the exit code. -->

## Verified
<!-- The exact command and its output. Use a small fixture, not a real bundle. -->
```
$ okf-check <fixture>
```

## Expected

## Environment
- okf version (`okf-check --version`):
- OS:
- okflint (`okf-check --doctor`):

## Acceptance
- [ ] A test fails before the fix and passes after it.
- [ ] Suites pass: `okf-check.test.sh`, `okf-verify.test.sh`, `plugin.test.sh`, `--selftest`.
