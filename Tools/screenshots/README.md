# Screenshot fixtures

`DemoApp/` is the project Dev's own screenshots (`.dev/screenshots.json`) import, so the website pictures show a
catalog with six languages and a mix of reviewed, needs-review and missing values instead of anyone's real
projects. The scenes launch Dev with `-DevScreenshotMode`, which keeps the store in memory, and pick a tool with
`-DevTool` (or `-DevSettings`), all in one launch.

Run them through the Release tool's Screenshots step, or:

    swift run dev-screenshots capture

The format is described in `docs/screenshots.md`.
