# Workflows, Screenshots, Store Text and the MCP server

Dev's CI, App Store screenshots and store text live in files at a project's root, so the app, an agent and a text
editor all edit the same thing.

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

## Store Text — `.dev/store/`

Everything a store or release page says, written once and reused. It works with no network and no accounts; the tool
is the project's Store Text tab. One text file per text, so a diff shows the sentence that changed:

```
.dev/store/
  store.json                       baseLocale, locales, destinations, bundleID
  .gitignore                       /private/
  en-US/name.txt                   the base text
  en-US/description.txt
  en-US/description.appstore.txt   the override for one destination (appstore, github, googleplay, msstore)
  en-US/keywords.txt               one per line
  en-US/versions/1.2.0/changelog.txt
  en-US/versions/1.2.0/changelog.github.txt
  de-DE/description.txt            the text in another locale
  translations.json                what each translation was made from (hashes)
  private/...                      the same layout, never committed
```

Fields (the file names): `name`, `subtitle`, `description`, `keywords`, `promotional-text`, `url-support`,
`url-marketing`, `url-privacy`, `category`, `copyright`, `review-notes`, and per version `changelog` and `testers`.

What a destination shows, most specific first: this locale's override, this locale's text, the base language's
override, the base text. Each field's length is counted live against each destination's limit, in the units that
destination counts (App Store keywords are bytes, commas included; GitHub topics and Microsoft search terms are items).
A limit a service doesn't document is an estimate: going over warns but doesn't stop a publish.

**Private until ready.** These repositories are public, so new text is a draft in `private/`, which `.dev/store/.gitignore`
keeps out of git. Ready (the chip above the editor, or `ready: true` over MCP) moves a field, in every locale, into the
repository; publishing or importing does the same, since that text is public anyway. Review notes and messages to
testers never leave `private/`. A file in `private/` wins over the same path outside it. The tool warns when git already
tracks a file in there. Private files exist only on this Mac: nothing syncs or backs them up. Credentials never go in any
of it: release.env names key files (`ASC_KEY_PATH`, `GOOGLE_PLAY_KEY_PATH`), the keychain holds the Microsoft client
secret, and the GitHub sign-in is the app's. Demo passwords for reviewers go in App Store Connect's review fields.

**Translate** fills the other locales with the model in Settings, only when pressed. It fills what's missing or
outdated (the source changed since) and never touches text written by hand: editing a translation makes it yours.

**Import** reads a service once and lists what it would write; nothing changes until you press Import. A field that's
empty here becomes the base text, and text that differs becomes that destination's override, so the base text and the
other destinations keep theirs. **Publish** reads what's live, lists each difference, and sends only after a confirmation.
A field empty here is left alone there, English never goes into a listing that lacks its translation, and a documented
limit stops it. What each sends:

| Service | Reads and writes | Needs | Publish stops at |
|---|---|---|---|
| App Store Connect | name, subtitle, privacy URL; description, keywords, promotional text, What's New, support and marketing URLs; category, copyright, review notes; TestFlight's What to Test | API key in release.env, bundle ID | the text: nothing is submitted for review |
| GitHub | repository description, homepage, topics; a release's notes (drafts included) | `GITHUB_REPO`, the GitHub sign-in | the text; the release itself comes from `release.sh github` |
| Google Play | title, short and full description, website; release notes on the production track, tester notes on `GOOGLE_PLAY_TRACK` | `GOOGLE_PLAY_KEY_PATH` (needs `openssl` to sign), `GOOGLE_PLAY_PACKAGE` or the bundle ID | a committed edit, which refuses while a review is pending |
| Microsoft Store | product name, short description, description, search terms, copyright, What's New, certification notes | `MS_STORE_APP_ID`, `MS_STORE_TENANT_ID`, `MS_STORE_CLIENT_ID`, the client secret | a saved draft submission: you commit it in Partner Center |

Fields a service's API can't set (Play's privacy policy and category, Microsoft's URLs and category) are counted and
offered to copy. A live App Store version only takes its promotional text.

**Release steps.** `release.sh github` takes its notes from the version's `changelog.github.txt`, else `changelog.txt`
(drafts first), else GitHub's generated notes. `release.sh --version X bump` (a step of its own, never part of `all`) sets
`MARKETING_VERSION` in the Xcode project and, when the version has no changelog, drafts one from the commits since the
last tag. New Version… in the tab starts from the same draft to edit there. Windows, Linux and Android builds take the
version from `--version` on each run, so bump has nothing else to change for them.

## MCP server

`Dev.app/Contents/MacOS/Dev --mcp` speaks MCP over stdin/stdout:

```bash
claude mcp add dev -- /Applications/Dev.app/Contents/MacOS/Dev --mcp
```

Tools: `list_projects`, `get_screenshot_framing`, `set_screenshot_framing`, `render_screenshots`,
`list_screenshots`, `list_workflows`, `set_workflow`, `delete_workflow`, `run_workflow`, `get_runs`, `get_store_text`,
`set_store_text`, `set_store_settings`, `draft_store_changelog`.

- `set_screenshot_framing` takes `framing` (the section, replacing it) and `captions` (`{scene id: key or null}`);
  it never changes the scenes' arguments. A project without `.dev/screenshots.json` has nothing to frame.

- `get_store_text` answers every field per destination and locale, with where it came from and its length against the
  limit. `set_store_text` writes one text (`field`, `text`, optional `destination`, `locale`, `version`, `ready`) and
  answers the same counts. Import, Publish and Translate stay the reader's, in the app: agents reach no store.

- Files are read and written by the MCP process itself; `run_workflow` and every "Ask First" permission are asked of
  the open app over distributed notifications (`AgentBridge`), which shows the reader an alert.
- The project list comes from `~/Library/Application Support/dev.v57.dev/projects.json`, written by the app.
- Permissions (Settings ▸ Agents): read, edit, run, publish — each Allow, Ask First or Never.
