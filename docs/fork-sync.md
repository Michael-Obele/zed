# Upstream Sync (fork → zed-industries/zed)

Use when the automatic stable merge in `mcp-nightly.yml` fails and a human
needs to resolve conflicts. PR pattern: `sync/stable-YYYYMMDD` → `main`.

## 1. Start

`main` tracks the latest upstream **stable release**, not `upstream/main`.
Resolve the tag with `/releases/latest` (it excludes prereleases and drafts):

```sh
git checkout main && git pull --rebase origin main
git fetch upstream --tags --force
STABLE=$(gh api repos/zed-industries/zed/releases/latest --jq .tag_name)  # e.g. v1.27.0
git rev-list --left-right --count HEAD..."$STABLE"  # ahead/behind
git checkout -B sync/stable-$(date -u +%Y%m%d) "$STABLE"
git push -u origin sync/stable-$(date -u +%Y%m%d) --force
gh pr create --base main --head sync/stable-$(date -u +%Y%m%d) --title "sync: stable $STABLE (DATE)" --body "..."
```

## 2. Resolve (merge `origin/main` INTO sync branch, never the reverse)

```sh
git checkout sync/upstream-DATE
git merge --no-edit origin/main
git diff --name-only --diff-filter=U   # conflicted files
```

## 3. Conflict policy

- **Default: take upstream (`--ours`, since the sync branch is tag-based).**
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

- Tracking policy: `main` follows the latest upstream **stable release**
  (`/releases/latest`), not `upstream/main`. `mcp-nightly.yml` merges that tag,
  resolves the expected `RELEASE_CHANNEL` conflict, then builds and releases.
  `sync-upstream.yml` opens a `sync/stable-*` PR as the manual fallback when the
  automatic merge hits an unexpected conflict. Don't point either workflow at
  `upstream/main`; that pulls nightly code into a stable-based `main`.
- Pushes made with `GITHUB_TOKEN` do not trigger downstream workflows
  (release-plz docs). The sync job checks out with
  `UPSTREAM_SYNC_TOKEN || GITHUB_TOKEN` so a PAT, when present, lets a
  scheduled sync-merge trigger the follow-on build. Secret
  `UPSTREAM_SYNC_TOKEN` needs Contents + Pull requests + Workflows write on
  this repo (fine-grained PAT: Workflows Read and write, or classic `workflow`
  scope) — without Workflows write the sync-branch push is rejected with
  `refusing to allow ... without 'workflow' scope` whenever upstream touched
  `.github/workflows/*` (seen 2026-10-31; note there is no `workflows:` job
  permission scope — the scope must come from the PAT itself).
  Add/rotate it in Settings → Secrets → Actions.
- `release_nightly.yml`/`release.yml` are upstream-generated (`cargo xtask workflows`)
  with a `repository_owner == zed-industries` guard — they always skip on the fork.
  Don't "fix" by editing them; use `mcp-nightly.yml` / a fork workflow instead.
