# `ps` branch — JFrog Professional Services customizations

## Purpose

This repository is a fork of [jfrog/charts](https://github.com/jfrog/charts). The
`ps` branch is where **all JFrog Professional Services (PS) specific work**
lives — scripts, docs, and values files under the [`ps/`](.) directory
(migration tooling, lab setup templates, comparison/transfer utilities, etc.).

`master` is kept as a **pure, unmodified mirror of upstream** `jfrog/charts`.
No PS commits are ever made directly on `master`. This is intentional — see
"Why this exists" below.

## Why this exists

GitHub's **"Sync fork"** button fast-forwards (or, if the branch has diverged,
offers to **discard** the diverged commits and hard-reset) `master` to match
`jfrog/charts:master`. If PS commits live on `master`, clicking "Sync fork"
(and accepting the "discard commits" option) **permanently deletes them** —
there is no merge, no warning beyond a confirmation dialog, and no recovery
via GitHub once it's done (the commits are only recoverable from a local
clone's reflog, if one exists).

This happened once already: `master` had diverged from upstream by dozens of
PS-only commits under `ps/`. A "Sync fork" discarded all of them. They were
only recoverable because a local clone still had `master` at the old commit;
that history was used to create this `ps` branch.

## The safe workflow going forward

1. **Never commit directly to `master`.** All PS work happens on `ps` (or a
   short-lived feature branch cut from `ps`, merged back via PR).
2. **`master` only ever moves via upstream sync** — either GitHub's
   "Sync fork" button, or the CLI equivalent below. Since `master` never has
   divergent commits, syncing it is always a safe fast-forward. Nothing to
   lose.
3. **Periodically bring `ps` up to date with the freshly-synced `master`:**

   ```bash
   git fetch github-ps-jfrog master
   git checkout ps
   git merge github-ps-jfrog/master -m "Merge upstream-synced master into ps branch"
   # resolve any conflicts (usually just chart version/CHANGELOG bumps —
   # take upstream's side with `git checkout --theirs <file>` for files
   # outside ps/)
   git push github-ps-jfrog ps
   ```

4. **Optional — sync upstream without the GitHub button at all:**

   ```bash
   git remote add upstream https://github.com/jfrog/charts.git   # one-time
   git fetch upstream
   git checkout master
   git merge --ff-only upstream/master   # fails loudly if master ever diverged
   git push github-ps-jfrog master
   ```

   The `--ff-only` flag is a safety net: if `master` ever accidentally picks
   up a local commit, this command refuses to proceed instead of silently
   discarding anything.

## TL;DR

- Do PS work on **`ps`**, not `master`.
- `master` = upstream mirror, always safe to sync.
- After syncing `master`, merge it into `ps` to pick up upstream updates.
