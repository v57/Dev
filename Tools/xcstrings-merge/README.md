# xcstrings-merge

> Superseded in the app: the Dev app now ships this engine in-process
> (`App/Sources/DevApp/Localization/Scan/` — ScanEngine/ScanExtractor/ScanPackageFinder/…),
> runs it from the Localization toolbar's "Scan Strings" button, previews the
> merge and writes the catalog through the app's own writer. This standalone
> executable stays as the command-line verifier (its numbers for a large app are the
> baseline the in-app engine is checked against).

Standalone SwiftPM executable that scans a repo tree for Swift packages,
extracts every localizable key from their sources using the Swift toolchain,
and merges the keys into one `.xcstrings` String Catalog — **without ever
clobbering an existing translation**.

Builds and runs on its own (`swift build` in this directory); it is not part
of the Dev app scheme.

## Usage

    swift run xcstrings-merge [--root <repo>] [--output <catalog.xcstrings>]

- `--root` — repo tree to scan (default: current directory). Every Swift
  package under it is processed: directories containing a `Package.swift`,
  including nested local sub-packages. SwiftPM/Xcode artifact directories
  (`.build`, `.git`, `.swiftpm`, `Packages`, `DerivedData`, `build`, ...)
  are never scanned.
- `--output` — catalog to merge into (default `<root>/Localizable.xcstrings`).

Example:

    swift run xcstrings-merge --root ~/Developer/MyApp \
        --output /tmp/MyApp-merged.xcstrings

## What it does per package

1. `swift package dump-package` to learn every target and its module source
   path (test/plugin/macro targets are skipped).
2. `swift build` (debug) to refresh sibling module products — failures are
   warnings; extraction continues with whatever module products exist.
3. For each remaining target, compiles its `.swift` sources once with the
   Xcode toolchain's localizable-key extraction:

       swiftc -emit-module ... -parse-as-library -module-name <Mod> <sources…>
              -emit-localized-strings -emit-localized-strings-path <out>

   The compiler writes one `.stringsdata` JSON document per source file,
   listing `(key, comment, table)` for every string literal passed to a
   localizing API: `Text("…")`, `TextField`, `LocalizedStringKey`,
   `String(localized:)`, `LocalizedStringResource`, etc. Interpolated
   strings are normalized to format specifiers (`"Count: \(n)"` → key
   `"Count: %lld"`) — the same convention Xcode's own catalogs use.

   Verified mechanism: this toolchain (Xcode 27 / Swift 6.4) exposes
   `-emit-localized-strings` / `-emit-localized-strings-path`; the newer
   `-emit-exported-strings*` flags do not exist here. SwiftPM itself passes
   `-emit-localized-strings` on macOS package builds.

4. Keys are collected per target with their comments; the `Localizable`
   table is the only one merged (custom `tableName:` tables are counted and
   skipped).

## Merge semantics

- Entries already present in the output catalog — every localization,
   state, variation, and unknown field — are **preserved**; the merge only
   reads existing entries and never rewrites them.
- Keys missing from the catalog are added as entries with an **empty
   localization** and `extractionState: "new"`. The extracted default value
   equals the key text (this mechanism's keys *are* the default strings), so
   the source-language display falls back to the key, matching the
   no-explicit-source-node convention real catalogs use.
- Multiple distinct comments for one key are joined with newlines.
- The file is rewritten (canonical sorted pretty-printed JSON, trailing
   newline) only when at least one key was added; otherwise it is left
   byte-identical. JSON round-trips losslessly through `JSONSerialization`
   (unknown top-level keys survive).

## Extraction robustness

A target's sources must typecheck to be extracted. To make that work without
a full SwiftPM build context the tool:

- adds every sibling `.swiftmodule` product directory under the package's
  `.build` as an `-I` root (foreign slices — iOS simulator, explicit
  precompiled system modules, dependency checkouts — excluded);
- passes SwiftPM-generated `<Module>.modulemap` files via
  `-Xcc -fmodule-map-file=…` so C/ObjC target imports resolve;
- injects a typecheck-only `Bundle.module` shim when a target fails solely
  because SwiftPM's synthesized resource-bundle accessor is missing;
- retries executables that fail under `-parse-as-library` in main-file
  semantics (top-level `main.swift`).

Targets that still fail (genuine source errors, missing CocoaPods
frameworks, stale dependency products) are reported per-module on stderr
with the first specific compiler error, and any keys extracted from the
files that did compile are still counted.

## Output

Per-target and per-package unique-key counts and a grand total go to stdout,
then the merge result:

    Merged catalog written: /tmp/MyApp-merged.xcstrings
      existing entries preserved: 1382
      entries added (empty localization, state "new"): 32
      total entries: 1414

## Layout

- `main.swift` — argument parsing + orchestration
- `PackageFinder.swift` — recursive package-root discovery
- `Manifest.swift` — `dump-package` decoding
- `Extractor.swift` — build refresh, module search paths, per-target
  compilation, `.stringsdata` parsing
- `StringsData.swift` — `.stringsdata` JSON model
- `CatalogMerge.swift` — catalog load / merge / canonical write
- `Shell.swift` — subprocess runner with capture + timeout
