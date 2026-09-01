## What does this PR do?
Briefly describe the change.

## Related issue
Fixes #<!-- issue number -->

## Checklist
- [ ] `bash -n scripts/*.sh scripts/*/*.sh` passes (no syntax errors)
- [ ] `shellcheck -x` passes on changed scripts (if shellcheck installed)
- [ ] Only the scripts/components named in the description were touched
- [ ] No secrets / tokens / `SEED` values committed
- [ ] If a script was moved or paths changed: all call sites (workflows, other
      scripts, README, docs) were updated and the render test still passes

## Verification
What did you run to confirm this works? Paste relevant output/exit codes.

## Notes for reviewers
Any trade-offs, follow-up work, or things to double-check.
