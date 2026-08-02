# Contributing

Thanks for taking a look. Issues and pull requests are both welcome.

## Getting set up

```bash
brew install xcodegen
git clone https://github.com/ilmakio/paint-macos.git
cd paint-macos
xcodegen generate
open Paint.xcodeproj
```

`Paint.xcodeproj` is generated from `project.yml`. If you need a new file,
target or build setting, change the YAML and re-run `xcodegen generate` — hand
edits to the project file get overwritten.

## Running the tests

```bash
xcodebuild -project Paint.xcodeproj -scheme Paint test
```

All 75 should pass before and after your change. CI runs the same command.

## House rules

**Keep the raster core free of AppKit.** Everything under `Paint/Models` that
deals with pixels — `PixelBuffer`, `Raster`, `FloodFill`, `Brush`, `Painter` —
should only need Foundation and CoreGraphics. That is what lets the tests drive
it with no window on screen.

**Tools talk to `ToolHost`, not to views.** A tool that reaches for
`CanvasView` directly cannot be tested. Add to the protocol instead.

**Anything that touches pixels needs a test.** Not a screenshot comparison — a
statement about the pixels. "The bucket cannot escape this outline", "one drag
is one undo", "flipping twice is the identity". Those catch the bugs that
matter here.

**Match the surrounding style.** Four-space indent, no force-unwraps outside
tests, comments that explain *why* rather than restate the code.

## Reporting a bug

Please include your macOS version, what you did, what you expected, and what
happened instead. For anything visual, a screenshot at high zoom with the pixel
grid on (`⇧⌘G`) is worth a lot — most drawing bugs are one pixel wide.

## Scope

Paint deliberately stops where the original stopped: one raster layer, no
filters, no vector objects, no cloud anything. Features that fit the classic
toolbox are in scope; a layers panel is not. If you are unsure, open an issue
before writing the code.
