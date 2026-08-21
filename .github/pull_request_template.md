<!--
Short is fine. The two prompts below are here because both have cost real
time in this repo before.
-->

## What this changes

## What I verified

<!--
Say plainly what you did NOT verify (repo rule 1). "BUILD SUCCEEDED" and
"TEST SUCCEEDED" say nothing about what is running: only
`scripts/install-local.sh` plus a check against the installed binary shows a
change actually shipped.
-->

- [ ] Tests pass (`xcodebuild ... test`)
- [ ] Ran against a real install (`scripts/install-local.sh`) — or say why not

Not verified:

## Checks

- [ ] Rebased on `origin/main`
- [ ] `CURRENT_PROJECT_VERSION` untouched — the release bump is its own commit
