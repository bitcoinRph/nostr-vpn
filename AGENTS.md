# AGENTS.md

Notes for AI coding agents working in this repo. Pair with the user's
global `~/.claude/CLAUDE.md` instructions.

## Before tagging a release

The release workflow (`.github/workflows/release.yml`) is triggered by
`v*` tag pushes and runs the same `Lint + Tests` checks as the regular
`CI` workflow as a gate before any artifacts are built. If those checks
fail, **no installers / binaries are produced** and the GitHub Release
isn't created — you have to push a fix, force-update the tag, and wait
through another full release run.

Always run the Lint + Tests gate locally first, before bumping the
version and tagging:

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

These mirror the three steps in the `Lint + Tests (push)` job in
`.github/workflows/ci.yml`. If any of them fail or warn, fix it
**before** you cut the release commit. Pushing a tag and then chasing
a fmt/clippy nit afterwards burns a full release CI cycle (~16 min on
v4.0.9) and leaves a misleading "failed" run in the actions history.

For the Linux GTK app (`linux/`, excluded from the workspace) also run:

```sh
( cd linux && cargo check )
```

## Release process

1. Update `## Unreleased` in `CHANGELOG.md` to a versioned + dated
   header like `## 4.0.10 - 2026-05-10`. The release notes generator
   (`scripts/render-release-notes.mjs` →
   `extractChangelogSection`) matches this exact pattern when looking
   up the section to put in the GitHub Release body.
2. Bump `[workspace.package].version` in the root `Cargo.toml`. This is
   the single source of truth — propagate to every other version file
   with `node scripts/sync-versions.mjs` (covers Linux Cargo.toml,
   macOS / iOS `project.yml`, Android `build.gradle.kts`, Windows
   `.csproj`). Verify with `node scripts/sync-versions.mjs --check`.
3. Run the local Lint + Tests gate (above).
4. Commit, tag (`git tag vX.Y.Z` — lightweight, pointing at the bump
   commit), and push the tag to `github` to trigger the release
   workflow. Also push `master` to both `github` and the htree `origin`.
5. Watch the run: `gh run list --workflow=release.yml --limit 3`.
