# Zed MCP Fork — CI Build & Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Michael-Obele/zed` (upstream Zed + the `@mcp` context-server mention patch) on GitHub Actions on a daily schedule, publish Linux `.tar.gz` binaries to Releases with an unofficial-test-build disclaimer, and let those binaries self-update from those releases.

**Architecture:** `main` is the fork's build branch. One new workflow (`.github/workflows/mcp-nightly.yml`) merges the latest upstream *stable tag* plus `origin/feat/mcp-mention` into `main`, runs a seconds-long marker guard, builds both Linux arches in a matrix, and publishes a prerelease. The app is compiled with `RELEASE_CHANNEL=nightly` and a patched updater that reads this fork's GitHub Releases instead of `cloud.zed.dev`; because the nightly update check compares commit SHAs, the release tag must carry the same full SHA the build script bakes into the binary.

**Tech Stack:** Rust/Cargo, Bash (`script/*`), GitHub Actions (`ubuntu-24.04`, `ubuntu-24.04-arm`), `gh` CLI, gpui.

**Design doc this implements:** `docs/plans/2026-10-01-zed-mcp-fork-ci-design.md`

---

## Global Constraints

- Repo `Michael-Obele/zed` (fork), upstream `zed-industries/zed`. `feat/mcp-mention` must never be rewritten — PR #62906 stays at 7 files, +166/−2.
- Sync = `git merge` only, never rebase or force-push. A conflict fails the run **before** any push or release.
- Linux only (x86_64 + aarch64). No `.deb`, no macOS/Windows assets.
- The updater patch applies **only** when `release_channel == Nightly` **and** `asset == "zed"`. `"zed-remote-server"` keeps coming from `cloud.zed.dev`.
- Release tag format: `v{CARGO_PKG_VERSION}+nightly.{FULL_COMMIT_SHA}`, release marked `--prerelease`.
- `crates/zed/RELEASE_CHANNEL` must read exactly `nightly`. App folder `~/.local/zed-nightly.app`, desktop id `dev.zed.Zed-Nightly`.
- Lint with `./script/clippy`, never bare `cargo clippy` (repo `AGENTS.md`).
- Every edit to an upstream-owned file is a future merge conflict: keep each one to the minimum lines.
- Local commits use imperative, capitalized, no-conventional-prefix subjects (repo `AGENTS.md` PR hygiene).

### Deviation 1 — the tag carries the FULL commit SHA, not `sha7`

The design doc (§5) specifies `v{CARGO_PKG_VERSION}+nightly.{sha7}`. That is wrong and would cause an infinite re-download loop. Evidence read 2026-10-02:

| Fact | Evidence |
|---|---|
| Build script bakes the **full** SHA | `crates/zed/build.rs:68-74` — `git rev-parse HEAD` → `cargo:rustc-env=ZED_COMMIT_SHA=…` |
| Build id comes from `GITHUB_RUN_NUMBER` | `crates/zed/build.rs:73-75` — no `ZED_BUILD_ID` input needed |
| Updater compares against `full()` | `crates/auto_update/src/auto_update.rs:755` — `.map(\|sha\| sha.full())` |
| `full()` does **not** truncate | `crates/release_channel/src/lib.rs:80-86` — only `short()` takes 7 chars |
| Comparison is `!=` on the last build segment | `crates/auto_update/src/auto_update.rs:867-876` |

A `{sha7}` tag gives `fetched_sha = "a1b2c3d"` vs `app_commit_sha = "a1b2c3d4e5…"` → "always newer" → loop. Tagging the full SHA makes both sides come from the same `git rev-parse HEAD`, with no reliance on injecting `ZED_COMMIT_SHA` (which `build.rs` reads with `option_env!` at *its own* compile time, so exporting it in CI is not dependable). Task 2 pins this with a regression test.

### Deviation 2 — the guard greps case-insensitively

The design's guard greps `crates/zed/src/zed.rs` for `unofficial`. The string we render is `Unofficial test build…`, and `grep` is case-sensitive, so the guard must use `grep -qi`. Task 3 sets the string, Task 6 sets the guard.

### Verification tiers (cost control)

- **Tier 1 — seconds, always run:** `git`, `grep`, `cat`, `bash -n`, YAML parse.
- **Tier 2 — minutes:** `cargo test -p auto_update` (compiles `auto_update` + deps only).
- **Tier 3 — expensive, ASK MICHAEL FIRST:** `script/bundle-linux`, `./script/clippy`, `cargo check -p zed`, anything >~300 MB download or >10 min. Standing rule: get explicit go-ahead. CI is the real proof for these; do not burn local bandwidth to pre-verify.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `crates/zed/RELEASE_CHANNEL` | modify | `dev` → `nightly`: enables update polling, `zed-nightly.app`, `dev.zed.Zed-Nightly` |
| `crates/auto_update/src/auto_update.rs` | modify | Read the app asset from this fork's GitHub Releases; pick the arch tarball; 4 new tests |
| `crates/zed/src/zed.rs` | modify | GPL-3.0 §5 modification notice + date in the About window and `copy_details` |
| `script/install.sh` | modify | Download from this fork's releases, Linux only, default channel `nightly` |
| `README.md` | modify | Unofficial-build banner, install one-liner, build badge |
| `.github/workflows/mcp-nightly.yml` | create | sync → guard → skip → build (×2 arches) → release → retention → failure issue |
| `script/update-patches` | modify | Export the patch backup from the latest stable tag instead of `upstream/main` |

---

## Task 1: Flip the release channel to `nightly`

**Files:**
- Modify: `crates/zed/RELEASE_CHANNEL`

**Interfaces:**
- Consumes: nothing.
- Produces: `RELEASE_CHANNEL == "nightly"`, which Task 6's guard asserts and Task 2's updater branch keys off.

- [ ] **Step 1: Confirm the current value**

```bash
cd /home/node/Documents/GitHub/zed && cat crates/zed/RELEASE_CHANNEL
```

Expected: `dev`

- [ ] **Step 2: Write the new value**

Write `nightly` as the file's entire contents, with a trailing newline and nothing else.

- [ ] **Step 3: Verify**

```bash
cat crates/zed/RELEASE_CHANNEL && ls crates/zed/resources/app-icon-nightly.png
```

Expected: `nightly`, and the icon path prints (the build script picks `app-icon{channel}.png` — `crates/zed/build.rs:231-243`).

