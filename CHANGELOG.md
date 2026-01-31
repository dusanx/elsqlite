# Changelog

All notable changes to ELSQLite will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Cell editing with dirty state tracking
- Row insertion and deletion
- Transaction-based save/revert
- Enhanced column name completion
- Record detail view
- Export functionality (CSV, org-table, JSON)
- Foreign key navigation

## [0.1.0] - 2026-01-30

### Added
- Initial release
- Two-panel layout (SQL editor + results browser)
- Bidirectional sync between SQL and UI
- Schema browser with outline-based folding
- Table browser with pagination (default 50 rows per page)
- Column navigation (TAB/Shift-TAB to move between columns)
- Automatic edit vs browse mode detection
- BLOB image preview (PNG, JPEG, GIF, BMP, WEBP)
- Context-aware SQL completion
  - Table names after FROM/JOIN
  - Column names with table.column syntax
  - SQL keywords and functions
- Query history navigation (M-p/M-n)
- Smart query complexity analysis
- Query restoration after modification queries
- Comprehensive test suite with 14 passing tests

### Technical
- Requires Emacs 29.1+ with SQLite support
- Pure Elisp implementation, no external dependencies
- Uses `tabulated-list-mode` for results display
- Schema caching for fast completion
- Modeline shows edit/browse mode and pagination info

[Unreleased]: https://github.com/dusanx/elsqlite/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/dusanx/elsqlite/releases/tag/v0.1.0
