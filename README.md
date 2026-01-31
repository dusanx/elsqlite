# ELSQLite - SQLite Browser for Emacs

A native Emacs SQLite browser that provides a unified interface for exploring and editing SQLite databases. Built on the philosophy that "everything is SQL"—the UI is a convenient way to build and modify queries, with bidirectional sync between SQL and visual representations.

## Features

- **Two-Panel Interface**: SQL editor panel (top) shows queries; results panel (bottom) shows data
- **Bidirectional Sync**: Navigate with UI → SQL updates; edit SQL → UI updates
- **Schema Browser**: Explore tables, views, and indexes with outline-based folding
- **Table Browser**: View and navigate table data with pagination
- **Column Navigation**: Move between columns with TAB/Shift-TAB
- **Smart Mode Detection**: Automatically detects if queries are editable or read-only
- **SQL Completion**: Context-aware completion for tables, columns, and keywords
- **Query History**: Navigate through previously executed queries with M-p/M-n
- **Query Restoration**: Automatic restore of previous SELECT after modification queries
- **BLOB Image Preview**: Automatic preview of PNG, JPEG, GIF, BMP, and WEBP images in child frame
- **BLOB Handling**: Binary data displayed as `<BLOB:N bytes>` instead of garbage

## Requirements

- Emacs 29.1 or later (with SQLite support)
- No external dependencies

To check if your Emacs has SQLite support:
```elisp
M-: (sqlite-available-p) RET
```

If this returns `t`, you're good to go!

## Installation

### From Source (Vanilla Emacs)

1. Clone this repository:
```bash
git clone https://github.com/yourusername/elsqlite.git
cd elsqlite
```

2. Add to your `init.el`:
```elisp
(add-to-list 'load-path "/path/to/elsqlite")
(require 'elsqlite)
```

### From Source (Doom Emacs)

1. Clone this repository:
```bash
git clone https://github.com/yourusername/elsqlite.git ~/.config/doom/local/elsqlite
```

2. Add to `~/.config/doom/config.el`:
```elisp
;; Load elsqlite from local directory
(add-to-load-path! "~/.config/doom/local/elsqlite")
(require 'elsqlite)

;; Optional: Auto-open .db files in ELSQLite
(elsqlite-enable-auto-open)
```

3. Restart Doom or reload config:
```bash
doom sync
# or in Emacs: SPC h r r (doom/reload)
```

### From MELPA (coming soon)

**Vanilla Emacs:**
```elisp
(use-package elsqlite
  :ensure t)
```

**Doom Emacs:**
```elisp
;; In packages.el
(package! elsqlite)

;; In config.el
(use-package! elsqlite
  :commands (elsqlite sqlite-browser))
```

## Usage

### Opening a Database

**Interactive (M-x):**
```elisp
M-x elsqlite RET /path/to/database.db RET
M-x sqlite-browser RET   ;; alias
```

**Programmatic (from Elisp):**
```elisp
(elsqlite "/path/to/database.db")
(elsqlite "~/data/customers.db")
```

**Auto-open .db files (optional):**

Vanilla Emacs - add to `init.el` (after the `require` line from installation):
```elisp
(add-to-list 'load-path "/path/to/elsqlite")
(require 'elsqlite)
(elsqlite-enable-auto-open)  ; Optional: auto-open .db files

;; To disable later: M-x elsqlite-disable-auto-open
```

Doom Emacs - already configured if you followed installation step 2 above.

Now `C-x C-f database.db` opens in ELSQLite instead of raw bytes.

**Quick keybinding for a specific database:**

Vanilla Emacs:
```elisp
(global-set-key (kbd "C-c d")
  (lambda () (interactive) (elsqlite "~/my-project.db")))
```

Doom Emacs - add to `config.el`:
```elisp
(map! :leader
      :desc "Open project database"
      "o d" (cmd! (elsqlite "~/my-project.db")))
;; Now: SPC o d opens your database
```

### Basic Navigation

