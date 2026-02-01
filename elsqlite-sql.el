;;; elsqlite-sql.el --- SQL panel for ELSQLite -*- lexical-binding: t; -*-

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

;; This module implements the SQL editor panel for ELSQLite:
;; - SQL editing with syntax highlighting
;; - Query execution
;; - Query history navigation
;; - Context-aware SQL completion

;;; Code:

(require 'sql)
(require 'elsqlite-db)

;; Forward declarations
(defvar elsqlite--db)
(defvar elsqlite--sql-buffer)
(defvar elsqlite--results-buffer)
(defvar elsqlite-table--magic-schema-query)
(declare-function elsqlite-table-execute-query "elsqlite-table")

;;; Variables

(defvar-local elsqlite-sql--history nil
  "List of previously executed queries in this session.")

(defvar-local elsqlite-sql--history-index nil
  "Current position in query history, or nil if not browsing history.")

(defvar-local elsqlite-sql--last-select-query nil
  "Last successfully executed SELECT query (for restoring after modifications).")

(defvar-local elsqlite-sql--previous-point nil
  "Previous cursor position in results buffer before modification query.")

(defvar-local elsqlite-sql--previous-window-start nil
  "Previous scroll position in results buffer before modification query.")

;;; SQL Mode

(defvar-keymap elsqlite-sql-mode-map
  :doc "Keymap for ELSQLite SQL panel."
  :parent prog-mode-map
  "C-c C-c" #'elsqlite-sql-execute
  "M-p"     #'elsqlite-sql-history-previous
  "M-n"     #'elsqlite-sql-history-next
  "TAB"     #'completion-at-point)

(define-derived-mode elsqlite-sql-mode sql-mode "ELSQLite-SQL"
  "Major mode for ELSQLite SQL panel."
  :group 'elsqlite

  ;; SQL syntax highlighting is inherited from sql-mode
  ;; Ensure font-lock is enabled (important for batch mode)
  (font-lock-mode 1)

  ;; Set up completion (prepend to keep sql-mode completion too)
  (add-hook 'completion-at-point-functions
            #'elsqlite-sql-completion-at-point nil t)

  ;; Make buffer editable
  (setq buffer-read-only nil)

  ;; Add to mode line
  (setq mode-line-format
        '("%e" mode-line-front-space
          mode-line-buffer-identification " "
          "(" mode-name ") "
          mode-line-misc-info
          mode-line-end-spaces)))

;;; Query execution

(defun elsqlite-sql--query-is-read-only-p (sql)
  "Return t if SQL is a read-only query (SELECT, WITH, EXPLAIN, PRAGMA)."
  (let ((trimmed-sql (string-trim sql)))
    (or (string-match-p "\\`\\(SELECT\\|WITH\\|EXPLAIN\\|PRAGMA\\)\\>"
                        (upcase trimmed-sql))
        ;; Empty string is considered read-only (triggers schema view)
        (string-empty-p trimmed-sql))))

(defun elsqlite-sql--restore-after-modification ()
  "Restore previous SELECT query and positions after successful modification query."
  (let ((results-buffer (current-buffer))
        ;; Read saved state from SQL buffer
        (saved-query (when (and elsqlite--sql-buffer
                                (buffer-live-p elsqlite--sql-buffer))
                       (buffer-local-value 'elsqlite-sql--last-select-query elsqlite--sql-buffer)))
        (saved-point (when (and elsqlite--sql-buffer
                                (buffer-live-p elsqlite--sql-buffer))
                       (buffer-local-value 'elsqlite-sql--previous-point elsqlite--sql-buffer)))
        (saved-window-start (when (and elsqlite--sql-buffer
                                       (buffer-live-p elsqlite--sql-buffer))
                              (buffer-local-value 'elsqlite-sql--previous-window-start elsqlite--sql-buffer))))

    ;; Restore previous query to SQL buffer
    (when (and elsqlite--sql-buffer
               (buffer-live-p elsqlite--sql-buffer))
      (with-current-buffer elsqlite--sql-buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (or saved-query ""))
          (goto-char (point-min)))))

    ;; Re-execute the restored query (in SQL buffer context)
    (when (and elsqlite--sql-buffer
               (buffer-live-p elsqlite--sql-buffer))
      (with-current-buffer elsqlite--sql-buffer
        (let ((sql-to-execute (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
          ;; If empty, use schema query
          (when (string-empty-p sql-to-execute)
            (require 'elsqlite-table)
            (setq sql-to-execute elsqlite-table--magic-schema-query))

          ;; Execute in results buffer - if it fails (e.g., table was dropped), show schema
          (with-current-buffer results-buffer
            (condition-case err
                (elsqlite-table-execute-query sql-to-execute)
              (error
               ;; Restore failed (e.g., table was dropped), fall back to schema view
               (message "Cannot restore previous view (%s), showing schema" (error-message-string err))
               (with-current-buffer elsqlite--sql-buffer
                 (let ((inhibit-read-only t))
                   (erase-buffer)
                   (goto-char (point-min))))
               (require 'elsqlite-table)
               (elsqlite-table-execute-query elsqlite-table--magic-schema-query)))))))

    ;; Restore cursor and scroll positions
    (when (and saved-point (buffer-live-p results-buffer))
      (with-current-buffer results-buffer
        ;; Restore point (safely, in case buffer is shorter now)
        (goto-char (min saved-point (point-max)))

        ;; Restore window scroll position
        (when saved-window-start
          (let ((window (get-buffer-window results-buffer)))
            (when window
              (set-window-start window saved-window-start t))))))))

(defun elsqlite-sql-execute ()
  "Execute the SQL query in the current buffer and update results panel.
If buffer is empty, display the schema browser."
  (interactive)
  (let* ((original-sql (string-trim (buffer-substring-no-properties (point-min) (point-max))))
         (sql original-sql)
         (results-buffer elsqlite--results-buffer)
         (is-read-only (elsqlite-sql--query-is-read-only-p original-sql)))

    (unless (buffer-live-p results-buffer)
      (user-error "Results buffer no longer exists"))

    ;; If query is a modification query (not read-only), save current view positions
    (unless is-read-only
      ;; Save cursor and scroll position from results buffer
      (when (buffer-live-p results-buffer)
        (let ((saved-pt (with-current-buffer results-buffer (point)))
              (saved-win-start (let ((window (get-buffer-window results-buffer)))
                                 (when window (window-start window)))))
          ;; Store in SQL buffer's local variables
          (setq elsqlite-sql--previous-point saved-pt
                elsqlite-sql--previous-window-start saved-win-start))))

    ;; If buffer is empty, use schema query
    (when (string-empty-p sql)
      (require 'elsqlite-table)
      (setq sql elsqlite-table--magic-schema-query))

    ;; Add to history (skip empty buffer case)
    (unless (string-empty-p original-sql)
      (elsqlite-sql--add-to-history sql))

    ;; Execute query in results buffer context
    (with-current-buffer results-buffer
      (condition-case err
          (progn
            (elsqlite-table-execute-query sql)
            ;; Success
            (if is-read-only
                ;; Read-only query: save it as the last SELECT for future restoration
                (when (and elsqlite--sql-buffer
                           (buffer-live-p elsqlite--sql-buffer))
                  (with-current-buffer elsqlite--sql-buffer
                    (setq elsqlite-sql--last-select-query original-sql)))
              ;; Modification query: restore previous SELECT
              (elsqlite-sql--restore-after-modification)))
        (error
         ;; Error: keep the failed query in SQL buffer for correction
         (message "SQL error: %s" (error-message-string err)))))))

(defun elsqlite-sql--add-to-history (sql)
  "Add SQL to query history."
  (unless (string-empty-p sql)
    ;; Don't add duplicate of most recent query
    (unless (and elsqlite-sql--history
                 (string= sql (car elsqlite-sql--history)))
      (push sql elsqlite-sql--history))
    ;; Reset history browsing
    (setq elsqlite-sql--history-index nil)))

;;; Query history navigation

(defun elsqlite-sql-history-previous ()
  "Replace current query with previous query from history."
  (interactive)
  (unless elsqlite-sql--history
    (user-error "No query history"))

  (let ((index (if elsqlite-sql--history-index
                   (1+ elsqlite-sql--history-index)
                 0)))
    (when (>= index (length elsqlite-sql--history))
      (user-error "Beginning of history"))

    (setq elsqlite-sql--history-index index)
    (elsqlite-sql--replace-buffer-content
     (nth index elsqlite-sql--history))))

(defun elsqlite-sql-history-next ()
  "Replace current query with next query from history."
  (interactive)
  (unless elsqlite-sql--history-index
    (user-error "End of history"))

  (let ((index (1- elsqlite-sql--history-index)))
    (if (< index 0)
        (progn
          (setq elsqlite-sql--history-index nil)
          (elsqlite-sql--replace-buffer-content ""))
      (setq elsqlite-sql--history-index index)
      (elsqlite-sql--replace-buffer-content
       (nth index elsqlite-sql--history)))))

(defun elsqlite-sql--replace-buffer-content (text)
  "Replace buffer content with TEXT."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert text)
    (goto-char (point-min))))

;;; SQL Completion

(defun elsqlite-sql-completion-at-point ()
  "Provide SQL completion at point."
  (let* ((bounds (bounds-of-thing-at-point 'symbol))
         (start (or (car bounds) (point)))
         (end (or (cdr bounds) (point)))
         (context (elsqlite-sql--get-completion-context))
         (candidates (elsqlite-sql--get-completion-candidates context)))

    (when candidates
      (list start end candidates
            :annotation-function
            (lambda (cand)
              (let ((type (get-text-property 0 'elsqlite-type cand)))
                (pcase type
                  ('keyword " <keyword>")
                  ('table " <table>")
                  ('column " <column>")
                  ('function " <function>")
                  (_ ""))))
            :company-kind
            (lambda (cand)
              (let ((type (get-text-property 0 'elsqlite-type cand)))
                (pcase type
                  ('keyword 'keyword)
                  ('table 'class)
                  ('column 'property)
                  ('function 'function)
                  (_ 'text))))))))

(defun elsqlite-sql--get-completion-context ()
  "Determine the completion context based on point position."
  (save-excursion
    (let* ((line-start (line-beginning-position))
           (text-before (buffer-substring-no-properties line-start (point)))
           (text-upper (upcase text-before)))
      (cond
       ;; After FROM or JOIN
       ((string-match-p "\\b\\(FROM\\|JOIN\\)\\s-+[a-zA-Z_]*\\'" text-upper)
        'table)

       ;; After SELECT (but not after FROM)
       ((and (string-match-p "\\bSELECT\\b" text-upper)
             (not (string-match-p "\\bFROM\\b" text-upper)))
        'select-column)

       ;; After WHERE or AND or OR
       ((string-match-p "\\b\\(WHERE\\|AND\\|OR\\)\\s-+[a-zA-Z_]*\\'" text-upper)
        'where-column)

       ;; After ORDER BY
       ((string-match-p "\\bORDER\\s-+BY\\s-+[a-zA-Z_]*\\'" text-upper)
        'order-column)

       ;; After table name and dot (table.column)
       ((string-match "\\b\\([a-zA-Z_][a-zA-Z0-9_]*\\)\\." text-before)
        (let ((table (match-string 1 text-before)))
          (cons 'table-column table)))

       ;; Start of statement or after semicolon
       ((or (string-empty-p (string-trim text-before))
            (string-match-p "^\\s-*;?\\s-*[a-zA-Z]*$" text-before)
            (string-match-p ";\\s-*[a-zA-Z]*\\'" text-before))
        'statement)

       ;; Default: keywords
       (t 'keyword)))))

(defun elsqlite-sql--get-completion-candidates (context)
  "Get completion candidates for CONTEXT."
  (let ((keywords '("SELECT" "FROM" "WHERE" "AND" "OR" "NOT"
                    "ORDER BY" "GROUP BY" "HAVING"
                    "LIMIT" "OFFSET"
                    "INSERT" "INTO" "VALUES"
                    "UPDATE" "SET"
                    "DELETE"
                    "JOIN" "LEFT JOIN" "INNER JOIN" "OUTER JOIN"
                    "ON" "AS"
                    "DISTINCT" "COUNT" "SUM" "AVG" "MIN" "MAX"
                    "ASC" "DESC"))
        (tables (when elsqlite--db
                  (elsqlite-db-get-tables elsqlite--db)))
        (result nil))

    (pcase context
      ('statement
       (setq result (mapcar (lambda (kw) (propertize kw 'elsqlite-type 'keyword))
                            '("SELECT" "INSERT" "UPDATE" "DELETE"))))

      ('table
       (setq result (mapcar (lambda (tbl) (propertize tbl 'elsqlite-type 'table))
                            tables)))

      ((or 'select-column 'where-column 'order-column)
       ;; Offer both keywords and table names
       (setq result (append
                     (mapcar (lambda (kw) (propertize kw 'elsqlite-type 'keyword))
                             '("*" "COUNT" "SUM" "AVG" "MIN" "MAX" "DISTINCT"))
                     (mapcar (lambda (tbl) (propertize tbl 'elsqlite-type 'table))
                             tables))))

      ((pred consp) ; (table-column . table-name)
       (let* ((table (cdr context))
              (columns (when elsqlite--db
                         (elsqlite-db-get-column-names elsqlite--db table))))
         (setq result (mapcar (lambda (col) (propertize col 'elsqlite-type 'column))
                              columns))))

      ('keyword
       (setq result (mapcar (lambda (kw) (propertize kw 'elsqlite-type 'keyword))
                            keywords))))

    result))

;;; Utility functions

(defun elsqlite-sql-set-query (sql)
  "Set the SQL buffer content to SQL."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert sql)
    (goto-char (point-min))
    ;; Ensure syntax highlighting is applied
    (when (fboundp 'font-lock-ensure)
      (font-lock-ensure))))

(provide 'elsqlite-sql)
;;; elsqlite-sql.el ends here
