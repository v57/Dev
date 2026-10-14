# Screenshots

Every v57 app describes its screenshots in one file, `.dev/screenshots.json` at its root: the scenes, the launch
arguments that open each one, and the devices, locales and appearances to take them on. `dev-screenshots` (also
`Dev --screenshots`, and the Screenshots step of `release.sh`) takes them; the pictures land in `.build/screenshots/`
with a `manifest.json` that records the commit each picture was taken at, so Dev can tell which ones are outdated.

The package is `DevKit/` in this repo (`Package.swift` at the root):

| Library | For |
|---|---|
| `DevScreenshots` | apps: the format, and `Screenshots.prepare()` (macOS, iOS; does nothing elsewhere) |
| `DevScreenshotsCapture` | Dev and the command line: capture on this Mac and its simulators, status |
| `dev-screenshots` | the command line |

## The file

```json
{
  "build": { "scheme": "Git", "project": "Git.xcodeproj" },
  "output": ".build/screenshots",
  "locales": ["en-US", "de-DE"],
  "appearances": ["light", "dark"],
  "variables": { "DEMO": "$ROOT/Tools/screenshots" },
  "watch": ["Git", "Sources"],
  "mac": { "window": [1440, 900] },
  "ios": { "devices": ["iPhone 17 Pro Max", "iPad Pro 13-inch (M5)"] },
  "scenes": [
    { "id": "01-history", "arguments": ["--in-memory", "--add-folder", "$DEMO/Repo", "--mode", "history"],
      "caption": "Every branch at a glance" },
    { "id": "02-sidebar", "arguments": ["--hide-sidebar"], "platforms": ["ipad"], "delay": 3, "relaunch": true }
  ]
}
```

| Key | Default | |
|---|---|---|
| `build` | none | `scheme`, `project` or `workspace`, `configuration` (`Debug`), `derivedData` (`.build/xcode`). Without it, `mac.app` / `ios.app` name a built app. |
| `output` | `.build/screenshots` | relative to the root |
| `locales` | `["en-US"]` | one launch per locale (`-AppleLanguages` / `-AppleLocale`) |
| `appearances` | `["light"]` | `light`, `dark` |
| `variables` | none | `$NAME` / `${NAME}` in arguments and environment; `$ROOT` is the project root |
| `watch` | the whole repo | paths whose commits outdate the pictures |
| `mac` | `{ "window": [1440, 900] }` when there's no `ios` | `window` in points (Retina pictures are twice that), `activate` (the active-window look; brings the app forward, off by default), `app` |
| `ios` | none | `devices` (simulator names), `cleanStatusBar` (9:41, full bars, on by default), `app` |
| scene `id` | required | the file name; no spaces or slashes |
| scene `arguments`, `environment` | none | the app's own launch arguments for this screen |
| scene `platforms` | all | `mac`, `iphone`, `ipad` |
| scene `delay` | 2 | seconds to settle before the picture |
| scene `caption` | none | the caption key, for framing and the App Store |
| scene `relaunch` | false | a fresh launch even when the app takes scenes in one launch |

Pictures: `<output>/mac/<locale>/<id>.png`, `<output>/<device-slug>/<locale>/<id>.png`, and `-dark` before `.png` for
dark. A run that captures some scenes keeps the others' pictures.

## The app's side

Any app that opens its screens from launch arguments (Git's `--mode`, Database's `--select`) works without code
changes: `dev-screenshots` launches it in the background (`open -n -g`), forces the appearance through the argument
domain and takes its largest window once it has appeared and the scene's delay has passed. Each scene is a new launch.

Linking `DevScreenshots` and calling `Screenshots.prepare()` at launch adds the rest:

```swift
import DevScreenshots

Screenshots.prepare(waitsForReady: true) { scene in   // the scene handler is optional
  model.tool = scene.value("--tool")                  // open a later scene in this launch
}
// once the first scene, from the launch arguments, has loaded:
Screenshots.ready()
```

- The window gets the config's size and comes forward without taking focus; with `waitsForReady`, the picture waits
  for `ready()` instead of a fixed delay.
- With a scene handler, every scene of a locale is taken in **one launch**: after each picture the next scene arrives
  on stdin, the handler opens it, and the picture is taken once it returns and the scene's delay has passed. Undo what
  the scene before changed; mark a scene `relaunch` when that isn't possible.
- The window a scene opened (a Settings window) is the one taken; otherwise the front one.
- Without `DEV_SCREENSHOT` in the environment it does nothing, so the calls can stay in release builds.
- Debug builds share the user's bundle id and defaults: open demo data and in-memory stores from the arguments, never
  the user's own.

The exchange, for apps in other languages: the environment carries `DEV_SCREENSHOT` (the first scene's id),
`DEV_SCREENSHOT_APPEARANCE`, `DEV_SCREENSHOT_WINDOW` (`1440x900`), `DEV_SCREENSHOT_DELAY` and
`DEV_SCREENSHOT_ACTIVATE`; the app writes `dev-screenshot: hello pid=<pid> [scenes]`, `reopen`, `activate` and
`ready [window=<number>] [scene=<id>]` lines to stdout; the next scene is a JSON line on stdin,
`{"scene": {…}, "appearance": "dark"}`.

## Commands

```bash
dev-screenshots capture [--project DIR] [--scene ID] [--locale X] [--platform mac|iphone|ipad] [--device NAME] [--no-build]
dev-screenshots status [--json]      # exit 2 when a scene needs a new capture
dev-screenshots check
swift run --package-path ~/Developer/v57/Dev dev-screenshots capture --project .
```

`status` compares each scene's pictures with the project: **missing**, **incomplete** (a device, locale or appearance
has none), **changed** (its arguments, the variables or the platform settings were edited), **outdated** (commits
under `watch` since the picture's commit) or **current**. Dev's Release tool shows the same line under Screenshots.

`release.sh screenshots` runs `capture` when the project has the file (otherwise the old `SCREENSHOT_TEST` UI test),
through `$DEV_SCREENSHOTS`, Dev's own binary when Dev runs the release, `dev-screenshots` on the `PATH`, this
package, or `/Applications/Dev.app`.

`screencapture` needs Screen Recording permission for whatever runs it (the terminal, or Dev).
