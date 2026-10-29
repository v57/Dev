# Workflows, Screenshots and the MCP server

Dev's CI and App Store screenshots live in two files at a project's root, so the app, an agent and a text editor
all edit the same thing.

## Workflows — `.dev/workflows/<id>.json`

```json
{
  "id": "release",
  "name": "Release",
  "trigger": { "tag": "v*", "branch": null, "daily": null },
  "continueOnFailure": false,
  "steps": [
    { "id": "build", "name": "Build", "kind": "release", "releaseStep": "build", "runner": "mac" },
    { "id": "test", "name": "Test", "kind": "release", "releaseStep": "test", "runner": "mac" },
    { "id": "linux", "name": "Test on Ubuntu", "kind": "command", "command": "swift build && swift test",
      "runner": "vm:Ubuntu", "parallel": true },
    { "id": "screenshots", "name": "Screenshots", "kind": "screenshots" },
    { "id": "archive", "name": "Archive · macOS", "kind": "release", "releaseStep": "archive", "platform": "macos" },
    { "id": "archive-ios", "name": "Archive · iOS", "kind": "release", "releaseStep": "archive", "platform": "ios" },
    { "id": "archive-windows", "name": "Archive · Windows", "kind": "release", "releaseStep": "archive",
      "platform": "windows", "runner": "vm:Windows" },
    { "id": "archive-linux", "name": "Archive · Linux", "kind": "release", "releaseStep": "archive",
      "platform": "linux", "runner": "vm:Ubuntu", "parallel": true },
    { "id": "direct", "name": "Sign & Notarize", "kind": "release", "releaseStep": "direct" },
    { "id": "bundle", "name": "Result Archive", "kind": "release", "releaseStep": "bundle" }
  ]
}
```

