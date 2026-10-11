# Screenshot fixtures

`DemoApp/` is the project the screenshot UI tests (`DevUITests/ScreenshotTests.swift`) import, so the
website pictures show a catalog with six languages and a mix of reviewed, needs-review and missing
values instead of anyone's real projects. The tests launch Dev with `-DevScreenshotMode`, which keeps
the store in memory.

Run them through the Release tool's Screenshots step, or:

    Tools/release/release.sh screenshots
