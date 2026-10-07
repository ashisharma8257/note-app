# note-app

Minimal GoodNotes-style notebook app for iPad: folders of notebooks with blank/lined/grid pages or imported PDFs, Apple Pencil ink (PencilKit tool picker: pen, highlighter, eraser, lasso, colors, undo), PDF export.

Folders are plain directories in the app's Documents (visible in the Files app) and can nest. A notebook is a directory containing `meta.json` (title, paper type, page ids in order), `doc.pdf` (page backgrounds) and `ink/<page id>.data` (one `PKDrawing` per page, so saving touches only the pages you edited). Device backups include it; there is no sync.

## Run on your iPad

1. Install Xcode from the App Store, then `brew install xcodegen`.
2. `xcodegen` in this folder, then `open Notes.xcodeproj`.
3. Target **Notes → Signing & Capabilities**: pick your Team (a free Apple ID works).
4. Plug in the iPad, select it as the run destination, press ⌘R. On the iPad, trust the developer in Settings → General → VPN & Device Management.

With a free Apple ID the install expires after 7 days; rebuild to renew. A paid developer account extends that to a year.

## Scripts

- `scripts/ipad.sh install` builds, signs and installs on the iPad (USB or same Wi-Fi). `schedule` / `unschedule` manage a daily 21:00 reinstall that keeps the free-account install from expiring; log in `~/Library/Logs/notes-install.log`.
- `scripts/check.sh` runs `Tests/NotebookCheck.swift`, which exercises page insert/delete and ink persistence by compiling `Notes/Notebook.swift` for Mac Catalyst.
