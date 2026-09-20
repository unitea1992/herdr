---
name: herdr-pre-release-audit
description: Herdrのstable release前にchangelog・docs・issue参照・release gateを監査するときに使う。
---

# Herdr Pre-release Audit

Use this skill only inside the herdr repository.

Read `references/pre-release-audit.md` and follow its workflow. Treat it as the source of truth for:

- choosing the release base ref
- inspecting first-parent history and merged PRs
- auditing `docs/next/CHANGELOG.md`
- auditing `docs/next/README.md` and staged website docs
- checking `skills/herdr/SKILL.md` against shipped CLI and agent-control behavior
- checking issue reference lines
- deciding when to run `just pre-release-check` or its component checks
- running and assessing `just bench-render-scale`
- producing the final release-readiness report

Do not edit files during the audit unless the user explicitly asks to apply fixes. When applying fixes, keep changes scoped to the files named in the reference workflow.
