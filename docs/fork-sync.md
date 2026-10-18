# Upstream Sync (fork → zed-industries/zed)

Use for recurring `main` syncs. PR pattern: `sync/upstream-YYYYMMDD` → `main`.

## 1. Start

```sh
git checkout main && git pull --rebase origin main
git fetch upstream main --tags
git rev-list --left-right --count HEAD...upstream/main  # ahead/behind
git checkout -B sync/upstream-$(date -u +%Y%m%d) upstream/main
git push -u origin sync/upstream-$(date -u +%Y%m%d) --force
gh pr create --base main --head sync/upstream-$(date -u +%Y%m%d) --title "sync: upstream/main (DATE)" --body "..."
```

## 2. Resolve (merge `origin/main` INTO sync branch, never the reverse)

```sh
git checkout sync/upstream-DATE
git merge --no-edit origin/main
git diff --name-only --diff-filter=U   # conflicted files
```

## 3. Conflict policy

- **Default: take upstream (`--ours`, since sync branch is upstream-based).**
  Applies to: `Cargo.lock`, `crates/edit_prediction/**`, `crates/gpui/**`,
  `crates/sidebar/**`, other upstream-refactored code.
- **Fork-critical renames — NEVER take upstream wholesale (Oct 2026 outage):**
  upstream added a compile-time assert (`crates/zed/src/main.rs`) that
  `paths::APP_NAME_LOWERCASE` matches the binary name, and this fork renames
  both to `zed-nightly`. Taking upstream's version of these files drops the
  rename and fails both architectures after an hour of compiling (`E0080`).
  After resolving, these must hold (the `prepare` guard in `mcp-nightly.yml`
  checks them before any build starts):
  - `crates/zed/Cargo.toml`: keep upstream `version`, but re-apply
    `[[bin]] name = "zed-nightly"` and `default-run = "zed-nightly"`.
  - `script/bundle-linux`: take upstream, then re-apply `zed-nightly` paths
    (`--bin zed-nightly` build flag, sentry/objcopy/ldd `release/zed-nightly`
    paths). Do NOT keep the old fork hunk blindly — upstream refactors this
    script often.
  - `crates/paths/src/paths.rs` (`APP_NAME = "Zed-Nightly"`) and
    `crates/cli/src/main.rs` (libexec lookup) usually auto-merge; verify.
- **MCP check before commit:**
  `ls .github/workflows/mcp-nightly.yml && grep -c -i mcp crates/agent_ui/src/mention_set.rs`
  Both must be non-empty. The MCP mention/completion code in
  `crates/agent_ui` + `crates/agent` auto-merges today — if it ever conflicts, prefer the
  fork hunk for `mention_set.rs`/`completion_provider.rs` and run `cargo test -p agent_ui`.

```sh
git checkout --ours -- <upstream-files...>
git add -A
GIT_EDITOR=true git commit -m "Merge main into sync/upstream-DATE: resolve N conflicts with upstream, keep MCP nightly"
git push origin sync/upstream-DATE
```

## 4. Verify

```sh
sleep 10; gh pr view <N> --repo Michael-Obele/zed --json mergeable,mergeStateStatus
# want: {"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
```

GitHub computes mergeability async — re-query after ~10s if still DIRTY.

## Notes

- Tracking policy: `main` follows upstream `main` (via `Sync upstream`), NOT
  stable tags. The stable-tag merge step in `mcp-nightly.yml` is a fallback for
  fresh/behind forks only; it skips when diverged. Don't reintroduce stable
  tracking without updating the release notes line and this doc.
- Pushes made with `GITHUB_TOKEN` do not trigger downstream workflows
  (release-plz docs). The sync job checks out with
  `UPSTREAM_SYNC_TOKEN || GITHUB_TOKEN` so a PAT, when present, lets a
  scheduled sync-merge trigger the follow-on build. Secret
  `UPSTREAM_SYNC_TOKEN` (fine-grained PAT: contents + PRs write on this repo)
  is still missing as of Oct 2026 — add it in Settings → Secrets → Actions.
- `release_nightly.yml`/`release.yml` are upstream-generated (`cargo xtask workflows`)
  with a `repository_owner == zed-industries` guard — they always skip on the fork.
  Don't "fix" by editing them; use `mcp-nightly.yml` / a fork workflow instead.
