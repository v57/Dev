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
    { "id": "direct", "name": "Sign & Notarize", "kind": "release", "releaseStep": "direct" }
  ]
}
```

- `kind`: `release` runs one `release.sh` step (configured by the project's `release.env`), `screenshots` runs the
  screenshot UI test and then the recipe below, `command` runs a shell command in the project folder.
- `runner`: `mac`, or `vm:<UTM machine name>` for commands. Dev starts the machine when it is stopped, copies the
  project into it (`VMRunner`) and runs the command there.
- `parallel`: the step runs at the same time as the step before it.
- `trigger`: Dev checks these while it is open (every five minutes): a new commit on `branch`, a new tag matching
  `tag`, or `daily` at `HH:MM`. There is no server, so nothing runs while Dev is quit.
- The build number of every run is `git rev-list --count HEAD`, the same number `release.sh` stamps on the archive.
- Steps that publish (`direct`, `github`, `appstore`) ask before they start, unless the reader started the run and
  confirmed it, or Settings ▸ Agents allows agents to publish.
- Without the folder, a project gets two defaults from its `release.env` (Pull Request and Release); they are written
  to disk the first time any workflow is saved.

Run history is kept in `~/Library/Application Support/dev.v57.dev/Workflows/history.json` (50 runs per project).

## Screenshots — `.dev/screenshots.json`

`release.sh screenshots` runs the project's screenshot UI test per locale and exports the attachments to
`build/release/<version>/screenshots/<locale>/`. The recipe turns them into App Store pictures in
`build/screenshots/<locale>/<scene>.png`:

```json
{
  "width": 2880, "height": 1800,
  "background": "#1D1D1F",
  "caption": { "catalog": "Screenshots.xcstrings", "fontSize": 110, "color": "#FFFFFF", "bold": true,
               "maxLines": 2, "top": 0.07 },
  "window": { "scale": 0.82, "shadow": true, "align": "bottom", "cornerRadius": 24 },
  "scenes": [
    { "match": "01-localization", "caption": "Translate every string in one run", "background": "#0A5FC2" }
  ]
}
```

- A scene's `caption` is a key of the caption catalog, in the development language. Saving a recipe adds missing
  keys to the catalog, so the Localization tool translates them with the rest of the project.
- Checks: the size must be an App Store Connect size; a caption that needs more than `maxLines` is reported
  (`build/screenshots/report.json`).
- Upload… in the Screenshots tab replaces the screenshots of the app's version in Prepare for Submission through the
  App Store Connect API, with the key `release.env` names (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`).

## MCP server

`Dev.app/Contents/MacOS/Dev --mcp` speaks MCP over stdin/stdout:

```bash
claude mcp add dev -- /Applications/Dev.app/Contents/MacOS/Dev --mcp
```

Tools: `list_projects`, `get_screenshot_recipe`, `set_screenshot_recipe`, `render_screenshots`,
`list_screenshots`, `list_workflows`, `set_workflow`, `delete_workflow`, `run_workflow`, `get_runs`.

- Files are read and written by the MCP process itself; `run_workflow` and every "Ask First" permission are asked of
  the open app over distributed notifications (`AgentBridge`), which shows the reader an alert.
- The project list comes from `~/Library/Application Support/dev.v57.dev/projects.json`, written by the app.
- Permissions (Settings ▸ Agents): read, edit, run, publish — each Allow, Ask First or Never.
