# atlas-runner

This repository exists for one reason: **GitHub Actions minutes are unlimited on
a public repository and capped at 2,000 per month on a private one.**

A perpetual runner burns about 720 hours a month. On a private repo that budget
is gone in 33 hours. So the workflow that keeps the service alive lives here, in
the open, and the application it runs lives in a private repository that this
workflow checks out with a token.

## What is here

| | |
| --- | --- |
| `.github/workflows/atlas.yml` | boots the backend, joins the mesh, stays up 5 h 40 m, then launches its successor |

## What is deliberately not here

No application code. No database schema. No data, and no path that would
describe any. This repository is world-readable, so the rule is that reading all
of it tells you how a runner is kept alive and nothing else.

## How it works

GitHub kills a workflow run after six hours. The run therefore starts a
replacement before it dies, and the replacement does the same — so the service
survives a limit it cannot avoid. An always-on EC2 instance relays a fixed public
port to whichever runner is currently alive, so the address never changes.

The re-dispatch is conditional on the worker having stayed up more than 20
minutes. Without that brake, a run that fails immediately re-dispatches
immediately, and a broken state becomes a dispatch loop bounded only by GitHub's
abuse detection.

## Do not

- Do not make this repository private. The minute cap is the whole point.
- Do not commit anything that is not the workflow.
- Do not add a secret here that is not consumed by the workflow.

Generated from `deploy/runner/` in the private repository. Edit it there.
