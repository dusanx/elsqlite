;;; quickstart.el --- ELSQLite Quick Start Example -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dusan Popovic

;;; Commentary:

;; This file demonstrates basic usage of ELSQLite.

;;; Usage:
;;
;; 1. Load this file in Emacs:
;;    M-x load-file RET examples/quickstart.el RET
;;
;; 2. Evaluate the examples below by placing cursor after each form
;;    and pressing C-x C-e
;;
;; 3. Or evaluate the entire buffer:
;;    M-x eval-buffer RET

;;; Code:

;; First, make sure ELSQLite is loaded
(add-to-list 'load-path (expand-file-name ".."))
(require 'elsqlite)

;; Optional: Set up Evil mode keybindings (if you use Evil)
;; (elsqlite-evil-setup)

;; Example 1: Check if SQLite is available
(message "SQLite available: %s" (sqlite-available-p))
;; => SQLite available: t

;; Example 2: Open the test database
(defun elsqlite-demo ()
  "Open ELSQLite with the test database."
  (interactive)
  (let ((test-db (expand-file-name "../tests/test.db"
                                   (file-name-directory
                                    (or load-file-name buffer-file-name)))))
    (elsqlite test-db)))

;; Run the demo:
;; M-x elsqlite-demo RET

;; Example 3: Working with the schema cache (programmatic)
(defun elsqlite-show-table-info (db-path table-name)
  "Show column information for TABLE-NAME in database at DB-PATH."
  (interactive
   (list (read-file-name "Database: ")
         (read-string "Table name: ")))
  (let ((db (sqlite-open db-path)))
    (unwind-protect
        (progn
          (elsqlite-db-cache-schema db)
          (let ((columns (elsqlite-db-get-table-columns db table-name)))
            (message "Columns in %s:\n%s"
                     table-name
                     (mapconcat (lambda (col)
                                  (format "  %s (%s)" (car col) (cdr col)))
                                columns
                                "\n"))))
      (sqlite-close db))))

;; Try it:
;; (elsqlite-show-table-info "../tests/test.db" "users")

;; Example 4: Query complexity detection
(message "Simple query editable: %s"
         (elsqlite-db-query-is-editable-p "SELECT * FROM users"))
;; => t

(message "Complex query editable: %s"
         (elsqlite-db-query-is-editable-p "SELECT COUNT(*) FROM users"))
;; => nil

;; Example 5: Creating a custom completion function
(defun elsqlite-list-all-columns (db-path)
  "List all columns from all tables in DB-PATH."
  (interactive "fDatabase: ")
  (let ((db (sqlite-open db-path)))
    (unwind-protect
        (progn
          (let* ((tables (elsqlite-db-get-tables db))
                 (all-columns nil))
            (dolist (table tables)
              (let ((columns (elsqlite-db-get-column-names db table)))
                (dolist (col columns)
                  (push (format "%s.%s" table col) all-columns))))
            (message "All columns:\n%s"
                     (string-join (nreverse all-columns) "\n"))))
      (sqlite-close db))))

;;; Interactive Tutorial

;; To learn ELSQLite interactively:
;;
;; 1. Run: M-x elsqlite-demo
;;
;; 2. You'll see the schema browser showing:
;;    - Tables: users, posts
;;    - View: active_users
;;    - Index: idx_posts_user
;;
;; 3. Navigate to "users" table and press RET
;;    - See all users
;;    - Note SQL panel shows: SELECT * FROM users LIMIT 50 OFFSET 0
;;
;; 4. Switch to SQL panel with C-x o:
;;    - Modify query: SELECT name, email FROM users WHERE age > 25
;;    - Press C-c C-c to execute
;;    - See results update
;;
;; 5. Navigate history:
;;    - Press M-p to see previous queries
;;    - Press M-n to go forward
;;
;; 6. Navigate between columns:
;;    - Press TAB to move to next column
;;    - Press Shift-TAB to move to previous column
;;
;; 7. Return to schema:
;;    - From table view: Press ^ or Shift-U to return to schema browser
;;    - From schema browser: Press q to quit ELSQLite

;;; Tips and Tricks

;; Tip 1: Page size configuration
;; Set this in your init.el for larger pages:
;; (setq elsqlite-default-page-size 100)

;; Tip 2: SQL panel height
;; Make the SQL panel taller:
;; (setq elsqlite-sql-panel-height 15)

;; Tip 3: Learning SQL
;; Watch the SQL panel as you navigate. You'll internalize:
;; - How LIMIT/OFFSET work for pagination
;; - How ORDER BY affects results
;; - How WHERE clauses filter data
;; - The difference between simple and complex queries

;; Tip 4: Keyboard shortcuts
;; Schema browser:
;;   - RET: Open table
;;   - TAB: Toggle fold/unfold
;;   - q: Quit ELSQLite
;;
;; Table view:
;;   - TAB / Shift-TAB: Navigate between columns
;;   - ^ or Shift-U: Return to schema browser
;;   - g: Refresh current view
;;
;; SQL panel:
;;   - C-c C-c: Execute query
;;   - M-p / M-n: Navigate query history
;;
;; Window navigation:
;;   - C-x o: Switch between SQL and results panels
;;   - Evil users: C-w w or C-w h/j/k/l

(provide 'quickstart)
;;; quickstart.el ends here
