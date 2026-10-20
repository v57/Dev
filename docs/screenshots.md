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
  "framing": { "width": 2880, "height": 1800, "backgrounds": { "01-history": "#0A5FC2" } },
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
| `mac` | `{ "window": [1440, 900] }` when there's no `ios` | `window` in points (Retina pictures are twice that), `activate` (off by default: the app stays in the background, and ComponentKit apps still draw the focused look through `-KitAppearsActive YES`; `true` brings it forward once and every picture waits until it is focused), `app` |
| `ios` | none | `devices` (simulator names), `cleanStatusBar` (9:41, full bars, on by default), `app` |
| `framing` | none | how Dev's Screenshots tool frames the pictures for the App Store: see below |
| scene `id` | required | the file name; no spaces or slashes |
| scene `arguments`, `environment` | none | the app's own launch arguments for this screen |
| scene `platforms` | all | `mac`, `iphone`, `ipad` |
| scene `delay` | 1 | seconds to settle before the picture; an app with the kit waits for its scene to load first, so it rarely needs more |
| scene `caption` | none | the caption key in the development language, for `framing` and the App Store |
| scene `relaunch` | false | a fresh launch even when the app takes scenes in one launch |

Pictures: `<output>/mac/<locale>/<id>.png`, `<output>/<device-slug>/<locale>/<id>.png`, and `-dark` before `.png` for
dark. A run that captures some scenes keeps the others' pictures.

Saving the file from Dev (or `ScreenshotConfig.save`) writes only what differs from the defaults, keys in the order
above and arrays or objects on one line when they fit in 120 columns, so a hand-written file changes only where edited.

## Framing

`framing` turns the captures into App Store pictures: the capture scaled with rounded corners and a shadow on a
background, under the scene's `caption` translated through a String Catalog, at one App Store size. Dev's Screenshots
tool edits it (and its agents, over MCP); captures don't depend on it, and neither does a scene's status, so editing a
caption or the framing never outdates a picture. Framed pictures go to `<output>/framed/`, at the capture's own path,
with `report.json` (captions that don't fit).

```json
"framing": {
  "platform": "mac",
  "width": 2880, "height": 1800,
  "background": "#1D1D1F",
  "backgrounds": { "01-history": "#0A5FC2" },
  "caption": { "catalog": "Screenshots.xcstrings", "fontSize": 110, "color": "#FFFFFF", "bold": true,
               "maxLines": 2, "top": 0.07 },
  "window": { "scale": 0.82, "shadow": true, "align": "bottom", "cornerRadius": 24 },
  "updatedBy": "Claude through MCP", "updatedAt": "2026-10-14T20:00:00Z"
}
```

| Key | Default | |
|---|---|---|
| `platform` | the Mac when `mac` is set, else the first device's | the platform whose pictures are framed: one size fits one platform |
| `width`, `height` | 2880 × 1800 (1320 × 2868 iPhone, 2064 × 2752 iPad) | pixels; must be an App Store Connect size |
| `background` | `#1D1D1F` | `#RRGGBB` |
| `backgrounds` | none | per scene `id`, its background |
| `caption` | as above | `catalog` (relative to the root; the scenes' captions are its keys, added when Dev saves), `fontSize` (points at the framed size), `color`, `bold`, `maxLines` (more is reported), `top` (space above, a fraction of the height) |
| `window` | as above | `scale` (the capture's width as a fraction of the picture's), `shadow`, `align` (`bottom` runs off the edge, `center` floats), `cornerRadius` |
| `updatedBy`, `updatedAt` | none | who saved the framing last; Dev writes them |

Every key is optional and a value that doesn't read takes its default; a `framing` that isn't an object is ignored, so
it never stops a capture. Without the section, Dev frames with the defaults for the platform and writes nothing until
the reader saves.

## The app's side

Any app that opens its screens from launch arguments (Git's `--mode`, Database's `--select`) works without code
changes: `dev-screenshots` launches it in the background (`open -n -g`), forces the appearance through the argument
domain and takes its largest window once it has appeared and the scene's delay has passed, in the background (or after bringing
the app forward with `mac.activate`). Every launch gets `-KitAppearsActive YES`, so an app on ComponentKit draws the
focused look though it isn't focused; only the window's buttons look inactive. Each scene is a new launch. Only apps
with the kit say when they lose focus, so only they pause (with `mac.activate`).

Linking `DevScreenshots` and calling `Screenshots.prepare()` at launch adds the rest:

```swift
import DevScreenshots

Screenshots.prepare(waitsForReady: true) { scene in   // the scene handler is optional
  model.tool = scene.value("--tool")                  // open a later scene in this launch
}
// once the first scene, from the launch arguments, has loaded:
Screenshots.ready()
```

- The window gets the config's size and stays in the background. With `"activate": true` it comes forward with
  focus: the app asks to be activated once, and every picture waits until it is the active app. Switching to another
  app pauses the capture (the timeout stops too) until you come back with ⌘-Tab or the Dock; a picture taken while
  focus left is taken again. With `waitsForReady`, the picture waits for `ready()` instead of a
  fixed delay.
- With a scene handler, every scene of a locale is taken in **one launch**: after each picture the next scene arrives
  on stdin (in a simulator, whose apps get `/dev/null` as stdin, on a FIFO), the handler opens it, and the picture is taken once it returns and the scene's delay has passed. Undo what
  the scene before changed; mark a scene `relaunch` when that isn't possible.
- The window a scene opened (a Settings window) is the one taken; otherwise the front one.
- Without `DEV_SCREENSHOT` in the environment it does nothing, so the calls can stay in release builds.
- Debug builds share the user's bundle id and defaults: open demo data and in-memory stores from the arguments, never
  the user's own.

The exchange, for apps in other languages: the environment carries `DEV_SCREENSHOT` (the first scene's id),
`DEV_SCREENSHOT_APPEARANCE`, `DEV_SCREENSHOT_WINDOW` (`1440x900`), `DEV_SCREENSHOT_DELAY` and
`DEV_SCREENSHOT_ACTIVATE`, and in a simulator `DEV_SCREENSHOT_INPUT` (a FIFO to read the next scenes from instead of
stdin); the app writes `dev-screenshot: hello pid=<pid> [scenes]`, `reopen`, `activate`,
`focus active|inactive` and `ready [window=<number>] [scene=<id>]` lines to stdout; the next scene is a JSON line on stdin,
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
under `watch` since the picture's commit) or **current**. Dev's Screenshots tab and the project's Overview show the
same status. A scene's `caption` and `relaunch` and the `framing` don't enter it.

`release.sh screenshots` runs `capture` when the project has the file (otherwise the old `SCREENSHOT_TEST` UI test),
through `$DEV_SCREENSHOTS`, Dev's own binary when Dev runs the release, `dev-screenshots` on the `PATH`, this
package, or `/Applications/Dev.app`.

`screencapture` needs Screen Recording permission for whatever runs it (the terminal, or Dev).
