;;; elsqlite.el --- SQLite browser -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dusan Popovic

;; Author: Dusan Popovic <dpx@binaryapparatus.com>
;; Maintainer: Dusan Popovic <dpx@binaryapparatus.com>
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, databases, sqlite
;; URL: https://github.com/dusanx/elsqlite
;; License: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; ELSQLite is a native Emacs SQLite browser that provides a unified
;; interface for exploring and editing SQLite databases.
;;
;; The core philosophy is "turtles all the way down" -- everything is a SQL
;; query, and the UI is a convenient way to build/modify that query.
;;
;; Features:
;; - Two-panel layout: results view (top) and SQL editor (bottom)
;; - Bidirectional sync between SQL panel and data view
;; - Schema browser for exploring database structure
;; - Table browser with pagination and sorting
;; - Automatic edit vs browse mode detection
;; - SQL completion with context awareness
;; - Query history
;;
;; Usage:
;;   M-x elsqlite RET /path/to/database.db RET
;;
;; See README.md for detailed documentation.

;;; Code:

(require 'elsqlite-db)
(require 'elsqlite-sql)
(require 'elsqlite-table)

;;; Customization

(defgroup elsqlite nil
  "SQLite browser for Emacs."
  :group 'tools
  :prefix "elsqlite-")

(defcustom elsqlite-default-page-size 50
  "Default number of rows to display per page."
  :type 'integer
  :group 'elsqlite)

(defcustom elsqlite-sql-panel-height 10
  "Height in lines for the SQL panel."
  :type 'integer
  :group 'elsqlite)

(defcustom elsqlite-auto-open-sqlite-files nil
  "When non-nil, automatically open SQLite files in ELSQLite.
When you visit a .db, .sqlite, or .sqlite3 file with `find-file',
it will open in ELSQLite instead of as raw bytes."
  :type 'boolean
  :group 'elsqlite)

;;; Buffer-local variables

(defvar-local elsqlite--db nil
  "Database handle for current ELSQLite session.")

(defvar-local elsqlite--db-file nil
  "Path to the currently open database file.")

(defvar-local elsqlite--sql-buffer nil
  "Buffer containing the SQL panel.")

(defvar-local elsqlite--results-buffer nil
  "Buffer containing the results/business panel.")

(defvar-local elsqlite--other-panel nil
  "Reference to the paired panel buffer.")

;;; Entry point

;;;###autoload
(defun elsqlite (db-file)
  "Open SQLite database DB-FILE in ELSQLite browser."
  (interactive
   (list (read-file-name "SQLite database: "
                         nil nil t nil
                         (lambda (name)
                           (or (directory-name-p name)
                               (string-match-p "\\.\\(db\\|sqlite\\|sqlite3\\)\\'" name))))))

  (unless (sqlite-available-p)
    (user-error "SQLite support not available in this Emacs build"))

  (unless (file-exists-p db-file)
    (user-error "Database file does not exist: %s" db-file))

  (let* ((db-file (expand-file-name db-file))
         (db (sqlite-open db-file))
         (db-name (file-name-nondirectory db-file))
         (sql-buffer-name (format "*ELSQLite SQL: %s*" db-name))
         (results-buffer-name (format "*ELSQLite: %s*" db-name)))

    ;; Create SQL panel buffer
    (let ((sql-buffer (get-buffer-create sql-buffer-name)))
      (with-current-buffer sql-buffer
        (elsqlite-sql-mode)
        (setq elsqlite--db db
              elsqlite--db-file db-file))

      ;; Create results panel buffer
      (let ((results-buffer (get-buffer-create results-buffer-name)))
        (with-current-buffer results-buffer
          (elsqlite-table-mode)
          (setq elsqlite--db db
                elsqlite--db-file db-file))

        ;; Link the two buffers
        (with-current-buffer sql-buffer
          (setq elsqlite--results-buffer results-buffer
                elsqlite--other-panel results-buffer)
          ;; Add cleanup hook
          (add-hook 'kill-buffer-hook #'elsqlite--cleanup-on-kill nil t))
        (with-current-buffer results-buffer
          (setq elsqlite--sql-buffer sql-buffer
                elsqlite--other-panel sql-buffer)
          ;; Add cleanup hook
          (add-hook 'kill-buffer-hook #'elsqlite--cleanup-on-kill nil t))

        ;; Set up the window layout
        (elsqlite--setup-layout sql-buffer results-buffer)

        ;; Initialize with schema viewer
        (with-current-buffer sql-buffer
          (require 'elsqlite-table)
          (elsqlite-sql-set-query "")
          (elsqlite-sql-execute))))))

(defun elsqlite--setup-layout (sql-buf results-buf)
  "Set up two-panel layout with SQL-BUF on top and RESULTS-BUF below."
  ;; Switch to results buffer in current window
  (switch-to-buffer results-buf)

  ;; Split window and show SQL buffer on top
  (let ((results-window (selected-window)))
    (select-window (split-window-vertically (- elsqlite-sql-panel-height)))
    (switch-to-buffer sql-buf)
    (select-window results-window)))

;;; Cleanup

(defun elsqlite--cleanup-on-kill ()
  "Clean up paired buffer and database when this buffer is killed."
  (let ((paired-buffer elsqlite--other-panel)
        (db elsqlite--db))

    ;; Close database connection
    (when (and db (sqlite-available-p))
      (ignore-errors (sqlite-close db)))

    ;; Kill paired buffer if it exists
    (when (and paired-buffer (buffer-live-p paired-buffer))
      (with-current-buffer paired-buffer
        ;; Remove the hook temporarily to avoid recursive cleanup
        (remove-hook 'kill-buffer-hook #'elsqlite--cleanup-on-kill t)
        ;; Close database in paired buffer too
        (when (and elsqlite--db (sqlite-available-p))
          (ignore-errors (sqlite-close elsqlite--db))))
      ;; Kill the buffer and its windows
      (let ((windows (get-buffer-window-list paired-buffer nil t)))
        (dolist (win windows)
          (when (window-live-p win)
            (delete-window win))))
      (kill-buffer paired-buffer))))

;;; Quit

(defun elsqlite-quit ()
  "Quit ELSQLite, closing both panels and the database."
  (interactive)
  (when elsqlite--db
    (let ((db elsqlite--db)
          (sql-buf elsqlite--sql-buffer)
          (results-buf elsqlite--results-buffer))

      ;; Close database
      (when (sqlite-available-p)
        (ignore-errors (sqlite-close db)))

      ;; Kill buffers
      (when (buffer-live-p sql-buf)
        (kill-buffer sql-buf))
      (when (buffer-live-p results-buf)
        (kill-buffer results-buf)))))

;;; Refresh

(defun elsqlite-refresh ()
  "Refresh the current view by re-executing the current query."
  (interactive)
  (cond
   ((derived-mode-p 'elsqlite-table-mode)
    (elsqlite-table-refresh))
   ((derived-mode-p 'elsqlite-sql-mode)
    (message "Use C-c C-c to execute query from SQL panel"))))

;;; Mode definitions

(defvar-keymap elsqlite-mode-map
  :doc "Keymap shared by all ELSQLite modes."
  "C-x C-s" #'elsqlite-save
  "C-c C-k" #'elsqlite-discard-changes
  "q"       #'elsqlite-quit
  "g"       #'elsqlite-refresh)

(define-derived-mode elsqlite-mode special-mode "ELSQLite"
  "Base mode for ELSQLite buffers."
  :group 'elsqlite
  (setq buffer-read-only t))

;;; Save/discard functionality

(defun elsqlite-save ()
  "Save pending changes to the database."
  (interactive)
  (message "Save functionality not yet implemented"))

(defun elsqlite-discard-changes ()
  "Discard pending changes."
  (interactive)
  (message "Discard functionality not yet implemented"))

;;; Aliases

;;;###autoload
(defalias 'elsqlite-browser #'elsqlite)

;;; Auto-open SQLite files

(defun elsqlite--auto-open-handler ()
  "Open SQLite files in ELSQLite if `elsqlite-auto-open-sqlite-files' is non-nil."
  (when (and elsqlite-auto-open-sqlite-files
             buffer-file-name
             (string-match-p "\\.\\(db\\|sqlite3?\\)\\'" buffer-file-name)
             (not (derived-mode-p 'elsqlite-mode)))
    (let ((db-file buffer-file-name))
      (kill-buffer (current-buffer))
      (elsqlite db-file))))

;;;###autoload
(defun elsqlite-enable-auto-open ()
  "Enable automatic opening of SQLite files in ELSQLite.
Adds a hook to `find-file-hook' that opens .db, .sqlite, and .sqlite3
files in ELSQLite instead of as raw bytes."
  (interactive)
  (setq elsqlite-auto-open-sqlite-files t)
  (add-hook 'find-file-hook #'elsqlite--auto-open-handler)
  (message "ELSQLite auto-open enabled for SQLite files"))

;;;###autoload
(defun elsqlite-disable-auto-open ()
  "Disable automatic opening of SQLite files in ELSQLite."
  (interactive)
  (setq elsqlite-auto-open-sqlite-files nil)
  (remove-hook 'find-file-hook #'elsqlite--auto-open-handler)
  (message "ELSQLite auto-open disabled"))

(provide 'elsqlite)
;;; elsqlite.el ends here
