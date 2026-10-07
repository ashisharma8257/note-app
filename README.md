# note-app

Minimal GoodNotes-style notebook app for iPad: folders of notebooks with blank/lined/grid/dotted pages or imported PDFs (import takes folders too, keeping their structure), Apple Pencil ink with a GoodNotes-style top bar (pen, highlighter, eraser, lasso, shapes, typed text boxes with arrows, colors, widths, undo/redo; Pencil double-tap and two/three-finger tap undo/redo), PDF export.

Folders are plain directories in the app's Documents (visible in the Files app) and can nest; an optional `.folder.json` holds the folder's color and icon. A notebook is a directory containing `meta.json` (title, paper type, page ids in order, page to reopen at, bookmarked pages, outline entries), `doc.pdf` (page backgrounds), `ink/<page id>.data` (one `PKDrawing` per page, so saving touches only the pages you edited) and `items/<page id>.json` (typed text boxes and the arrows between them). Optional files: `paper.pdf` (the paper new pages get), and two caches rebuilt after edits: `cover.jpg` (page 1 for the library) and `search.json` (each page's PDF text, typed text and handwriting read with Vision, for library search). Device backups include it; there is no sync.

## Run on your iPad

1. Install Xcode from the App Store, then `brew install xcodegen`.
2. `xcodegen` in this folder, then `open Notes.xcodeproj`.
3. Target **Notes → Signing & Capabilities**: pick your Team (a free Apple ID works).
4. Plug in the iPad, select it as the run destination, press ⌘R. On the iPad, trust the developer in Settings → General → VPN & Device Management.

With a free Apple ID the install expires after 7 days; rebuild to renew. A paid developer account extends that to a year.

## Scripts

- `scripts/ipad.sh install` builds, signs and installs on the iPad (USB or same Wi-Fi). `schedule` / `unschedule` manage a daily 21:00 reinstall that keeps the free-account install from expiring; log in `~/Library/Logs/notes-install.log`.
- `scripts/goodnotes-import.sh BACKUP_DIR [--install]` converts a GoodNotes backup (folders of `.goodnotes` files) into notebooks under `build/goodnotes-import/GoodNotes`, keeping the folder tree, and with `--install` copies it into the app on the iPad. Handwriting, highlighter, shape-tool shapes and lasso moves become editable ink; paper templates, imported PDFs and images become page backgrounds; text boxes and connectors are drawn into the page. Each notebook's page 1 is compared with GoodNotes' own thumbnail, and side-by-side images of low matches go to `build/goodnotes-import/low-match/`. The format notes are at the top of `tools/GoodNotesImport.swift`.
- `scripts/check.sh` runs `Tests/NotebookCheck.swift`, which exercises page insert/delete and ink persistence by compiling `Notes/Notebook.swift` for Mac Catalyst.