- `kind`: `release` runs one `release.sh` step (configured by the project's `release.env`), `screenshots` runs
  `release.sh screenshots` (the scenes in `.dev/screenshots.json`) and then frames them, `command` runs a shell
  command in the project folder.
- `platform` (release steps): `macos`, `ios`, `windows`, `linux` or `android`, passed as `release.sh --platform`;
  without it the step builds `release.env`'s `PLATFORM`.
- `runner`: `mac`, or `vm:<UTM machine name>` for commands and for `windows`/`linux` release steps. Dev starts the
  machine when it is stopped. A command gets the project copied into it (`VMRunner`) and runs there; a release step
  runs `release.sh --host <user>@<address>` on this Mac, which copies the project and every package it builds from
  (`V57_LOCAL=1`, the same checkouts as the Mac's `-Local` workspace) into `~/dev-release/<App>` (Linux) or
  `C:\rel\<App>` (Windows), builds there with v57/SwiftUI's `build-app` scripts and copies the package back.
- `parallel`: the step runs at the same time as the step before it.
- `trigger`: Dev checks these while it is open (every five minutes): a new commit on `branch`, a new tag matching
  `tag`, or `daily` at `HH:MM`. There is no server, so nothing runs while Dev is quit.
- The build number of every run is `git rev-list --count HEAD`, the same number `release.sh` stamps on the archive.
- Steps that publish (`direct`, `github`, `appstore`) ask before they start, unless the reader started the run and
  confirmed it, or Settings ▸ Agents allows agents to publish.
- Without the folder, a project gets two defaults from its `release.env` (Pull Request and Release); they are written
  to disk the first time any workflow is saved.

Run history is kept in `~/Library/Application Support/dev.v57.dev/Workflows/history.json` (50 runs per project, and
every older one that still has files).

### What a run makes

Every release step of a run writes to the run's own folder, `build/release/runs/<date>-<build>/` in the project
(`release.sh --output`), one subfolder per platform; each step's `::artifact KIND PLATFORM PATH` lines are the run's
files, listed under its steps and in the Workflows sidebar's Releases, where each opens, shows in Finder or goes to
the Trash (Delete Run… trashes the whole folder).

| Platform | `archive` makes | Where it builds |
|---|---|---|
| macOS | `<App>.xcarchive` (xcodebuild-release), `<App>.zip` + `<App>.dmg` (Developer ID signed; `direct` notarizes them) | this Mac |
| iOS | `<App>.xcarchive` | this Mac |
| Windows | `<App>-Windows-<arch>.zip` (`<App>\`: the WinUI host as `<App>.exe`, the app DLL, the Swift and .NET runtimes) | a Windows VM |
| Linux | `<App>-Linux-<arch>.tar.gz` (`<App>/`: the executable with the Swift runtime linked in, resources, `.desktop`) | a Linux VM |
| Android | `<App>-Android.apk`, release-signed (not built yet) | this Mac |

The names are the ones UpdateKit looks for. `bundle` (Result Archive) zips every platform's archives and packages into
`<App>-<version>-<build>.zip` with `manifest.json` (app, version, build, commit, branch, and each file's platform,
kind, size and SHA-256). Export… copies the run's zip, or, for a run without the step, makes the result as a folder
instead (`bundle --no-zip`: files hard-linked, archives cloned, so it takes a second and no space) and copies that. `googleplay` and `msstore` are
slots: they check their `release.env` keys and say what is still missing.

## Screenshots — `.dev/screenshots.json`

One file describes a project's screenshots: the scenes and how the app opens each (DevKit's format,
[screenshots.md](screenshots.md)), and the `framing` section that makes App Store pictures of them. The Screenshots
tab's Capture runs `Dev --screenshots capture --project <root>` (`dev-screenshots`), which writes
`.build/screenshots/<platform>/<locale>/<id>.png` and `manifest.json`; the tab reads the manifest, frames the pictures
of the framed platform into `.build/screenshots/framed/` and shows each scene's status (outdated by commits under
`watch`, or by edited scenes).

```json
{
  "build": { "scheme": "Dev", "project": "Dev.xcodeproj" },
  "scenes": [
    { "id": "01-localization", "arguments": ["-DevTool", "localization"], "caption": "Translate every string in one run" }
  ],
  "framing": {
    "width": 2880, "height": 1800, "background": "#1D1D1F",
    "backgrounds": { "01-localization": "#0A5FC2" },
    "caption": { "catalog": "Screenshots.xcstrings", "fontSize": 110, "color": "#FFFFFF", "bold": true,
                 "maxLines": 2, "top": 0.07 },
    "window": { "scale": 0.82, "shadow": true, "align": "bottom", "cornerRadius": 24 }
  }
}
```

- A scene's `caption` is a key of the caption catalog, in the development language. Saving adds missing keys to the
  catalog, so the Localization tool translates them with the rest of the project.
- The tab saves only `framing` and the scenes' captions, into the file as it is on disk, so the scenes and the
  capture settings are never dropped.
- Checks: the size must be an App Store Connect size; a caption that needs more than `maxLines` is reported
  (`.build/screenshots/framed/report.json`); scenes that need a new capture are listed.
- Upload… in the Screenshots tab replaces the screenshots of the app's version in Prepare for Submission with the
  framed pictures (the first appearance and device) through the App Store Connect API, with the key `release.env` names (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`).
- The key is set up as in Shell's Notarization sheet (Release Settings, or the upload sheet when there is none):
  Choose… takes the `.p8` App Store Connect downloads, reads the key ID from `AuthKey_<KEY ID>.p8` and copies the
  file to `~/.appstoreconnect/private_keys` (mode 600). Check with Apple lists the account's apps. An empty issuer
  means an individual key (the token signs as `sub: user`). Use for Notarization saves the same key as the
  `NOTARY_PROFILE` notarytool profile.

## MCP server

`Dev.app/Contents/MacOS/Dev --mcp` speaks MCP over stdin/stdout:

```bash
claude mcp add dev -- /Applications/Dev.app/Contents/MacOS/Dev --mcp
```

Tools: `list_projects`, `get_screenshot_framing`, `set_screenshot_framing`, `render_screenshots`,
`list_screenshots`, `list_workflows`, `set_workflow`, `delete_workflow`, `run_workflow`, `get_runs`.

- `set_screenshot_framing` takes `framing` (the section, replacing it) and `captions` (`{scene id: key or null}`);
  it never changes the scenes' arguments. A project without `.dev/screenshots.json` has nothing to frame.

- Files are read and written by the MCP process itself; `run_workflow` and every "Ask First" permission are asked of
  the open app over distributed notifications (`AgentBridge`), which shows the reader an alert.
- The project list comes from `~/Library/Application Support/dev.v57.dev/projects.json`, written by the app.
- Permissions (Settings ▸ Agents): read, edit, run, publish — each Allow, Ask First or Never.
