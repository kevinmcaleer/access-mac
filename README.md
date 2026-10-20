# Access for Mac

A native macOS app that opens Microsoft Access databases (`.mdb` and `.accdb`) and,
over time, aims to cover what Access does: tables, queries, forms, reports, macros and VBA.
The plan lives in the repository's issues, grouped into epics.

## What works today

- Opening `.mdb` (Access 2000-2003) and `.accdb` (Access 2007-365) files, and File > New
  for a blank Access 2016 database.
- Editing table data in Datasheet view: change a field, add a record in the last row,
  delete records with the Delete key or the ribbon, undo any of it, and save back to the
  same file. AutoNumbers, long text, OLE objects and every index are kept up to date, and
  Jackcess checks the edited files in CI.
- The navigation pane, with every table, query, form, report, macro and module, search,
  and a toggle for system objects.
- A read-only Design view listing fields and indexes.
- Every Access field type is decoded except complex (attachment / multi-value) fields,
  which show their key for now.

Not yet: Access 97 (Jet 3) files open read-only, tables with calculated fields or with
attachment / multi-value fields can't gain or lose records, and relationship rules
(referential integrity) aren't enforced when editing.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/AccessEngine` | The Jet/ACE file format engine. Pure Swift and Foundation, builds on macOS and Linux. |
| `Sources/AccessCore` | The object model the app uses: navigation pane objects, paged recordsets. |
| `Sources/AccessSQL` | Access SQL. A lexer so far; the parser and executor come with Epic 5. |
| `Sources/accessdump` | A command-line inspector: `swift run accessdump file.accdb [table]`. |
| `App/` | The SwiftUI app. `project.yml` generates the Xcode project with XcodeGen. |
| `Tests/` | Unit tests, including fixture tests that compare the engine against Jackcess. |
| `Tools/FixtureGen` | Regenerates the test databases. |

## Building

The engine and its tests need only a Swift 5.9+ toolchain:

```sh
swift test
```

The app needs macOS 14+, Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd App && xcodegen generate && open AccessMac.xcodeproj
```

Every pull request runs the engine tests on Linux and macOS and builds the app; the built
app is attached to the CI run as `AccessForMac.zip`.