**Window Management**:
- `C-x o` - Switch between SQL and results panels
- `C-x 0` - Delete current window (closes database if it's an ELSQLite window)
- Evil users: `C-w w`, `C-w h/j/k/l` work as expected

**SQL Panel**:
- `C-c C-c` - Execute query
- `M-p` / `M-n` - Navigate query history
- `TAB` - SQL completion (standard `completion-at-point`)

**Schema Browser** (results panel showing schema):
- `RET` - Open table
- `TAB` - Toggle fold/unfold CREATE statements
- `q` - Quit ELSQLite and close both panels
- `g` - Refresh schema view

**Table Browser** (results panel showing table):
- `TAB` / `Shift-TAB` - Move to next/previous column
- `^` or `Shift-U` - Return to schema browser
- `g` - Refresh current view
- `n` / `p` - Next/previous row (standard `tabulated-list-mode`)
- BLOB images automatically preview in child frame when cursor is on BLOB column

## Example Workflow

1. **Open a database**: `M-x elsqlite RET mydata.db RET`
   - You'll see the schema browser listing all tables, views, and indexes
   - SQL panel shows the query that generates this view
   - Press `TAB` on a CREATE statement to fold/unfold it

2. **Browse a table**: Move to a table and press `RET`
   - Table contents appear in the results panel
   - SQL panel updates to show `SELECT * FROM tablename LIMIT 50 OFFSET 0`
   - Mode line shows `ELSQLite[database.db] [tablename]`

3. **Navigate columns**: Use `TAB` / `Shift-TAB` to move between columns
   - If a column contains a BLOB image, it automatically previews in a child frame
   - Preview follows cursor as you navigate up/down in the same column

4. **Edit SQL directly**: Switch to SQL panel with `C-x o`
   - Modify the query to sort: `SELECT * FROM users ORDER BY age DESC`
   - Add a filter: `SELECT * FROM users WHERE age > 21`
   - Press `C-c C-c` to execute
   - Results panel updates automatically

5. **Query history**: In SQL panel, use `M-p` and `M-n`
   - Navigate through previously executed queries
   - Edit and re-execute as needed

6. **Return to schema**: From table view, press `^` or `Shift-U`
   - Returns to schema browser
   - Press `q` to quit ELSQLite

## Mode Line

The mode line shows contextual information as you navigate:

- **`ELSQLite[database.db] [Schema Viewer]`** - Viewing schema browser
- **`ELSQLite[database.db] [tablename]`** - Viewing a table
- **`ELSQLite[database.db] [Query]`** - Viewing custom query results
- **`(column TYPE = value)`** - Current field info (appears when cursor is on a cell)

Example: `ELSQLite[mydb.db] [users] (name TEXT = John Doe)`

## Architecture

```
elsqlite/
├── elsqlite.el         # Main entry point, mode coordination
├── elsqlite-db.el      # Database operations, schema caching
├── elsqlite-sql.el     # SQL panel, completion, history
├── elsqlite-table.el   # Results panel, table browser
└── tests/
    ├── elsqlite-test.el   # ERT test suite
    └── test.db            # Sample test database
```

## Development

### Running Tests

```bash
emacs --batch -L . -L tests -l tests/elsqlite-test.el -f ert-run-tests-batch-and-exit
```

Or interactively:
```elisp
M-x load-file RET tests/elsqlite-test.el RET
M-x ert RET t RET
```

### Current Implementation Status

**Implemented** ✓
- [x] Open database and browse schema
- [x] Schema browser with outline-based folding
- [x] Table browser with pagination
- [x] Column navigation (TAB/Shift-TAB)
- [x] SQL panel bidirectional sync
- [x] Execute custom queries
- [x] Query complexity detection
- [x] Context-aware SQL completion
- [x] Query history (M-p/M-n)
- [x] Query restoration after modifications
- [x] BLOB image preview (PNG, JPEG, GIF, BMP, WEBP)

**Planned**
- [ ] Cell editing with dirty tracking
- [ ] Row deletion and insertion
- [ ] Transaction-based save/revert
- [ ] Interactive sorting keybinding
- [ ] Interactive filtering keybinding
- [ ] Enhanced column name completion
- [ ] Record detail view
- [ ] Export to CSV/org-table/JSON
- [ ] Foreign key navigation

## Design Philosophy

### "Turtles All The Way Down"

Everything in ELSQLite is SQL. The UI doesn't hide SQL behind buttons and dialogs—it generates SQL and shows it to you. This creates a learning loop:

1. Navigate with arrow keys → see SQL update
2. Try sorting/filtering → see SQL change
3. Internalize patterns → start typing SQL directly
4. Graduate from UI-driven to SQL-driven workflow

This dual-input model serves both SQL novices and experts. The visible SQL panel is both a teaching tool and a power-user interface.

### Why Bidirectional Sync?

Most database tools separate browsing from querying. ELSQLite unifies them. The same view works both ways:
- **Bottom-up**: Navigate data visually, SQL appears
- **Top-down**: Write SQL, data appears

No mode switching, no context juggling—just work naturally and the tool adapts.

## Configuration

Add to your `init.el` (vanilla) or `config.el` (Doom):

```elisp
;; Customize page size (default: 50)
(setq elsqlite-default-page-size 100)

;; Customize SQL panel height in lines (default: 10)
(setq elsqlite-sql-panel-height 15)

;; Customize maximum column width (default: 100)
;; Long strings and BLOBs are truncated to this length
(setq elsqlite-max-column-width 200)
```

## Troubleshooting

### "SQLite support not available"

Your Emacs build doesn't include SQLite support. Rebuild Emacs 29+ with SQLite libraries installed, or use a pre-built version with SQLite support.

### "Database file does not exist"

The file path you provided doesn't exist. Use `C-g` to cancel and check the path. The file chooser filters for `.db`, `.sqlite`, and `.sqlite3` extensions.

### Tests failing

Make sure you're running tests from the project root:
```bash
cd /path/to/elsqlite
emacs --batch -L . -L tests -l tests/elsqlite-test.el -f ert-run-tests-batch-and-exit
```

## Contributing

Contributions welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

Quick guidelines:
1. Write tests for new features
2. Follow existing code style
3. Update README for user-facing changes
4. Keep the "everything is SQL" philosophy

## License

GPL-3.0-or-later - See [LICENSE](LICENSE) for full text.

## Author

Copyright (C) 2026 Dusan Popovic

A native Emacs SQLite browser that teaches SQL while you use it.