- [ ] **Step 4: Commit**

```bash
git add crates/zed/RELEASE_CHANNEL
git commit -m "Build the fork on the nightly release channel"
```

---

## Task 2: Serve the app update from this fork's GitHub Releases

**Files:**
- Modify: `crates/auto_update/src/auto_update.rs` (add const + helper near line 48; branch in `get_release_asset` at line 670; tests at the end of `mod tests`)

**Interfaces:**
- Consumes: `RELEASE_CHANNEL == nightly` (Task 1) so the `Nightly` branch is the one that runs.
- Produces: `fn release_asset_for_arch(&GithubRelease, &str) -> Result<ReleaseAsset>` returning `version` = tag without a leading `v`, `url` = `browser_download_url`. Task 6's workflow must publish assets named `zed-linux-x86_64.tar.gz` / `zed-linux-aarch64.tar.gz` to match.

- [ ] **Step 1: Write the failing tests**

Append to the existing `mod tests` at the bottom of `crates/auto_update/src/auto_update.rs`:

```rust
    fn fake_github_release(tag: &str, asset_names: &[&str]) -> http_client::github::GithubRelease {
        http_client::github::GithubRelease {
            tag_name: tag.to_string(),
            pre_release: true,
            assets: asset_names
                .iter()
                .map(|name| http_client::github::GithubReleaseAsset {
                    name: name.to_string(),
                    browser_download_url: format!("https://example.test/{name}"),
                    digest: None,
                })
                .collect(),
            tarball_url: String::new(),
            zipball_url: String::new(),
        }
    }

    #[test]
    fn test_release_asset_for_arch_picks_the_matching_tarball() {
        let release = fake_github_release(
            "v1.22.0+nightly.0f1e2d3c4b5a69788796a5b4c3d2e1f009182736",
            &["zed-linux-aarch64.tar.gz", "zed-linux-x86_64.tar.gz"],
        );

        let asset = release_asset_for_arch(&release, "x86_64").unwrap();

        assert_eq!(
            asset.version,
            "1.22.0+nightly.0f1e2d3c4b5a69788796a5b4c3d2e1f009182736"
        );
        assert_eq!(asset.url, "https://example.test/zed-linux-x86_64.tar.gz");
    }

    #[test]
    fn test_release_asset_for_arch_errors_when_the_arch_is_missing() {
        let release = fake_github_release("v1.22.0+nightly.abc", &["zed-linux-aarch64.tar.gz"]);

        let error = release_asset_for_arch(&release, "x86_64").unwrap_err();

        assert!(
            error.to_string().contains("zed-linux-x86_64.tar.gz"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn test_release_asset_for_arch_keeps_tags_without_a_v_prefix() {
        let release = fake_github_release("1.22.0", &["zed-linux-x86_64.tar.gz"]);

        assert_eq!(
            release_asset_for_arch(&release, "x86_64").unwrap().version,
            "1.22.0"
        );
    }

    #[test]
    fn test_fork_release_tag_matches_the_baked_commit_sha() {
        let full_sha = "0f1e2d3c4b5a69788796a5b4c3d2e1f009182736";
        let tag = format!("v1.22.0+nightly.{full_sha}");
        let fetched_version = tag.strip_prefix('v').unwrap();

        let newer_version = AutoUpdater::check_if_fetched_version_is_newer(
            ReleaseChannel::Nightly,
            Ok(Some(full_sha.to_string())),
            semver::Version::new(1, 22, 0),
            fetched_version.to_string(),
            AutoUpdateStatus::Idle,
        )
        .expect("version check should succeed");

        assert_eq!(
            newer_version, None,
            "the commit that published the release must not be offered as an update"
        );
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p auto_update release_asset_for_arch` (Tier 2)

Expected: FAIL to compile — `cannot find function release_asset_for_arch in this scope`. The fourth test (`test_fork_release_tag_matches_the_baked_commit_sha`) compiles already; run it separately to prove the contract is real:

Run: `cargo test -p auto_update test_fork_release_tag_matches_the_baked_commit_sha`
Expected: PASS. Then temporarily change `full_sha` in the tag to its first 7 chars and confirm it FAILS — that is the loop being caught. Restore the full value.

- [ ] **Step 3: Add the constant and the helper**

Next to `const NIGHTLY_POLL_INTERVAL` (line 48), add:

```rust
/// The fork that publishes this build's releases.
const RELEASES_REPO: &str = "Michael-Obele/zed";
```

Immediately after the `ReleaseAsset` struct definition (line ~191), add:

```rust
/// Picks the `zed-linux-{arch}.tar.gz` asset out of a GitHub release.
fn release_asset_for_arch(
    release: &http_client::github::GithubRelease,
    arch: &str,
) -> Result<ReleaseAsset> {
    let asset_name = format!("zed-linux-{arch}.tar.gz");
    let asset = release
        .assets
        .iter()
        .find(|asset| asset.name == asset_name)
        .with_context(|| format!("release {} has no {asset_name} asset", release.tag_name))?;

    Ok(ReleaseAsset {
        version: release
            .tag_name
            .strip_prefix('v')
            .unwrap_or(&release.tag_name)
            .to_string(),
        url: asset.browser_download_url.clone(),
    })
}
```

- [ ] **Step 4: Branch `get_release_asset` to the fork's releases**

In `get_release_asset` (line 670), insert this immediately after `let client = this.read_with(cx, |this, _| this.client.clone());` so no telemetry work happens for the GitHub path:

```rust
        // This fork ships app builds from its own GitHub Releases. Remote server
        // binaries keep coming from cloud.zed.dev, so only the app asset is redirected.
        if release_channel == ReleaseChannel::Nightly && asset == "zed" {
            let release = http_client::github::latest_github_release(
                RELEASES_REPO,
                true,
                true,
                client.http_client(),
            )
            .await
            .context("fetching releases from the fork")?;

            return release_asset_for_arch(&release, arch);
        }
```

Why the two conditions: the app asset is requested as `"zed"` (`auto_update.rs:753`) and the remote server as `"zed-remote-server"` (`:612`, `:664`); the latter must not be redirected.

