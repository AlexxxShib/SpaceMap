# Space Map

Space Map is a native app for macOS 14 or later. Scan a disk or folder to see disk usage as a ring chart, then select items to move to the system Trash.

## Build and run

Install Apple's Command Line Tools with the macOS 14 SDK or later. Run these commands from the repository root.

```sh
./scripts/build.sh
open "build/Space Map.app"
```

The app builds for your Mac's processor architecture and has no third-party dependencies.

## Explore the map

Click a segment to see its details on the right. Double-click a folder to make it the center of the map. Expand the small-items row to see the full list. Mark items in the inspector or from the context menu, then review the queue in the bottom panel and confirm the move to the Trash.

## Run the tests

```sh
./scripts/test.sh
```

The tests create a temporary file tree. Add `--system-trash` to test moving one file created by the test suite to the system Trash.

[Technical specification (in Russian)](docs/technical-specification.md)
