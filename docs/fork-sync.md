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
  Applies to: `Cargo.lock`, `crates/zed/Cargo.toml` (keep upstream version, e.g. 1.26.0 not 1.23.3),
  `crates/edit_prediction/**`, `crates/gpui/**`, `crates/sidebar/**`, other upstream-refactored code.
- **Always keep fork files:** `.github/workflows/mcp-nightly.yml`,
  `.github/workflows/sync-upstream.yml`, `build-and-clean.sh`, fork branding
  (`zed-nightly` binary name, About-window notice, install-from-own-releases docs).
- **`script/bundle-linux`:** take upstream, then re-apply fork deltas in a follow-up
  (non-fatal sentry upload, `zed-nightly` binary paths). Do NOT keep the old fork hunk blindly —
  upstream refactors this script often.
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
- Actions are disabled on this fork; the `sync-upstream.yml` workflow can't dispatch
  until enabled (Settings → Actions). Until then, do syncs locally as above.
- `release_nightly.yml`/`release.yml` are upstream-generated (`cargo xtask workflows`)
  with a `repository_owner == zed-industries` guard — they always skip on the fork.
  Don't "fix" by editing them; use `mcp-nightly.yml` / a fork workflow instead.
