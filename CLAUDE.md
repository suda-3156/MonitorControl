# CLAUDE.md

## What this repository is

A personal fork of [MonitorControl](https://github.com/MonitorControl/MonitorControl),
a macOS menu bar app that controls external monitors over DDC/CI.

The fork exists to add live DDC value sync: the sliders should reflect the
panel's real state, not the last value the app wrote. Stock MonitorControl reads
the panel only at startup, so adjusting the monitor with its own buttons leaves
the sliders stale.

Because this is a fork that tracks upstream releases, **keep the diff against
upstream small and localized**. Prefer adding a new method next to the existing
ones over rewriting existing code, and do not reformat or refactor code that the
change does not touch.

## Build

Use `task` (see `Taskfile.yml`). `task --list` shows the available tasks.

Machine-local configuration lives in `.env.local`, which `Taskfile.yml` loads
via `dotenv` and direnv loads via `.envrc`. It is git-ignored; `.env.example` is
the tracked template and must stay free of machine-specific values. A missing
`.env.local` is not an error, the build falls back to ad-hoc signing.

Build output goes to Xcode's own DerivedData directory: the tasks deliberately
do not pass `-derivedDataPath`, so `xcodebuild` and Xcode.app share one build
directory and nothing lands in the working tree. This is not just tidiness.
Upstream's "Increase Build Number" phase bumps `CFBundleVersion` in both
`Info.plist` files whenever `find` reports a file newer than `Info.plist`
anywhere under `PROJECT_DIR`, and it is not gated on dependency analysis, so
build products inside the project directory make even a no-op build produce a
version diff. With the default location the bump happens once per editing
session, which is what upstream intends; commit that diff or discard it, but do
not try to suppress it.

The product path is not predictable (DerivedData names carry a hash), so the
build tasks ask `xcodebuild -showBuildSettings` for `BUILT_PRODUCTS_DIR` and
print the resulting path when they finish.

## Code signing

Signing is overridden on the `xcodebuild` command line, never in
`project.pbxproj`: upstream ships `DEVELOPMENT_TEAM = 299YSU96J7`, and editing
that file adds fork drift to something that conflicts badly on merge. The
override comes from `.env.local` (`MC_CODE_SIGN_IDENTITY`,
`MC_DEVELOPMENT_TEAM`); `task signing` prints what is in effect.

The app is only ever run locally, so Gatekeeper and notarization do not apply:
a locally built bundle carries no `com.apple.quarantine` attribute. What does
apply is TCC. Accessibility permission is required for the media key tap, and
TCC stores the permission against the app's designated requirement:

- Ad-hoc (`CODE_SIGN_IDENTITY=-`) produces `designated => cdhash H"..."`, the
  hash of that exact build. Every rebuild is a different app to macOS:
  Accessibility has to be granted again and a dead entry is left behind in
  System Settings.
- A certificate produces `designated => identifier "..." and anchor apple
  generic and certificate leaf[subject.CN] = "..."`, which does not depend on
  the build's contents. Grant Accessibility once and rebuilds keep it.

So prefer a real certificate for anything that gets used, and keep ad-hoc for
throwaway checks. No provisioning profile is needed: the build passes an empty
`PROVISIONING_PROFILE_SPECIFIER`. `SMLoginItemSetEnabled` (the "start at login"
helper in `Contents/Library/LoginItems`) also expects the helper and the main
app to carry the same signature, which ad-hoc signing cannot express.

Changing the identity changes the designated requirement, so the first launch
after a switch needs Accessibility granted again and the stale entry removed.

## Code style

Follow the surrounding code. The repository config is authoritative:

- `.swiftformat`: 2-space indent, `--nospaceoperators`, **`--self insert`**
  (explicit `self.` on every member access), lowercase exponents.
- `.swiftlint.yml`: `line_length`, `identifier_name` and a few other rules are
  disabled; do not add line breaks or rename things to satisfy rules that this
  project turns off.
- SwiftLint is not installed, so its build phase only emits a warning.

Formatting is SwiftFormat's job, not something to match by eye. Upstream ran
nicklockwood/SwiftFormat over the whole repository in v4.4.0, so the committed
tree is the tool's own output. Run `task format -- <paths>` over the files a
change touches before committing. Two rules account for nearly everything the
tool wants in this codebase: `docComments` turns a comment attached to a single
declaration into `///` (a comment heading a group of declarations stays `//`),
and `wrapPropertyBodies` puts a one-line accessor body on its own line.

`mise.toml` pins the version, which is the piece upstream lacks. 0.63.0 was
checked against upstream's tree and reformats nothing there, so the pin is what
keeps a `task format` run from touching code the change did not. Bump it
deliberately, and check `git status` after the first build on the new version.

The `[Format] Run SwiftFormat` build phase is not gated on dependency analysis
and runs

```sh
export PATH="$PATH:/opt/homebrew/bin"
if which swiftformat >/dev/null; then swiftformat . ; fi
```

from the project directory on **every** build, so whether a build reformats the
whole tree depends on where `swiftformat` sits:

- `task build` from a shell with mise's shims on `PATH` finds it, and the phase
  rewrites the tree. Harmless while the tree is a fixpoint, which it is.
- Xcode.app launched from the Finder does not: GUI apps inherit launchd's `PATH`
  (`launchctl getenv PATH` is unset here, so `/usr/bin:/bin:/usr/sbin:/sbin`),
  and mise's shims are in `~/.local/share/mise/shims`, not `/opt/homebrew/bin`.
  The phase only emits a warning. Nothing in the app fails when it does.

So a build from Xcode will not catch unformatted code. `task build` or
`task format` will.

`.swiftformat` also excludes `.build` defensively, so that a stray whole-tree run
cannot rewrite SPM checkouts should anything ever put them there.

Guard-heavy, early-return style with `os_log(_:type:)` tracing is the house
idiom in the DDC code. Match it.

## Language

- Swift code, comments, commit messages and documentation: English.
- User-facing strings: `NSLocalizedString("...", comment: "...")` with the
  English text as the key. `MonitorControl/UI/*.lproj/Localizable.strings` holds
  the translations; BartyCrouch manages them, and its build phase is disabled.

## DDC constraints

These are protocol-level facts, not implementation details to optimize away:

- A single DDC read costs ~70 ms (2 write cycles at 10 ms plus a 50 ms read
  wait). The DDC/CI (MCCS) spec requires at least 40 ms after a Get VCP Feature
  request before reading the reply, so the wait cannot be shortened; shortening
  it only buys retries. Brightness + contrast is ~140 ms at best.
- **Never run a DDC read on the main thread.** `OtherDisplay.readDDCValues`
  does `DisplayManager.shared.globalDDCQueue.sync` internally, so callers must
  be off the main thread and must not already be on `globalDDCQueue`.
- Read only what is displayed, and cache. That is the whole available strategy.
- `pollingCount == 0` (Settings -> Displays -> DDC polling mode: None) is the
  project's existing "no DDC reads" switch. Gate new reads on it instead of
  adding a new preference.
- **Never run `m1ddc` while MonitorControl is running.** Two processes on the
  same I2C bus corrupt each other's reads. Quit the app first.
