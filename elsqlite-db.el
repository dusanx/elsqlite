;;; elsqlite-db.el --- Database operations for ELSQLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dusan Popovic

;; Author: Dusan Popovic <dpx@binaryapparatus.com>
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

;; This module handles all database operations for ELSQLite:
;; - Opening and closing databases
;; - Schema caching and inspection
;; - Query execution with parameter binding
;; - Helper functions for table information

;;; Code:

(require 'sqlite)

;;; Schema caching

(defvar-local elsqlite-db--schema-cache nil
  "Cached schema information for the current database.
Structure: (tables . TABLES-ALIST)
           (views . VIEWS-LIST)
           (indexes . INDEXES-LIST)

TABLES-ALIST: ((table-name . COLUMNS-ALIST) ...)
COLUMNS-ALIST: ((column-name . column-type) ...)")

(defun elsqlite-db-cache-schema (db)
  "Build and cache schema information from DB."
  (let ((objects (sqlite-select db "SELECT name, type, sql FROM sqlite_master WHERE type IN ('table', 'view', 'index') ORDER BY type, name"))
        (tables '())
        (views '())
        (indexes '()))

    ;; Separate objects by type
    (dolist (obj objects)
      (let ((name (nth 0 obj))
            (type (nth 1 obj)))
        (pcase type
          ("table"
           (unless (string-prefix-p "sqlite_" name) ; Skip internal tables
             (let ((columns (elsqlite-db--get-table-columns db name)))
               (push (cons name columns) tables))))
          ("view"
           (push name views))
          ("index"
           (unless (string-prefix-p "sqlite_" name) ; Skip internal indexes
             (push name indexes))))))

    (setq elsqlite-db--schema-cache
          `((tables . ,(nreverse tables))
            (views . ,(nreverse views))
            (indexes . ,(nreverse indexes))))

    elsqlite-db--schema-cache))

(defun elsqlite-db--get-table-columns (db table-name)
  "Get list of columns for TABLE-NAME in DB.
Returns alist of (column-name . type)."
  (let ((pragma-result (sqlite-select db (format "PRAGMA table_info(%s)" table-name))))
    (mapcar (lambda (row)
              ;; PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
              (cons (nth 1 row)  ; name
                    (nth 2 row)))  ; type
            pragma-result)))

(defun elsqlite-db-get-schema (db)
  "Get cached schema for DB, building it if necessary."
  (or elsqlite-db--schema-cache
      (elsqlite-db-cache-schema db)))

(defun elsqlite-db-get-tables (db)
  "Get list of table names from DB."
  (let ((schema (elsqlite-db-get-schema db)))
    (mapcar #'car (alist-get 'tables schema))))

(defun elsqlite-db-get-table-columns (db table-name)
  "Get list of column definitions for TABLE-NAME in DB.
Returns alist of (column-name . type)."
  (let* ((schema (elsqlite-db-get-schema db))
         (tables (alist-get 'tables schema)))
    (alist-get table-name tables nil nil #'string=)))

(defun elsqlite-db-get-column-names (db table-name)
  "Get list of column names for TABLE-NAME in DB."
  (mapcar #'car (elsqlite-db-get-table-columns db table-name)))

;;; Query execution

(defun elsqlite-db-execute (db sql &optional params)
  "Execute SQL query on DB with optional PARAMS.
Use this for INSERT, UPDATE, DELETE operations.
Returns number of affected rows."
  (if params
      (sqlite-execute db sql params)
    (sqlite-execute db sql)))

(defun elsqlite-db-select (db sql &optional params)
  "Execute SELECT query SQL on DB with optional PARAMS.
Returns list of rows (each row is a list of values)."
  (if params
      (sqlite-select db sql params)
    (sqlite-select db sql)))

(defun elsqlite-db-select-full (db sql &optional params)
  "Execute SELECT query SQL on DB with optional PARAMS.
Returns (COLUMNS . ROWS) where COLUMNS is list of column names."
  (let* ((result (if params
                     (sqlite-select db sql params 'full)
                   (sqlite-select db sql nil 'full)))
         (columns (car result))
         (rows (cdr result)))
    (cons columns rows)))

;;; Query analysis

(defun elsqlite-db-query-is-editable-p (sql)
  "Determine if SQL query results can be edited.
Query is editable when ALL conditions are met:
- Single table in FROM (no JOINs)
- No GROUP BY
- No DISTINCT
- No aggregate functions (COUNT, SUM, AVG, etc.)
- No subqueries in SELECT"
  (let ((sql-upper (upcase sql)))
    (and
     ;; Must be a SELECT
     (string-match-p "^[[:space:]]*SELECT" sql-upper)

     ;; No DISTINCT
     (not (string-match-p "\\bDISTINCT\\b" sql-upper))

     ;; No GROUP BY
     (not (string-match-p "\\bGROUP[[:space:]]+BY\\b" sql-upper))

     ;; No JOIN
     (not (string-match-p "\\bJOIN\\b" sql-upper))

     ;; No aggregate functions (simplified check)
     (not (string-match-p "\\b\\(COUNT\\|SUM\\|AVG\\|MIN\\|MAX\\)\\s-*(" sql-upper))

     ;; No subquery in SELECT (simplified: look for SELECT after first SELECT)
     (not (string-match-p "SELECT.*SELECT" sql-upper)))))

(defun elsqlite-db-extract-table-name (sql)
  "Extract table name from a simple SELECT query SQL.
Returns nil if query is complex or table cannot be determined."
  (when (elsqlite-db-query-is-editable-p sql)
    (let ((sql-upper (upcase sql)))
      (when (string-match "\\bFROM[[:space:]]+\\([a-zA-Z_][a-zA-Z0-9_]*\\)" sql-upper)
        (substring sql (match-beginning 1) (match-end 1))))))

;;; Schema queries

(defun elsqlite-db-get-schema-objects (db)
  "Get list of all schema objects (tables, views, indexes) from DB.
Returns list of (name type sql) tuples."
  (sqlite-select db
                 "SELECT name, type, sql FROM sqlite_master WHERE type IN ('table', 'view', 'index') AND name NOT LIKE 'sqlite_%' ORDER BY type, name"))

(defun elsqlite-db-get-table-info (db table-name)
  "Get detailed information about TABLE-NAME from DB.
Returns list of (cid name type notnull dflt_value pk) tuples."
  (sqlite-select db (format "PRAGMA table_info(%s)" table-name)))

(defun elsqlite-db-count-rows (db table-name)
  "Count number of rows in TABLE-NAME in DB."
  (let ((result (sqlite-select db (format "SELECT COUNT(*) FROM %s" table-name))))
    (car (car result))))

(provide 'elsqlite-db)
;;; elsqlite-db.el ends here
