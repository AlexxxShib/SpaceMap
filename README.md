# Space Map

Space Map shows which files and folders take up the most space on your Mac. Scan a disk or folder to see its contents as a ring chart. Within each ring, wider segments represent items that use more space. Click a folder to explore it, or mark items for cleanup and review them together before moving them to the Trash.

Space Map is a native Swift app for macOS 14 or later. The interface is in Russian.

## Build and run

Install Apple's Command Line Tools with the macOS 14 SDK or later. From the repository root, run the signing setup once per Mac. It creates a local certificate and stores the key in your login keychain.

```sh
./scripts/setup-signing.sh
```

To build and launch the app, run these commands from the same directory.

```sh
./scripts/build.sh
open "build/Space Map.app"
```

The app builds for your Mac's processor architecture and has no third-party dependencies.

## macOS permissions

Each local build uses the `Space Map Local Development` signing certificate and the bundle identifier `local.spacemap.app`. This lets macOS recognize the app across rebuilds. If you switch signing identities, macOS may ask for folder access again. To use your own Apple signing certificate, set `SPACEMAP_SIGN_IDENTITY` to its name and use the same identity for subsequent builds.

When you choose a folder to scan, Space Map saves a macOS bookmark so it can reopen that folder later. You can review folder access in **System Settings → Privacy & Security → Files & Folders**.

When scanning an entire disk, permission to read other apps' protected data may last only until you quit Space Map. To grant persistent access, use Space Map's permissions menu to reveal the running copy in Finder, add that copy under **System Settings → Privacy & Security → Full Disk Access**, then relaunch it. [How macOS protects app data](https://developer.apple.com/videos/play/wwdc2023/10053/)

## Explore the map

- Click a folder in the chart or the list to make it the center of the map. Click a file to see its details in the inspector on the right.
- Use the back and forward arrows to revisit folders. Expand the small-items row to see each item in the group.
- Mark items in the inspector or from the context menu. Review the queue in the bottom panel and confirm which items to move to the Trash.

## Rescan

Space Map caches the map locally. The next time you open the app, it returns to the last folder you viewed. You can browse the saved map while sizes update in the background.

Press **⌘R** to rescan. Space Map uses the macOS change journal to revisit affected folders, retries folders it could not read, and counts hard-linked files only once. If the change history is unavailable, it scans the entire source. Press **⇧⌘R** to request a full scan at any time.

## Run the tests

```sh
./scripts/test.sh
```

The tests create a temporary file tree. Add `--live-journal` to test updates against the macOS change journal, or `--system-trash` to test moving a file created by the test suite to the system Trash.

[Technical specification (in Russian)](docs/technical-specification.md)

## License

Space Map is available under the [MIT License](LICENSE).