Why `latest_github_release(…, true, true, …)`: `crates/http_client/src/github.rs:35-86` hits the releases **list** endpoint (newest first, so `/releases/latest`'s prerelease exclusion does not apply), filters empty-asset releases, and `.find(|release| release.pre_release == pre_release)` — our releases are prereleases, so `true`. It also builds the request with `github_api_request`, which supplies the `Authorization` header from `GITHUB_TOKEN` if present and sets a timeout; unauthenticated is fine (60 req/h, polls are hours apart). GitHub's UA requirement is handled inside that helper, not by us.

- [ ] **Step 5: Point the nightly release-notes link at the fork**

In `release_notes_url` (line 340), replace the `ReleaseChannel::Nightly` arm:

```rust
        ReleaseChannel::Nightly => format!("https://github.com/{RELEASES_REPO}/releases"),
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cargo test -p auto_update` (Tier 2)

Expected: PASS, including the six pre-existing `test_nightly_*` tests and the existing `test_auto_update_downloads`, which exercises the `Stable` channel and therefore still uses the `cloud.zed.dev` path unchanged.

- [ ] **Step 7: Commit**

```bash
git add crates/auto_update/src/auto_update.rs
git commit -m "Update the fork's builds from its own GitHub releases"
```

---

## Task 3: Add the GPL §5 modification notice to the About window

**Files:**
- Modify: `crates/zed/src/zed.rs` (`AboutWindow` struct ~line 1552, `new` ~1565, `copy_details` ~1592, `render` ~1637)

**Interfaces:**
- Consumes: nothing.
- Produces: the lowercase-insensitive marker `unofficial` inside `crates/zed/src/zed.rs`, which Task 6's guard asserts; and a per-build date baked from `ZED_BUILD_DATE`, which Task 6 sets.

- [ ] **Step 1: Add the notice constants and date helper**

Directly above `struct AboutWindow`, add:

```rust
const UNOFFICIAL_NOTICE: &str =
    "Unofficial test build — not affiliated with Zed Industries. \"Zed\" is a trademark of Zed Industries, Inc.";

/// The date this binary's modifications were built, for the GPL-3.0 §5 notice.
/// CI bakes `ZED_BUILD_DATE`; the literal keeps local builds truthful.
fn modification_date() -> &'static str {
    option_env!("ZED_BUILD_DATE").unwrap_or("2026-10-02")
}
```

- [ ] **Step 2: Add the fields**

In the `AboutWindow` struct, after `full_version: SharedString,` add:

```rust
        notice: SharedString,
        modification_notice: SharedString,
```

- [ ] **Step 3: Change the headline and populate the fields**

In `AboutWindow::new`, replace the `debug`/`message` block:

```rust
            let debug = if cfg!(debug_assertions) { " (debug)" } else { "" };
            let message: SharedString =
                format!("{release_channel_name} {version}{debug} — unofficial test build").into();
            let modification_notice: SharedString = format!(
                "Modified from zed-industries/zed on {}. Source: github.com/Michael-Obele/zed",
                modification_date()
            )
            .into();
```

and in the returned struct literal, after `full_version,` add:

```rust
                notice: UNOFFICIAL_NOTICE.into(),
                modification_notice,
```

- [ ] **Step 4: Show the notice in the window**

In `render`, inside the header `v_flex()` and after the `Version` / `full_version` label pair, add:

```rust
                            .child(
                                Label::new(self.notice.clone())
                                    .color(Color::Muted)
                                    .size(LabelSize::XSmall),
                            )
                            .child(
                                Label::new(self.modification_notice.clone())
                                    .color(Color::Muted)
                                    .size(LabelSize::XSmall),
                            )
```

- [ ] **Step 5: Carry the notice into copied details**

In `copy_details`, update both arms so a pasted bug report carries the notice:

```rust
        fn copy_details(&self, window: &mut Window, cx: &mut Context<Self>) {
            let content = match self.commit.as_ref() {
                Some(commit) => format!(
                    "{}\n{}\n{}\nCommit: {}\nVersion: {}",
                    self.message, self.notice, self.modification_notice, commit, self.full_version
                ),
                None => format!(
                    "{}\n{}\n{}\nVersion: {}",
                    self.message, self.notice, self.modification_notice, self.full_version
                ),
            };
            cx.write_to_clipboard(ClipboardItem::new_string(content));
            window.remove_window();
        }
```

- [ ] **Step 6: Verify without compiling**

```bash
grep -qi unofficial crates/zed/src/zed.rs && echo "guard marker present"
grep -n "modification_date\|UNOFFICIAL_NOTICE" crates/zed/src/zed.rs
grep -n "notice:" crates/zed/src/zed.rs
```

Expected: the marker line prints, and both fields appear in the struct literal. Full type-checking is Tier 3 (`cargo check -p zed` — ask first); CI is the real gate.

- [ ] **Step 7: Commit**

```bash
git add crates/zed/src/zed.rs
git commit -m "Add the unofficial build notice to the About window"
```

---

## Task 4: Point `install.sh` at this fork

**Files:**
- Modify: `script/install.sh` (header comment ~line 4, defaults ~line 10, platform case ~line 22, `linux()` ~line 82)

**Interfaces:**
- Consumes: release assets named `zed-linux-{arch}.tar.gz` from Task 2/6; the `nightly` channel folder conventions that `script/bundle-linux` and `install_release_linux` already share.
- Produces: a one-liner install that unpacks to `~/.local/zed-nightly.app` and installs `dev.zed.Zed-Nightly.desktop`.

- [ ] **Step 1: Repoint the header comment and the default channel**

Replace the comment block at lines 4-6 with:

```sh
# Downloads this fork's Linux tarball from
# https://github.com/Michael-Obele/zed/releases and unpacks it into ~/.local/.
# This is an unofficial test build and is not affiliated with Zed Industries.
```

and change the channel default:

```sh
    channel="${ZED_CHANNEL:-nightly}"
```

- [ ] **Step 2: Refuse non-Linux platforms**

Replace the `if [ "$platform" = "Darwin" ] … else … fi` block with:

```sh
    if [ "$platform" = "Linux" ]; then
        platform="linux"
    else
        echo "This unofficial build only supports Linux (got $platform $arch)."
        echo "Download official Zed from https://zed.dev/download"
        exit 1
    fi
```

- [ ] **Step 3: Download from the fork's releases**

Replace this exact block in the `linux()` function (lines 82-87):

```sh
    else
        echo "Downloading Zed version: $ZED_VERSION"
        curl "https://cloud.zed.dev/releases/$channel/$ZED_VERSION/download?asset=zed&arch=$arch&os=linux&source=install.sh" > "$temp/zed-linux-$arch.tar.gz"
    fi
```

with:

```sh
    else
        if [ "$ZED_VERSION" != "latest" ]; then
            echo "This fork publishes only the latest release; ignoring ZED_VERSION=$ZED_VERSION" >&2
        fi
        echo "Downloading the latest unofficial Zed build for linux-$arch"
        asset_url="$(
            curl "https://api.github.com/repos/Michael-Obele/zed/releases?per_page=1" \
                | grep -o "\"browser_download_url\": \"[^\"]*zed-linux-$arch\.tar\.gz\"" \
                | head -n 1 | cut -d '"' -f 4
        )"
        if [ -z "$asset_url" ]; then
            echo "Could not find a zed-linux-$arch.tar.gz asset in the latest release" >&2
            exit 1
        fi
        curl "$asset_url" > "$temp/zed-linux-$arch.tar.gz"
    fi
```

Notes: `releases?per_page=1` is newest-first and, for an unauthenticated request, excludes drafts — so entry one is our newest prerelease. `grep -o` + `cut` avoids adding a `jq` dependency. `ZED_BUNDLE_PATH` (the local-tarball path above it) is untouched, so installing a locally built tarball still works.

- [ ] **Step 4: Verify syntax and that no Zed-cloud download remains**

```bash
bash -n script/install.sh && echo "syntax ok"
grep -n "cloud.zed.dev\|zed.dev/releases" script/install.sh || echo "no upstream download URLs left"
grep -n "ZED_BUNDLE_PATH" script/install.sh
```

Expected: `syntax ok`, no upstream URLs, and `ZED_BUNDLE_PATH` still present. (`sh -n` is not enough — the script is `#!/usr/bin/env sh` but we only changed portable constructs; if `bash -n` complains about nothing, `sh -n` will pass too.)

Also confirm the folder/desktop-id derivation still matches the other two consumers (nothing to change, just prove it):

```bash
grep -n "zed-nightly\|Zed-Nightly\|zed\$suffix.app" script/install.sh script/bundle-linux crates/auto_update/src/auto_update.rs
```

Expected: `zed$suffix.app` with `suffix="-$channel"`, `APP_ID="dev.zed.Zed-Nightly"`, and `format!("zed{}.app", suffix)` — all keyed off the same channel string.

- [ ] **Step 5: Commit**

```bash
git add script/install.sh
git commit -m "Install the fork's Linux builds from GitHub releases"
```

---

## Task 5: Add the disclaimer banner and fork metadata

**Files:**
- Modify: `README.md` (top ~18 lines)
- Change: fork settings on GitHub (issues, description, `ci-failure` label)

**Interfaces:**
- Consumes: the release tag pattern and the one-liner from Task 4.
- Produces: the `ci-failure` label that Task 7's failure job attaches.

- [ ] **Step 1: Replace the top of the README**

Replace the first block (the `> [!IMPORTANT] Remove this line to confirm you've reviewed this PR…` note) with:

```markdown
> [!WARNING]
> **This is an unofficial test build of Zed — not affiliated with, endorsed by, or
> connected to Zed Industries, Inc.** "Zed" and the Zed logo are trademarks of Zed
> Industries, Inc. It is a personal fork that adds `@mcp` context-server mentions to the
> Agent Panel ([PR #62906](https://github.com/zed-industries/zed/pull/62906)); the
> modification is also shown in the app's About window. Licensed GPL-3.0.

[![mcp-nightly](https://github.com/Michael-Obele/zed/actions/workflows/mcp-nightly.yml/badge.svg)](https://github.com/Michael-Obele/zed/actions/workflows/mcp-nightly.yml)

### Install (Linux, unofficial)

```sh
curl -f https://raw.githubusercontent.com/Michael-Obele/zed/main/script/install.sh | sh
```

Unpacks to `~/.local/zed-nightly.app` and installs `dev.zed.Zed-Nightly.desktop`, so it
never collides with an official Zed install. In-app updates are enabled and need `rsync`.
Downloads and builds come from [this repo's releases](https://github.com/Michael-Obele/zed/releases).

---

```

Leave the upstream `# Zed …` heading and everything below it untouched.

- [ ] **Step 2: Enable issues and set the description**

```bash
gh api -X PATCH repos/Michael-Obele/zed -f has_issues=true
gh repo edit Michael-Obele/zed --description "Unofficial test build of Zed with MCP context-server mentions — not affiliated with Zed Industries."
```

- [ ] **Step 3: Create the failure label (idempotent)**

```bash
gh label create ci-failure --repo Michael-Obele/zed --color B60205 \
  --description "Automated mcp-nightly failure report" 2>/dev/null || echo "label already exists"
```

- [ ] **Step 4: Verify**

```bash
gh repo view Michael-Obele/zed --json hasIssuesEnabled,description
gh label list --repo Michael-Obele/zed | grep ci-failure
head -20 README.md
```

Expected: `hasIssuesEnabled: true`, the disclaimer description, the label listed, and the banner at the top of the README.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Add the unofficial build disclaimer and install instructions"
```

---

## Task 6: Create the workflow — sync, guard, skip, build

This task creates the whole file including the build matrix, but no release publishing (that is Task 7). Its deliverable is independently useful and testable: a `workflow_dispatch` run produces both Linux tarballs as Actions artifacts.

**Files:**
- Create: `.github/workflows/mcp-nightly.yml`

**Interfaces:**
- Consumes: the five guard markers (Tasks 1-4), the tag format from Deviation 1, and the asset names from Task 2.
- Produces: job outputs `prepare.should_build`, `prepare.tag`, `prepare.sha`, `prepare.date`, consumed by Task 7's `release` job.

- [ ] **Step 1: Create the workflow file**

```yaml
name: mcp-nightly

# This fork's build pipeline. `main` is the build branch: upstream's latest stable
# tag and origin/feat/mcp-mention are merged into it, a marker guard proves the fork's
# patches survived, and then both Linux arches are built.
on:
  schedule:
    # Daily, off the hour to avoid GitHub's cron congestion.
    - cron: "10 7 * * *"
  workflow_dispatch:
    inputs:
      skip-sync:
        description: "Rebuild the current main without merging upstream or the feature branch"
        type: boolean
        default: false
      sync-ref:
        description: "Override the upstream sync target (tag or branch). Empty = latest stable release"
        type: string
        default: ""
  push:
    branches: [main]

permissions:
  contents: write
  issues: write

concurrency:
  group: mcp-nightly
  cancel-in-progress: false

env:
  CARGO_TERM_COLOR: always
  RUST_BACKTRACE: "1"
  FORK_REPO: Michael-Obele/zed
  UPSTREAM_REPO: zed-industries/zed
  # The runner's root filesystem guarantees only ~14 GB; put Cargo's output on the
  # large scratch disk instead. `script/bundle-linux:49` honours this variable.
  CARGO_TARGET_DIR: /mnt/zed-target

jobs:
  sync:
    # Never on push: CI's own push must not re-trigger the pipeline.
    if: github.event_name != 'push' && inputs.skip-sync != true
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - name: Check out the build branch
        uses: actions/checkout@v5
        with:
          ref: main
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Resolve the sync target
        id: target
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          SYNC_REF: ${{ inputs.sync-ref }}
        run: |
          set -euo pipefail
          if [ -n "$SYNC_REF" ]; then
            ref="$SYNC_REF"
          else
            # /releases/latest excludes prereleases and drafts by definition.
            ref="$(gh api "repos/$UPSTREAM_REPO/releases/latest" --jq .tag_name)"
          fi
          echo "Resolved sync target: $ref"
          echo "ref=$ref" >> "$GITHUB_OUTPUT"

      - name: Merge upstream and the feature branch into main
        env:
          SYNC_REF: ${{ steps.target.outputs.ref }}
        run: |
          set -euo pipefail
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git remote add upstream "https://github.com/$UPSTREAM_REPO.git"
          git fetch upstream --tags --force
          git fetch origin feat/mcp-mention
          # Merges only: a merge can add commits but never drop them, and a conflict
          # aborts here — before anything is pushed.
          git merge --no-edit "$SYNC_REF"
          git merge --no-edit origin/feat/mcp-mention
          git push origin main

  prepare:
    needs: [sync]
    # `always()` so a skipped sync still builds; a failed sync stops the run here.
    if: always() && needs.sync.result != 'failure'
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    outputs:
      should_build: ${{ steps.decide.outputs.should_build }}
      tag: ${{ steps.decide.outputs.tag }}
      sha: ${{ steps.decide.outputs.sha }}
      date: ${{ steps.decide.outputs.date }}
    steps:
      - name: Check out the build branch
        uses: actions/checkout@v5
        with:
          ref: main
          fetch-depth: 0

      - name: Guard the fork's patches
        run: |
          set -euo pipefail
          grep -q "MentionUri::ContextServer" crates/acp_thread/src/mention.rs
          grep -q "Michael-Obele/zed" crates/auto_update/src/auto_update.rs
          grep -q "Michael-Obele/zed" script/install.sh
          grep -qi "unofficial" crates/zed/src/zed.rs
          test "$(cat crates/zed/RELEASE_CHANNEL)" = "nightly"
          echo "All fork markers present."

      - name: Decide whether a release is due
        id: decide
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          sha="$(git rev-parse HEAD)"
          version="$(script/get-crate-version zed)"
          tag="v${version}+nightly.${sha}"
          date="$(date -u +%F)"
          echo "tag=$tag" >> "$GITHUB_OUTPUT"
          echo "sha=$sha" >> "$GITHUB_OUTPUT"
          echo "date=$date" >> "$GITHUB_OUTPUT"
          # A previously *failed* build has no release, so it retries on the next run.
          if gh release view "$tag" --repo "$FORK_REPO" >/dev/null 2>&1; then
            echo "Release $tag already exists; skipping the build."
            echo "should_build=false" >> "$GITHUB_OUTPUT"
          else
            echo "No release for $tag yet; building."
            echo "should_build=true" >> "$GITHUB_OUTPUT"
          fi

  build:
    needs: [prepare]
    if: needs.prepare.outputs.should_build == 'true'
    strategy:
      fail-fast: false
      matrix:
        include:
          - runner: ubuntu-24.04
            arch: x86_64
          - runner: ubuntu-24.04-arm
            arch: aarch64
    runs-on: ${{ matrix.runner }}
    timeout-minutes: 300
    env:
      CC: clang
      CXX: clang++
      ZED_COMMIT_SHA: ${{ needs.prepare.outputs.sha }}
      ZED_BUILD_DATE: ${{ needs.prepare.outputs.date }}
    steps:
      - name: Check out the build branch
        uses: actions/checkout@v5
        with:
          ref: main
          fetch-depth: 0

      - name: Report free space before building
        run: df -h / /mnt

      - name: Put Cargo's output on the scratch disk
        run: |
          sudo mkdir -p "$CARGO_TARGET_DIR"
          sudo chown -R "$USER" "$CARGO_TARGET_DIR"

      - name: Free space on the root filesystem
        run: |
          sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
            /usr/local/share/boost /opt/hostedtoolcache/CodeQL
          sudo docker image prune -af || true
          df -h /

      - name: Install Linux build dependencies
        run: script/linux

      - name: Download the WASI SDK
        run: script/download-wasi-sdk

      - name: Cache Rust artifacts
        uses: Swatinem/rust-cache@v2
        with:
          key: ${{ matrix.arch }}

      - name: Build the Linux bundle
        run: script/bundle-linux

      - name: Upload the tarball
        uses: actions/upload-artifact@v4
        with:
          name: zed-linux-${{ matrix.arch }}
          path: ${{ env.CARGO_TARGET_DIR }}/release/zed-linux-${{ matrix.arch }}.tar.gz
          retention-days: 7
```

Facts this relies on, all verified 2026-10-02:
- `script/linux` already installs `clang`, `lld`, `llvm`, `musl-tools`, `musl-dev`, `gettext-base`, `jq` (`script/linux:23-52`) — no extra apt step.
- `script/bundle-linux` writes `target/release/zed-linux-$(uname -m).tar.gz` with `target_dir="${CARGO_TARGET_DIR:-target}"` (`:49`, `:207-211`) → `$CARGO_TARGET_DIR/release/…`, which is why the upload path uses the env var. `uname -m` is `x86_64`/`aarch64` on those runners, matching `matrix.arch`.
- `script/bundle-linux:97-99` skips the Sentry upload when `sentry-cli` is absent, and `ZED_CLIENT_CHECKSUM_SEED` / `ZED_MINIDUMP_ENDPOINT` are optional (`crates/client/src/telemetry.rs:82-95` — `Option`, `?`-guarded) so the missing upstream secrets do not break the build.
- `crates/zed/build.rs:68-75` bakes `ZED_COMMIT_SHA` from `git rev-parse HEAD` and `ZED_BUILD_ID` from `GITHUB_RUN_NUMBER`; the exported `ZED_COMMIT_SHA` is belt-and-braces, and the tag in `prepare` is derived from the same `HEAD`, so the two always agree.
- Pushes made with `GITHUB_TOKEN` do not trigger workflows, so the `sync` job's push cannot loop.
- `rust-cache` reads `CARGO_TARGET_DIR` from the job environment, so no `workspaces:` mapping is needed; the cache key is per-arch (`key: ${{ matrix.arch }}`). If the repo's cache quota thrashes, drop `Swatinem/rust-cache` and let each run rebuild.

- [ ] **Step 2: Verify the YAML parses**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/mcp-nightly.yml')); print('yaml ok')"
grep -c "actions/checkout@v5" .github/workflows/mcp-nightly.yml
```

Expected: `yaml ok`, and `3`.

- [ ] **Step 3: Commit and push**

```bash
git add .github/workflows/mcp-nightly.yml
git commit -m "Add the mcp-nightly build pipeline"
git push origin main
```

This also pushes the two commits that were already ahead of `origin/main`.

- [ ] **Step 4: Confirm the guard actually fails when it should**

A guard that has never failed is not a guard. `workflow_dispatch` always evaluates the default branch, so the break must land on `main` — never a side branch:

```bash
printf 'dev\n' > crates/zed/RELEASE_CHANNEL
git commit -am "Temporarily break the channel guard"
git push origin main
gh workflow run mcp-nightly.yml --repo Michael-Obele/zed -f skip-sync=true
sleep 60 && gh run list --repo Michael-Obele/zed --workflow mcp-nightly.yml --limit 1
```

Expected: the newest run fails in the `prepare` job at "Guard the fork's patches" in well under a minute, **before** any compilation, and no release is created (`gh release list --repo Michael-Obele/zed` is unchanged). The failure-notification job does not exist yet; Task 7 adds it and Task 10 verifies it.

Undo with a revert commit — never a force-push:

```bash
git revert --no-edit HEAD
printf 'nightly\n' > crates/zed/RELEASE_CHANNEL
cat crates/zed/RELEASE_CHANNEL   # must read: nightly
git push origin main
```

(If `git revert` re-applies `dev` because the revert target is ambiguous, just rewrite the file to `nightly`, `git commit -am "Restore the nightly channel"`, and push.)

- [ ] **Step 5: Run the real pipeline once**

```bash
gh workflow run mcp-nightly.yml --repo Michael-Obele/zed -f skip-sync=true
gh run watch --repo Michael-Obele/zed "$(gh run list --repo Michael-Obele/zed --workflow mcp-nightly.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Expected: `sync` skipped, `prepare` passes the guard, `build` runs twice and uploads two artifacts. Confirm:

```bash
gh run view --repo Michael-Obele/zed "$(gh run list --repo Michael-Obele/zed --workflow mcp-nightly.yml --limit 1 --json databaseId --jq '.[0].databaseId')" | grep -E "zed-linux|Artifact"
```

No release exists yet — that is Task 7.

---

## Task 7: Publish the release, prune old ones, report failures

**Files:**
- Modify: `.github/workflows/mcp-nightly.yml` (append three jobs: `release`, `retention`, `notify-failure`)

**Interfaces:**
- Consumes: `prepare.outputs.tag` / `.sha` / `.date`, and the two artifacts from Task 6.
- Produces: a prerelease tagged `v{version}+nightly.{full sha}` carrying both tarballs plus `sha256sums.txt`, which Task 2's updater reads.

- [ ] **Step 1: Append the jobs**

Add to the end of the `jobs:` map:

```yaml
  release:
    needs: [prepare, build]
    # Schedule and manual runs publish; a push only produces artifacts.
    if: github.event_name != 'push'
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    steps:
      - name: Collect the tarballs
        uses: actions/download-artifact@v4
        with:
          pattern: zed-linux-*
          path: dist
          merge-multiple: true

      - name: Write checksums
        run: |
          set -euo pipefail
          cd dist
          sha256sum zed-linux-*.tar.gz > sha256sums.txt
          cat sha256sums.txt

      - name: Create the prerelease
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          TAG: ${{ needs.prepare.outputs.tag }}
          SHA: ${{ needs.prepare.outputs.sha }}
          BUILD_DATE: ${{ needs.prepare.outputs.date }}
        run: |
          set -euo pipefail
          short_sha="${SHA:0:9}"
          cat > notes.md <<EOF
          ## Unofficial test build — MCP context-server mentions

          **This is an automated test build of a personal fork. It is not an official Zed release.**

          - **Not affiliated with, endorsed by, or connected to Zed Industries, Inc.**
            "Zed" and the Zed logo are trademarks of Zed Industries, Inc.
          - Built ${BUILD_DATE} from [\`${short_sha}\`](https://github.com/$FORK_REPO/commit/${SHA})
          - Base: latest upstream stable release merged into \`main\`
          - Public repo = Corresponding Source. License: GPL-3.0 (see \`licenses.md\` in the tarball)
          - Modified from zed-industries/zed; the modification is also shown in the app's About window.

          **Install:** \`curl -f https://raw.githubusercontent.com/$FORK_REPO/main/script/install.sh | sh\`

          **In-app updates:** enabled (needs \`rsync\` on your machine).

          **What's in this build:** \`@mcp\` mention autocomplete in the Agent Panel — attach a running MCP context server to a conversation explicitly.
          EOF
          gh release create "$TAG" \
            --repo "$FORK_REPO" \
            --prerelease \
            --title "Unofficial MCP test build ${TAG}" \
            --notes-file notes.md \
            dist/zed-linux-*.tar.gz dist/sha256sums.txt

  retention:
    needs: [release]
    if: needs.release.result == 'success'
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - name: Keep only the newest ten releases
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          gh release list --repo "$FORK_REPO" --limit 100 \
            --json tagName,isPrerelease,createdAt \
            --jq '[.[] | select(.isPrerelease)] | .[10:] | .[].tagName' \
            | while read -r tag; do
                [ -n "$tag" ] || continue
                echo "Deleting $tag"
                gh release delete "$tag" --repo "$FORK_REPO" --yes --cleanup-tag
              done

  notify-failure:
    needs: [sync, prepare, build, release]
    if: failure()
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - name: Comment on or open the failure issue
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          RUN_URL: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}
        run: |
          set -euo pipefail
          existing="$(gh issue list --repo "$FORK_REPO" --state open \
            --search 'mcp-nightly failed in:title' --json number --jq '.[0].number')"
          body="$(printf 'The mcp-nightly pipeline failed on %s.\n\nRun: %s\nTrigger: %s' \
            "$(date -u +%F)" "$RUN_URL" "${{ github.event_name }}")"
          if [ -n "$existing" ]; then
            gh issue comment "$existing" --repo "$FORK_REPO" --body "$body"
          else
            gh issue create --repo "$FORK_REPO" \
              --title "mcp-nightly failed: run ${{ github.run_id }}" \
              --body "$body" \
              --label ci-failure
          fi
```

- [ ] **Step 2: Verify the YAML parses and the job graph is right**

```bash
python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/mcp-nightly.yml')); print(list(d['jobs']))"
```

Expected: `['sync', 'prepare', 'build', 'release', 'retention', 'notify-failure']`

- [ ] **Step 3: Commit and run the release path**

```bash
git add .github/workflows/mcp-nightly.yml
git commit -m "Publish and prune mcp-nightly releases"
git push origin main
gh workflow run mcp-nightly.yml --repo Michael-Obele/zed -f skip-sync=true
```

- [ ] **Step 4: Verify the release**

```bash
TAG="$(gh release list --repo Michael-Obele/zed --limit 1 --json tagName --jq '.[0].tagName')"
echo "$TAG"
gh release view "$TAG" --repo Michael-Obele/zed
gh release view "$TAG" --repo Michael-Obele/zed --json assets --jq '.assets[].name'
```

Expected: tag matches `v<version>+nightly.<40 hex chars>` (that is Deviation 1 working); assets are exactly `zed-linux-x86_64.tar.gz`, `zed-linux-aarch64.tar.gz`, `sha256sums.txt`; the body carries the disclaimer and the install one-liner.

- [ ] **Step 5: Verify the skip path**

```bash
gh workflow run mcp-nightly.yml --repo Michael-Obele/zed -f skip-sync=true
sleep 60 && gh run list --repo Michael-Obele/zed --workflow mcp-nightly.yml --limit 1
```

Expected: the newest run finishes in about a minute with the `prepare` job reporting `Release … already exists; skipping the build.` and no `build` job running.

---

## Task 8: Retire the noisy inherited workflows

Upstream's workflows are owner-gated (`if: github.repository_owner == 'zed-industries' || …`) and therefore skip on the fork — verified: `run_tests.yml`, `release.yml`, `release_nightly.yml`, `compliance_check.yml` all carry the gate. The ones that will actually fire are the cron-driven, ungated ones.

**Files:**
- Change: GitHub Actions workflow enablement on the fork (no file changes).

**Interfaces:**
- Consumes: nothing.
- Produces: a fork whose Actions page only shows `mcp-nightly` activity.

- [ ] **Step 1: List what the fork has**

```bash
gh workflow list --repo Michael-Obele/zed --all
```

- [ ] **Step 2: Disable the nine ungated cron workflows**

These have a `schedule:` trigger but no owner gate (verified 2026-10-02 by intersecting `grep -l cron` with `grep -L repository_owner`):

```bash
for wf in \
  community_pr_board_refresh community_update_all_top_ranking_issues \
  community_update_weekly_top_ranking_issues guild_stale_assignments \
  guild_weekly_shipped track_duplicate_bot_effectiveness triage_project_sync \
  triage_queue_board update_duplicate_magnets; do
  gh workflow disable "$wf.yml" --repo Michael-Obele/zed && echo "disabled $wf"
done
```

- [ ] **Step 3: Verify**

```bash
gh workflow list --repo Michael-Obele/zed
gh run list --repo Michael-Obele/zed --limit 20 --json name,status,conclusion \
  --jq '.[] | "\(.name) \(.status) \(.conclusion)"'
```

Expected: the nine show as `disabled`; the only recent runs are `mcp-nightly`. If any other workflow produces red runs, disable it by name and note it here.

---

## Task 9: Point the patch backup at the stable tag

**Files:**
- Modify: `script/update-patches`

**Interfaces:**
- Consumes: nothing.
- Produces: `patches/*.patch` containing only this fork's commits.

- [ ] **Step 1: Repoint the range**

Replace the `UPSTREAM="upstream"` line and the export line:

```bash
UPSTREAM="upstream"
PATCH_DIR="patches"
# The build branch is synced to the latest upstream *stable tag* (see
# .github/workflows/mcp-nightly.yml), so the fork's own commits are what comes
# after that tag — not everything since upstream/main, which would be 100+ upstream commits.
SYNC_BASE="$(git describe --tags --abbrev=0 "$UPSTREAM"/main 2>/dev/null || echo "$UPSTREAM/main")"
```

```bash
echo "→ Exporting commits in ${SYNC_BASE}..HEAD to $PATCH_DIR/ ..."
git format-patch -o "$PATCH_DIR" "${SYNC_BASE}..HEAD"
```

- [ ] **Step 2: Verify**

```bash
bash -n script/update-patches && echo "syntax ok"
./script/update-patches && ls -1 patches/ | head
```

Expected: `syntax ok`, and a small number of patches (the fork's commits), not hundreds.

- [ ] **Step 3: Commit**

`script/update-patches` is currently untracked. Decide once and stay consistent — either commit it (recommended, it is the recovery path for the fork's patches):

```bash
git add script/update-patches
git commit -m "Export patch backups from the upstream sync base"
```

or keep it local-only and add it to `.git/info/exclude`.

- [ ] **Step 4: Keep `script/sync-upstream` until the pipeline has proven itself**

`script/sync-upstream` (untracked) rebases and force-pushes, which fights the CI model. Keep it as a local fallback for now; delete it only after the first successful scheduled run has merged upstream, i.e. after Task 10 Step 4.

---

## Task 10: Acceptance sweep

Run this once the workflow has had a scheduled run (or a dispatch with `skip-sync` omitted, which exercises the sync path).

- [ ] **Step 1: Sync path — merges, no force-push**

```bash
git fetch origin && git log --oneline --merges -5 origin/main
git log --oneline origin/feat/mcp-mention -3
```

Expected: `origin/main` gained merge commits (not rebased history); `feat/mcp-mention` is unchanged. The `sync` job log shows `git merge --no-edit <tag>` then `git merge --no-edit origin/feat/mcp-mention`.

- [ ] **Step 1b: Seeded merge conflict — red run, no push, previous release intact**

A real upstream conflict cannot be staged on demand, so prove the mechanism with the exact command sequence the `sync` job runs. Scripts here use `set -euo pipefail`, so a conflicting merge exits non-zero and the `git push` is never reached:

```bash
git fetch upstream --tags
git checkout -b conflict-seed origin/main
# Edit a line that origin/feat/mcp-mention also changes, e.g. inside
# crates/acp_thread/src/mention.rs, to force the same hunk.
git merge --no-edit origin/feat/mcp-mention; echo "merge exit code: $?"
git merge --abort
git checkout main && git branch -D conflict-seed
```

Expected: `merge exit code: 1` with `CONFLICT (content): Merge conflict in …`, and a clean tree after `--abort`. In CI the same non-zero exit stops the job before `git push origin main`, so `main` is untouched and the last release stays published — stale but valid, never featureless. Confirm nothing removed the last release:

```bash
gh release list --repo Michael-Obele/zed --limit 3
```

- [ ] **Step 2: PR #62906 is still clean**

```bash
gh pr view 62906 --repo zed-industries/zed --json state,mergeable,mergeStateStatus
gh pr diff 62906 --repo zed-industries/zed --patch | grep -c "^diff --git"
gh pr diff 62906 --repo zed-industries/zed --patch | grep -c "^+" 
```

Expected: `OPEN` / `MERGEABLE`; 7 files. This is the check that the fork never rewrote the feature branch.

- [ ] **Step 3: Install and read the About window**

```bash
curl -f https://raw.githubusercontent.com/Michael-Obele/zed/main/script/install.sh | sh
~/.local/zed-nightly.app/libexec/zed-editor --version 2>/dev/null || echo "check About in the GUI"
```

Then open the app's **About** window and confirm it shows the unofficial notice, the modification date, and the source URL; press **Copy** and paste into a scratch file to confirm the notice travels with the details.

- [ ] **Step 4: Update path — exactly one download, no loop**

The critical check. Installed build publishes cross-arch, so use this sequence:

```bash
gh workflow run mcp-nightly.yml --repo Michael-Obele/zed   # merges upstream -> new HEAD -> new tag
# wait for it to finish, then install the *previous* build on the same machine
# (or keep the already-installed one), launch it, and open Settings -> auto update.
```

Expected: after the newer release exists, an installed older build reports one available update with version `<version>+nightly.<new sha>`, downloads it **once**, and after installing and restarting the About window shows the new SHA. Launch it again and let it poll (`NIGHTLY_POLL_INTERVAL` is 15 min, `auto_update.rs:48`) — it must **not** offer the same build again. A repeated offer means the tag's SHA and the baked SHA disagree; re-read Deviation 1.

- [ ] **Step 5: Retention**

```bash
gh release list --repo Michael-Obele/zed --limit 30
```

Expected: after roughly ten releases, the oldest are gone (deleted with `--cleanup-tag`).

- [ ] **Step 5b: Failure notifications reach an issue**

Task 6 could not check this because the notifier did not exist yet. Seed one failing run now:

```bash
printf 'dev\n' > crates/zed/RELEASE_CHANNEL
git commit -am "Temporarily break the channel guard"
git push origin main
gh workflow run mcp-nightly.yml --repo Michael-Obele/zed -f skip-sync=true
sleep 90
gh issue list --repo Michael-Obele/zed --state open --search 'mcp-nightly failed in:title'
```

Expected: an open issue labelled `ci-failure`, titled `mcp-nightly failed: run <id>`, with the run URL in the body. Run it once more before reverting: the second failure should **comment on the same issue** instead of opening a second one.

Revert and push a good build:

```bash
printf 'nightly\n' > crates/zed/RELEASE_CHANNEL
git commit -am "Restore the nightly channel"
git push origin main
gh workflow run mcp-nightly.yml --repo Michael-Obele/zed -f skip-sync=true
gh issue close "$(gh issue list --repo Michael-Obele/zed --state open --search 'mcp-nightly failed in:title' --json number --jq '.[0].number')" --comment "Guard restored; pipeline green again."
```

- [ ] **Step 6: Confirm the fork's Actions page is quiet**

```bash
gh run list --repo Michael-Obele/zed --limit 30 --json name,conclusion --jq '.[].name' | sort -u
```

Expected: only `mcp-nightly` (plus any you deliberately triggered). No scheduled failures from Task 8's list.

- [ ] **Step 7: Clean up the local leftovers**

```bash
rm -f script/sync-upstream        # superseded once a scheduled sync has succeeded
git status --short                # build-and-clean.sh should be the only untracked file left
```

---

## Notes for the implementer

- **Ask before Tier 3 work.** `script/bundle-linux`, `./script/clippy`, and `cargo check -p zed` are expensive; the standing rule is to get Michael's go-ahead. CI covers them, so prefer pushing and reading the run.
- **Never `git push --force` on `main` or `feat/mcp-mention`.** The whole sync model depends on merges only.
- **A red run is the correct outcome** for a merge conflict, a missing marker, or a build failure — it leaves the previous release in place, which is the point. Do not "fix" it by loosening the guard.
- **Third-party actions** are referenced by major tag (`actions/checkout@v5`, `actions/upload-artifact@v4`, `Swatinem/rust-cache@v2`). Upstream pins full SHAs; if you want that here, resolve the current SHA with `gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq .object.sha` and substitute. Do not invent a SHA.
- **`tooling/xtask` generates the upstream workflow files.** `mcp-nightly.yml` is hand-written and not generated, so never run `cargo xtask workflows` expecting it to be preserved.
