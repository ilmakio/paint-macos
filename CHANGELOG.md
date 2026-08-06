# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] — 2026-08-06

### Changed

- New app icon, authored in Icon Composer, so it picks up the system's
  material and lighting treatments instead of shipping a flat raster.

### Removed

- The old `AppIcon.appiconset` and its ten hand-rendered PNGs, now that the
  `.icon` bundle supersedes them.

## [1.0.0] — 2026-08-02

First public release.

### Added

- All sixteen tools from the classic toolbox: free-form and rectangular select,
  eraser and colour eraser, bucket, eyedropper, magnifier, pencil, brush,
  airbrush, text, line, curve, rectangle, polygon, ellipse and rounded
  rectangle.
- 28-colour palette with editable swatches, plus foreground and background
  colours bound to the left and right mouse buttons.
- Brush sizes 1–64 with round, square and calligraphic nibs; outline, filled
  and outline-plus-fill styles for every shape; adjustable bucket tolerance.
- Floating selections: move, stretch by handle, Option-drag to duplicate,
  arrow-key nudge, transparent background mode, crop to selection.
- Canvas resizing by dragging the edge grips or through Image ▸ Attributes;
  flip, rotate, stretch and skew, invert colours, clear image.
- Zoom from 25% to 3200% with a pixel grid at 4× and above, pinch to zoom, and
  space-drag panning.
- Open and save PNG, JPEG, TIFF, BMP and GIF via `NSDocument`, with Open
  Recent, Revert, printing and unsaved-changes handling.
- Undo and redo across the whole editing surface, with a stroke or a complete
  selection move collapsing into a single step.
- 75 tests covering the raster core, the document layer and every tool.

[1.0.1]: https://github.com/ilmakio/paint-macos/releases/tag/v1.0.1
[1.0.0]: https://github.com/ilmakio/paint-macos/releases/tag/v1.0.0
