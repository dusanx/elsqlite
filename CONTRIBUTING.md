# Contributing to ELSQLite

Thank you for your interest in contributing to ELSQLite! This document provides guidelines and instructions for contributing.

## Philosophy

Before contributing, please understand ELSQLite's core philosophy:

**"Turtles all the way down"** - Everything is SQL. The UI generates SQL and shows it to the user. This creates a learning loop where users can see the SQL behind every action, learn patterns, and graduate to writing SQL directly.

**Bidirectional sync** - The SQL panel and results panel are always in sync. Navigate with UI → SQL updates. Edit SQL → UI updates. No separate "modes" to switch between.

## Getting Started

### Prerequisites

- Emacs 29.1 or later with SQLite support
- Git
- Make (optional, for convenience)

### Setting Up Development Environment

1. Fork and clone the repository:
```bash
git clone https://github.com/dusanx/elsqlite.git
cd elsqlite
```

2. Verify your Emacs setup:
```bash
make check-emacs
```

3. Run the test suite:
```bash
make test
```

## Development Workflow

### Running Tests

Always run tests before submitting a PR:

```bash
make test
```

Or manually:
```bash
emacs --batch -L . -L tests -l tests/elsqlite-test.el -f ert-run-tests-batch-and-exit
```

### Interactive Testing

Load the package in a running Emacs session:

```elisp
;; In *scratch* buffer
(add-to-list 'load-path (expand-file-name "~/path/to/elsqlite"))
(require 'elsqlite)
(elsqlite (expand-file-name "~/path/to/elsqlite/tests/test.db"))
```

### Writing Tests

For any new feature or bug fix, add tests to `tests/elsqlite-test.el`:

```elisp
(ert-deftest elsqlite-test-my-feature ()
  "Test description."
  (skip-unless (sqlite-available-p))
  (let ((db (sqlite-open elsqlite-test-db-path)))
    (unwind-protect
        (progn
          ;; Your test code here
          (should (equal expected actual)))
      (sqlite-close db))))
```

### Code Style

- Use `lexical-binding: t` in all files
- Follow existing indentation (2 spaces)
- Keep lines under 80 characters where reasonable
- Use descriptive variable and function names
- Add docstrings to all public functions
- Use `;;; Section` for major sections, `;;` for regular comments

Example:

```elisp
(defun elsqlite-db-get-tables (db)
  "Get list of table names from DB."
  (let ((schema (elsqlite-db-get-schema db)))
    (mapcar #'car (alist-get 'tables schema))))
```

### Commit Messages

Write clear, descriptive commit messages:

```
Short summary (50 chars or less)

More detailed explanation if needed. Wrap at 72 characters.
Explain what changed and why, not how (the diff shows how).

- Bullet points are okay
- Reference issues: Fixes #123
```

## Areas for Contribution

### Data Editing (High Priority)

Help implement editing functionality:

- [ ] Cell editing with dirty state tracking
- [ ] Row deletion with visual marking
- [ ] Row insertion
- [ ] Transaction-based save/revert (`C-x C-s` / `C-c C-k`)

### Feature Enhancements

- [ ] Enhanced column name completion
- [ ] Record detail view (single record display)
- [ ] Better NULL value handling and display
- [ ] BLOB handling improvements (hex view, external viewer)
- [ ] Horizontal scrolling for wide tables
- [ ] Interactive sorting keybinding
- [ ] Interactive filtering keybinding

### Documentation

- [ ] More usage examples in README
- [ ] Screencast or GIF demonstrations
- [ ] Emacs Wiki page
- [ ] Blog post or tutorial

### Testing

- [ ] Increase test coverage
- [ ] Test edge cases (empty tables, NULL values, BLOBs)
- [ ] Performance testing with large databases
- [ ] Test on different Emacs versions

## Pull Request Process

1. Create a feature branch:
```bash
git checkout -b feature/my-feature
```

2. Make your changes and add tests

3. Ensure all tests pass:
```bash
make check
```

4. Update documentation:
   - Add docstrings to new functions
   - Update README.md if adding user-facing features
   - Update CHANGELOG.md under [Unreleased]

5. Commit with clear messages

6. Push and create a PR:
```bash
git push origin feature/my-feature
```

7. In the PR description:
   - Describe what changed and why
   - Reference any related issues
   - Add screenshots/demos for UI changes
   - Note any breaking changes

## Architecture Overview

```
elsqlite.el         - Entry point, mode coordination, window layout
elsqlite-db.el      - Database operations, schema caching, query analysis
elsqlite-sql.el     - SQL panel mode, completion, history
elsqlite-table.el   - Results panel, table browser, navigation
```

### Key Concepts

**Buffer-local variables** link the two panels:
- `elsqlite--db` - Database handle
- `elsqlite--sql-buffer` / `elsqlite--results-buffer` - Panel references
- `elsqlite--other-panel` - Reference to paired panel

**Schema cache** (`elsqlite-db--schema-cache`):
- Built once when database opens
- Used for completion and column lookups
- Alist structure: `((tables . ...) (views . ...) (indexes . ...))`

**Query editability** (`elsqlite-db-query-is-editable-p`):
- Simple SELECT from single table → editable
- Complex queries (JOINs, aggregates, etc.) → read-only
- Used to determine mode indicator and future edit affordances

## Questions?

- Open an issue for bugs or feature requests
- Tag your issue appropriately (`bug`, `enhancement`, `question`)
- Be specific: include Emacs version, SQLite version, error messages

## Code of Conduct

Be respectful and constructive. We're all here to build something useful and learn together.

## License

By contributing, you agree that your contributions will be licensed under the GPL-3.0 license.
