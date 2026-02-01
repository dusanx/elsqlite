;;; elsqlite-table.el --- Table browser for ELSQLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dusan Popovic

;;; Commentary:

;; This module implements the results/business panel for ELSQLite:
;; - Schema browser (initial view)
;; - Table browser with pagination
;; - Navigation that updates SQL panel
;; - Sort and filter support

;;; Code:

(require 'tabulated-list)
(require 'outline)
(require 'elsqlite-db)

;; Forward declarations
(defvar elsqlite--db)
(defvar elsqlite--db-file)
(defvar elsqlite--sql-buffer)
(defvar elsqlite--results-buffer)
(defvar elsqlite--other-panel)
(declare-function elsqlite-quit "elsqlite")
(declare-function elsqlite-sql-set-query "elsqlite-sql")
(declare-function elsqlite-sql-execute "elsqlite-sql")

;;; Customization

(defgroup elsqlite nil
  "SQLite browser for Emacs."
  :group 'tools
  :prefix "elsqlite-")

(defface elsqlite-header-face
  '((t :inherit (bold header-line)))
  "Face for column header row.
Inherits from bold and header-line to match theme colors."
  :group 'elsqlite)

(defface elsqlite-integer-face
  '((t :inherit font-lock-constant-face))
  "Face for INTEGER columns."
  :group 'elsqlite)

(defface elsqlite-real-face
  '((t :inherit font-lock-constant-face))
  "Face for REAL/FLOAT columns."
  :group 'elsqlite)

(defface elsqlite-text-face
  '((t :inherit default))
  "Face for TEXT columns."
  :group 'elsqlite)

(defface elsqlite-blob-face
  '((t :inherit font-lock-type-face))
  "Face for BLOB columns."
  :group 'elsqlite)

(defface elsqlite-null-face
  '((t :inherit shadow))
  "Face for NULL values."
  :group 'elsqlite)

;;; Variables

(defconst elsqlite-table--magic-schema-query
  "SELECT group_concat(sql_statement, CHAR(10)) AS \"elsqlite_schema_dump\"
FROM (
  SELECT sql || ';' AS sql_statement
  FROM sqlite_schema
  WHERE name NOT LIKE 'sqlite_%'
    AND sql IS NOT NULL
  ORDER BY
    CASE type
      WHEN 'table' THEN 1
      WHEN 'view' THEN 2
      WHEN 'index' THEN 3
      ELSE 4
    END,
    tbl_name,
    name
);"
  "Special query that triggers schema viewer mode.
Returns a formatted database schema dump.")

(defvar-local elsqlite-table--current-query nil
  "Current SQL query being displayed.")

(defvar-local elsqlite-table--current-table nil
  "Current table name if displaying a single table, nil otherwise.")

(defvar-local elsqlite-table--editable-p nil
  "Whether current view is editable.")

(defvar-local elsqlite-table--view-type nil
  "Type of current view: `schema\\=', `table\\=', or `query\\='.")

(defvar-local elsqlite-table--page-size 50
  "Number of rows per page.")

(defvar-local elsqlite-table--current-offset 0
  "Current pagination offset.")

(defvar-local elsqlite-table--total-rows nil
  "Total number of rows in current table (nil if unknown).")

(defvar-local elsqlite-table--column-types nil
  "Alist of (column-name . type) for current table/query.")

(defvar-local elsqlite-table--image-frame nil
  "Child frame showing image preview for BLOB columns.")

(defvar-local elsqlite-table--last-column-index nil
  "Last column index where cursor was positioned (for tracking movement).")

(defvar-local elsqlite-table--last-blob-data nil
  "Last BLOB data shown in preview (to avoid recreating for same image).")

;;; Image Preview for BLOB Columns

(defun elsqlite-table--blob-is-image-p (blob-data)
  "Return t if BLOB-DATA contains image data (PNG, JPEG, GIF, BMP, WEBP)."
  (when (and blob-data (stringp blob-data) (> (length blob-data) 4))
    (or
     ;; PNG: starts with \x89PNG
     (string-prefix-p "\x89PNG" blob-data)
     ;; JPEG: starts with \xFF\xD8\xFF
     (string-prefix-p "\xFF\xD8\xFF" blob-data)
     ;; GIF: starts with GIF87a or GIF89a
     (string-prefix-p "GIF8" blob-data)
     ;; BMP: starts with BM
     (string-prefix-p "BM" blob-data)
     ;; WEBP: starts with RIFF....WEBP
     (and (string-prefix-p "RIFF" blob-data)
          (>= (length blob-data) 12)
          (string= "WEBP" (substring blob-data 8 12))))))

(defun elsqlite-table--close-image-frame ()
  "Close the image preview frame if it exists."
  (when (and elsqlite-table--image-frame
             (frame-live-p elsqlite-table--image-frame))
    (delete-frame elsqlite-table--image-frame))
  (setq elsqlite-table--image-frame nil
        elsqlite-table--last-blob-data nil))

(defun elsqlite-table--show-image-preview (blob-data)
  "Show BLOB-DATA as an image in a child frame."
  ;; Close any existing frame first
  (elsqlite-table--close-image-frame)

  (when (elsqlite-table--blob-is-image-p blob-data)
    (let* (;; Get current window geometry
           (window (selected-window))
           (parent-frame (window-frame window))
           ;; Get window size in pixels for preview size calculation
           (window-pixel-width (window-pixel-width window))
           (window-pixel-height (window-pixel-height window))
           ;; Make preview frame: 3/8 of window width, 3/4 height with margin
           (max-preview-width (- (/ (* window-pixel-width 3) 8) 40))
           (max-preview-height (- (/ (* window-pixel-height 3) 4) 40))
           ;; Create scaled image that fits within preview bounds
           (image (create-image blob-data nil t
                                :max-width max-preview-width
                                :max-height max-preview-height))
           (image-size (image-size image t))
           (img-width (car image-size))
           ;; Calculate position for bottom-right of entire FRAME (not window/pane)
           (preview-width-px max-preview-width)
           (preview-height-px max-preview-height)
           ;; Get parent frame dimensions
           (parent-frame-width (frame-pixel-width parent-frame))
           (parent-frame-height (frame-pixel-height parent-frame))
           ;; Position at bottom-right corner of entire frame with margin
           (margin-x 30)  ;; Right margin
           (margin-y 10)  ;; Bottom margin
           (frame-x (- parent-frame-width preview-width-px margin-x))
           (frame-y (- parent-frame-height preview-height-px margin-y))
           ;; Create buffer for image
           (buffer (generate-new-buffer " *elsqlite-image-preview*")))

      (with-current-buffer buffer
        (erase-buffer)
        ;; Insert image centered horizontally at top
        (let ((centering-space (/ (- max-preview-width img-width) 2)))
          (when (> centering-space 0)
            (insert (propertize " " 'display `(space :width (,centering-space))))))
        (insert-image image)
        (setq mode-line-format nil)
        (setq cursor-type nil)
        (setq cursor-in-non-selected-windows nil))

      ;; Create child frame, temporarily disabling persp-mode hooks to prevent workspace creation
      (setq elsqlite-table--image-frame
            (let ((after-make-frame-functions nil)  ;; Disable all after-make-frame hooks
                  (_persp-init-frame-function nil)   ;; Disable persp-mode frame init
                  (_persp-mode-hook nil))            ;; Disable persp-mode hooks
              (make-frame `((parent-frame . ,parent-frame)
                            (left . ,frame-x)
                            (top . ,frame-y)
                            (width . ,(max 20 (/ max-preview-width (frame-char-width))))
                            (height . ,(max 10 (/ max-preview-height (frame-char-height))))
                            (min-width . 10)
                            (min-height . 4)
                            (border-width . 2)
                            (internal-border-width . 4)
                            (vertical-scroll-bars . nil)
                            (horizontal-scroll-bars . nil)
                            (menu-bar-lines . 0)
                            (tool-bar-lines . 0)
                            (tab-bar-lines . 0)
                            (no-accept-focus . t)
                            (no-focus-on-map . t)
                            (undecorated . t)
                            (cursor-type . nil)
                            (inhibit-double-buffering . t)
                            (drag-internal-border . nil)
                            (drag-with-header-line . nil)
                            (drag-with-mode-line . nil)
                            (desktop-dont-save . t)
                            (no-other-frame . t)
                            (auto-raise . nil)
                            (auto-lower . nil)
                            (skip-taskbar . t)
                            (z-group . above)))))

      ;; Switch to buffer without triggering persp-mode
      (let ((_persp-add-buffer-on-find-file nil)
            (_persp-add-buffer-on-after-change-major-mode nil))
        (with-selected-frame elsqlite-table--image-frame
          (switch-to-buffer buffer)
          ;; Center the content vertically and horizontally
          (goto-char (point-min))
          (recenter)))

      ;; Save the blob data so we can detect if same image next time
      (setq elsqlite-table--last-blob-data blob-data))))

(defun elsqlite-table--on-window-selection-change (frame)
  "Close image preview when window focus leaves a table buffer.
Called via `window-selection-change-functions'."
  (when frame
    ;; Check all windows in the frame
    (dolist (window (window-list frame))
      (with-current-buffer (window-buffer window)
        ;; If this is a table buffer but not the selected window, close preview
        (when (and (derived-mode-p 'elsqlite-table-mode)
                   (not (eq window (selected-window)))
                   elsqlite-table--image-frame
                   (frame-live-p elsqlite-table--image-frame))
          (elsqlite-table--close-image-frame))))))

(defun elsqlite-table--handle-image-preview ()
  "Show or hide image preview based on current column and cell content.
Only shows preview when cursor is in the table buffer, not in SQL buffer."
  (if (not (derived-mode-p 'elsqlite-table-mode))
      ;; Not in table buffer - close any preview
      (elsqlite-table--close-image-frame)

    ;; In table buffer - handle preview normally
    (let* ((col-index (elsqlite-table--current-column))
           (column-changed (not (equal col-index elsqlite-table--last-column-index)))
           (entry (tabulated-list-get-entry))
           (displayed-value (when (and entry col-index (>= col-index 0) (< col-index (length entry)))
                              (aref entry col-index)))
           (raw-blob (when (stringp displayed-value)
                       (get-text-property 0 'elsqlite-raw-blob displayed-value)))
           (has-image (and raw-blob (elsqlite-table--blob-is-image-p raw-blob))))

      ;; Update tracked column
      (setq elsqlite-table--last-column-index col-index)

      (cond
       ;; Case 1: In schema view - close any preview
       ((eq elsqlite-table--view-type 'schema)
        (elsqlite-table--close-image-frame))

       ;; Case 2: No column (outside table) - close preview
       ((not col-index)
        (elsqlite-table--close-image-frame))

       ;; Case 3: Column changed to a column with image - show new preview
       ((and column-changed has-image)
        (elsqlite-table--close-image-frame)
        (elsqlite-table--show-image-preview raw-blob))

       ;; Case 4: Column changed to column without image - close preview
       ((and column-changed (not has-image))
        (elsqlite-table--close-image-frame))

       ;; Case 5: Same column, has image - update preview only if different image
       ;; This handles moving up/down in an image column
       ((and (not column-changed) has-image)
        ;; Only recreate preview if blob data changed (different image) or frame doesn't exist
        (unless (and (equal raw-blob elsqlite-table--last-blob-data)
                     elsqlite-table--image-frame
                     (frame-live-p elsqlite-table--image-frame))
          (elsqlite-table--show-image-preview raw-blob)))

       ;; Case 6: Same column, no image (empty/null) - close preview
       ((and (not column-changed) (not has-image))
        (elsqlite-table--close-image-frame))))))

;;; Table Mode

(defvar-keymap elsqlite-table-mode-map
  :doc "Keymap for ELSQLite results panel."
  :parent tabulated-list-mode-map
  "TAB"     #'elsqlite-table-next-column
  "S-TAB"   #'elsqlite-table-previous-column
  "<backtab>" #'elsqlite-table-previous-column  ;; Alternative for S-TAB
  "^"       #'elsqlite-table-back-to-schema
  "S-u"     #'elsqlite-table-back-to-schema)  ;; Shift-u for uppercase U

(define-derived-mode elsqlite-table-mode tabulated-list-mode "ELSQLite-Table"
  "Major mode for ELSQLite results panel."
  :group 'elsqlite

  (setq tabulated-list-padding 0)  ;; No padding before columns
  (setq truncate-lines t)  ;; Critical for horizontal scroll

  ;; Make buffer read-only
  (setq buffer-read-only t)

  ;; Disable built-in header-line (we use first row as header)
  (setq tabulated-list-use-header-line nil)

  ;; Enable current row highlighting (uses theme's hl-line face)
  (hl-line-mode 1)

  ;; Enable automatic horizontal scrolling
  (setq-local auto-hscroll-mode t)
  (setq-local horizontal-scroll-bar t)

  ;; Ensure our keybindings are set (in addition to keymap definition)
  (local-set-key (kbd "^") #'elsqlite-table-back-to-schema)
  (local-set-key (kbd "S-u") #'elsqlite-table-back-to-schema)
  (local-set-key (kbd "TAB") #'elsqlite-table-next-column)
  (local-set-key (kbd "S-TAB") #'elsqlite-table-previous-column)

  ;; Update mode line dynamically as cursor moves
  (setq mode-line-format
        '("%e" mode-line-front-space
          (:eval (elsqlite-table--mode-line))
          mode-line-end-spaces))

  ;; Force mode-line update and handle image preview on cursor movement
  (add-hook 'post-command-hook
            (lambda ()
              (force-mode-line-update)
              (elsqlite-table--handle-image-preview))
            nil t)

  ;; Close image preview when window loses focus (global hook, safe to add multiple times)
  (add-hook 'window-selection-change-functions
            #'elsqlite-table--on-window-selection-change)

  ;; Clean up image frame when buffer is killed
  (add-hook 'kill-buffer-hook #'elsqlite-table--close-image-frame nil t))

(defun elsqlite-table--get-current-field-info ()
  "Get information about the field at point: (name type value)."
  (when (and (eq major-mode 'elsqlite-table-mode)
             (not (eq elsqlite-table--view-type 'schema)))
    (let* ((col-index (elsqlite-table--current-column))
           (entry (tabulated-list-get-entry)))
      (when (and col-index entry (>= col-index 0) (< col-index (length entry)))
        (let* ((column-name (when tabulated-list-format
                              (aref tabulated-list-format col-index)))
               (field-name (when column-name (car column-name)))
               (field-type (when (and field-name elsqlite-table--column-types)
                             (cdr (assoc field-name elsqlite-table--column-types))))
               (field-value (aref entry col-index)))
          (when field-name
            (list field-name field-type field-value)))))))

(defun elsqlite-table--mode-line ()
  "Generate mode line for table view."
  (let ((db-name (when elsqlite--db-file
                   (file-name-nondirectory elsqlite--db-file)))
        (table-indicator (cond
                          ((eq elsqlite-table--view-type 'schema)
                           "[Schema]")
                          (elsqlite-table--current-table
                           (format "[%s]" elsqlite-table--current-table))
                          (t "[Query]")))
        (field-info (elsqlite-table--get-current-field-info)))
    (string-join
     (delq nil (list (format "ELSQLite[%s]" (or db-name ""))
                     table-indicator
                     (when field-info
                       (let* ((name (nth 0 field-info))
                              (type (nth 1 field-info))
                              (value (string-trim (nth 2 field-info))))
                         (format "(%s %s = %s)"
                                 name
                                 (or type "?")
                                 (if (> (length value) 50)
                                     (concat (substring value 0 47) "...")
                                   value))))))
     " ")))

;;; Type Detection

(defun elsqlite-table--get-column-types (table-name)
  "Get column types for TABLE-NAME using PRAGMA table_info.
Returns alist of (column-name . type-string)."
  (when table-name
    (let* ((pragma-result (sqlite-select elsqlite--db
                                          (format "PRAGMA table_info(%s)" table-name)))
           (type-alist '()))
      ;; PRAGMA table_info returns: (cid name type notnull dflt_value pk)
      (dolist (row pragma-result)
        (let ((col-name (nth 1 row))
              (col-type (upcase (or (nth 2 row) "TEXT"))))
          (push (cons col-name col-type) type-alist)))
      (nreverse type-alist))))

(defun elsqlite-table--normalize-type (type-string)
  "Normalize TYPE-STRING to one of: INTEGER REAL TEXT BLOB NULL."
  (when type-string
    (let ((type (upcase type-string)))
      (cond
       ((string-match-p "INT" type) "INTEGER")
       ((string-match-p "REAL\\|FLOAT\\|DOUBLE" type) "REAL")
       ((string-match-p "BLOB" type) "BLOB")
       ((string-match-p "TEXT\\|CHAR\\|CLOB" type) "TEXT")
       (t "TEXT"))))) ;; Default to TEXT

(defun elsqlite-table--get-type-face (type)
  "Get face for column TYPE."
  (pcase type
    ("INTEGER" 'elsqlite-integer-face)
    ("REAL" 'elsqlite-real-face)
    ("BLOB" 'elsqlite-blob-face)
    ("TEXT" 'elsqlite-text-face)
    (_ 'elsqlite-text-face)))

(defun elsqlite-table--should-right-align (type)
  "Return t if TYPE should be right-aligned."
  (member type '("INTEGER" "REAL")))

;;; Header Row Support

(defun elsqlite-table--calculate-column-widths (columns rows)
  "Calculate optimal column widths based on COLUMNS and ROWS content.
Returns a vector of column specifications for tabulated-list-format."
  (let* ((num-cols (length columns))
         (widths (make-vector num-cols 0)))

    ;; Calculate width needed for each column
    (dotimes (i num-cols)
      (let ((max-width (length (nth i columns))))

        ;; Check all data rows for this column
        (dolist (row rows)
          (let* ((val (nth i row))
                 (formatted (elsqlite-table--format-value val))
                 (len (length formatted)))
            (setq max-width (max max-width len))))

        ;; Cap at 100 characters
        (aset widths i (min max-width 100))))

    ;; Build column format vector
    (vconcat
     (cl-loop for col in columns
              for i from 0
              collect (list col (aref widths i) t)))))

(defun elsqlite-table--make-header-row ()
  "Create a header row from tabulated-list-format.
Returns a list entry suitable for tabulated-list-entries."
  (when tabulated-list-format
    (let ((header-cols (cl-loop for col across tabulated-list-format
                                for name = (nth 0 col)
                                for width = (nth 1 col)
                                collect (propertize
                                        ;; Pad to full column width
                                        (truncate-string-to-width name width nil ?\s t)
                                        'face 'elsqlite-header-face))))
      (list 'header (vconcat header-cols)))))

(defun elsqlite-table--add-header-to-entries (entries)
  "Add header row as first entry in ENTRIES."
  (cons (elsqlite-table--make-header-row) entries))

(defun elsqlite-table--format-row-with-padding (row)
  "Format ROW values with padding, alignment, and faces based on column types."
  (vconcat
   (cl-loop for val across row
            for col across tabulated-list-format
            for col-name = (nth 0 col)
            for width = (nth 1 col)
            for col-index from 0
            for type-info = (cdr (assoc col-name elsqlite-table--column-types))
            for normalized-type = (elsqlite-table--normalize-type type-info)
            for right-align = (elsqlite-table--should-right-align normalized-type)
            for face = (if (string= val "NULL")
                          'elsqlite-null-face
                        (elsqlite-table--get-type-face normalized-type))
            collect
            (let* ((str (if (stringp val) val (format "%s" val)))
                   (str-len (length str))
                   (padded (if right-align
                              ;; Right-align: pad on the left
                              (if (< str-len width)
                                  (concat (make-string (- width str-len) ?\s) str)
                                (substring str 0 width))
                            ;; Left-align: pad on the right
                            (truncate-string-to-width str width nil ?\s t))))
              (propertize padded 'face face)))))

;;; Schema Viewer (Text-based with folding)

(defun elsqlite-table--format-schema-sql (sql)
  "Format SQL schema: remove comments, reformat CREATE statements."
  (if (or (null sql) (string-empty-p (string-trim sql)))
      ;; Return empty string if input is empty
      ""
    ;; Else: process the SQL
    (with-temp-buffer
      (insert sql)
      (goto-char (point-min))

      ;; Remove SQL comments (-- style)
      (while (re-search-forward "--[^\n]*" nil t)
        (replace-match "" nil nil))

      ;; Remove SQL comments (/* */ style)
      (goto-char (point-min))
      (while (re-search-forward "/\\*.*?\\*/" nil t)
        (replace-match "" nil nil))

      ;; Join all lines into single line (normalize input)
      (goto-char (point-min))
      (while (re-search-forward "[\n\r]+" nil t)
        (replace-match " " nil nil))

      ;; Process each CREATE statement
      (goto-char (point-min))
      (let ((formatted-statements '()))
        (while (re-search-forward "CREATE\\s-+\\(TABLE\\|VIEW\\|INDEX\\)\\s-+\\(.+?\\);" nil t)
          (let* ((type (match-string 1))
                 (definition (match-string 2))
                 (formatted (elsqlite-table--format-create-statement type definition)))
            (when formatted
              (push formatted formatted-statements))))

        ;; If no statements were formatted, return original SQL
        (if (null formatted-statements)
            (progn
              (message "Warning: No CREATE statements found in schema, returning original")
              sql)
          ;; Replace buffer with formatted statements
          (erase-buffer)
          (insert (string-join (nreverse formatted-statements) "\n\n"))
          (buffer-string))))))

(defun elsqlite-table--format-create-statement (type definition)
  "Format a single CREATE statement of TYPE with DEFINITION.
TYPE is TABLE, VIEW, or INDEX. DEFINITION is everything after CREATE TYPE."
  (let ((cleaned-def (replace-regexp-in-string "[\n\r]+" " " (string-trim definition))))
    (cond
     ;; Format CREATE TABLE
     ((string= type "TABLE")
      (elsqlite-table--format-create-table definition))

     ;; Format CREATE INDEX
     ((string= type "INDEX")
      (concat "CREATE INDEX " cleaned-def ";"))

     ;; Format CREATE VIEW
     ((string= type "VIEW")
      (concat "CREATE VIEW " cleaned-def ";")))))

(defun elsqlite-table--format-create-table (definition)
  "Format CREATE TABLE DEFINITION with columns on separate lines."
  ;; Extract table name and column definitions - handle newlines in definition
  (let ((cleaned-def (replace-regexp-in-string "[\n\r]+" " " definition)))
    (when (string-match "\\([a-zA-Z0-9_]+\\)\\s-*(\\(.*\\))" cleaned-def)
      (let* ((table-name (match-string 1 cleaned-def))
             (columns-text (match-string 2 cleaned-def))
             (columns (elsqlite-table--split-column-definitions columns-text)))

        (when columns
          ;; Build formatted CREATE TABLE
          (concat "CREATE TABLE " table-name " (\n"
                  (mapconcat (lambda (col)
                               (concat "  " (string-trim col)))
                             columns
                             ",\n")
                  "\n);"))))))

(defun elsqlite-table--split-column-definitions (columns-text)
  "Split COLUMNS-TEXT into individual column definitions.
Respects parentheses and quotes when splitting."
  (let ((result '())
        (current "")
        (depth 0)
        (in-string nil)
        (chars (string-to-list columns-text)))

    (dolist (char chars)
      (cond
       ;; Track string literals
       ((and (= char ?\') (not in-string))
        (setq in-string t)
        (setq current (concat current (char-to-string char))))

       ((and (= char ?\') in-string)
        (setq in-string nil)
        (setq current (concat current (char-to-string char))))

       ;; Track parentheses depth (for things like FOREIGN KEY(...))
       ((and (= char ?\() (not in-string))
        (setq depth (1+ depth))
        (setq current (concat current (char-to-string char))))

       ((and (= char ?\)) (not in-string))
        (setq depth (1- depth))
        (setq current (concat current (char-to-string char))))

       ;; Split on comma only at depth 0 and outside strings
       ((and (= char ?,) (= depth 0) (not in-string))
        (push (string-trim current) result)
        (setq current ""))

       ;; Accumulate other characters
       (t
        (setq current (concat current (char-to-string char))))))

    ;; Add the last column
    (when (> (length (string-trim current)) 0)
      (push (string-trim current) result))

    (nreverse result)))

(defvar-local elsqlite-table--parsed-schema nil
  "Parsed schema: alist of (table-name . ((col-name . type) ...)).")

(defun elsqlite-table--parse-schema (sql)
  "Parse SQL schema dump and extract table/column type information.
Returns alist: ((table-name . ((column-name . type) ...)) ...)."
  (let ((schema-alist '()))
    (with-temp-buffer
      (insert sql)
      (goto-char (point-min))

      ;; Find all CREATE TABLE statements
      (while (re-search-forward "CREATE TABLE \\([a-zA-Z0-9_]+\\)\\s-*(" nil t)
        (let* ((table-name (match-string 1))
               (start (point))
               ;; Find matching closing paren
               (end (save-excursion
                      (backward-char 1)  ; Back to opening paren
                      (forward-sexp 1)   ; Jump to closing paren
                      (point)))
               (columns-text (buffer-substring-no-properties start (1- end)))
               (columns-alist '()))

          ;; Parse column definitions
          ;; Split by comma (but not commas inside parentheses)
          (with-temp-buffer
            (insert columns-text)
            (goto-char (point-min))

            (let ((column-defs '())
                  (current-def "")
                  (paren-depth 0))
              ;; Manually split by comma, respecting parentheses
              (while (not (eobp))
                (let ((char (char-after)))
                  (cond
                   ((= char ?\()
                    (setq paren-depth (1+ paren-depth))
                    (setq current-def (concat current-def (char-to-string char))))
                   ((= char ?\))
                    (setq paren-depth (1- paren-depth))
                    (setq current-def (concat current-def (char-to-string char))))
                   ((and (= char ?,) (= paren-depth 0))
                    ;; Found top-level comma - end of column definition
                    (push (string-trim current-def) column-defs)
                    (setq current-def ""))
                   (t
                    (setq current-def (concat current-def (char-to-string char))))))
                (forward-char 1))

              ;; Add the last column
              (when (> (length (string-trim current-def)) 0)
                (push (string-trim current-def) column-defs))

              ;; Parse each column definition
              (dolist (col-def (nreverse column-defs))
                ;; Skip constraints (PRIMARY KEY, FOREIGN KEY, etc.)
                (unless (string-match-p "^\\(PRIMARY\\|FOREIGN\\|UNIQUE\\|CHECK\\|CONSTRAINT\\)" col-def)
                  ;; Extract column name and type
                  ;; Format: "column_name TYPE [constraints...]"
                  (when (string-match "^\\([a-zA-Z0-9_]+\\)\\s-+\\([a-zA-Z]+\\)" col-def)
                    (let ((col-name (match-string 1 col-def))
                          (col-type (upcase (match-string 2 col-def))))
                      (push (cons col-name col-type) columns-alist)))))))

          ;; Add table and its columns to schema
          (push (cons table-name (nreverse columns-alist)) schema-alist))))

    (nreverse schema-alist)))

(defun elsqlite-table--get-column-type-from-schema (column-ref)
  "Get column type from parsed schema for COLUMN-REF.
COLUMN-REF can be \\='column or \\='table.column."
  (when elsqlite-table--parsed-schema
    (if (string-match "\\([a-zA-Z0-9_]+\\)\\.\\([a-zA-Z0-9_]+\\)" column-ref)
        ;; table.column format
        (let* ((table-name (match-string 1 column-ref))
               (col-name (match-string 2 column-ref))
               (table-schema (cdr (assoc table-name elsqlite-table--parsed-schema))))
          (cdr (assoc col-name table-schema)))
      ;; Just column name - search all tables, return first match
      (catch 'found
        (dolist (table-entry elsqlite-table--parsed-schema)
          (let ((col-type (cdr (assoc column-ref (cdr table-entry)))))
            (when col-type
              (throw 'found col-type))))
        nil))))

;;; Schema Viewer Mode (outline-based text view)

(require 'sql)

(defvar-keymap elsqlite-schema-mode-map
  :doc "Keymap for ELSQLite schema viewer."
  :parent sql-mode-map
  "RET" #'elsqlite-schema-select-table
  "TAB" #'outline-toggle-children
  "q"   #'elsqlite-quit)

(define-derived-mode elsqlite-schema-mode sql-mode "ELSQLite-Schema"
  "Major mode for viewing database schema with folding support.
Based on sql-mode with outline support for folding."
  :group 'elsqlite

  ;; SQL syntax highlighting is inherited from sql-mode

  ;; Add outline support for folding
  (require 'outline)
  (setq-local outline-regexp "CREATE ")
  (setq-local outline-level (lambda () 1))
  (outline-minor-mode 1)

  ;; Make buffer read-only
  (setq buffer-read-only t)

  ;; Enable current line highlighting
  (hl-line-mode 1)

  ;; Update mode line
  (setq mode-line-format
        '("%e" mode-line-front-space
          (:eval (elsqlite-schema--mode-line))
          mode-line-end-spaces)))

(defun elsqlite-schema--mode-line ()
  "Generate mode line for schema viewer."
  (let ((db-name (when elsqlite--db-file
                   (file-name-nondirectory elsqlite--db-file))))
    (format "ELSQLite[%s] [Schema Viewer]" (or db-name ""))))

(defun elsqlite-table-show-schema-viewer (schema-sql)
  "Display formatted SCHEMA-SQL in schema viewer with folding support."
  (let* ((formatted-sql (elsqlite-table--format-schema-sql schema-sql))
         (parsed-schema (elsqlite-table--parse-schema formatted-sql))
         ;; Save buffer-local vars before mode change
         (db elsqlite--db)
         (db-file elsqlite--db-file)
         (saved-sql-buffer elsqlite--sql-buffer)
         (results-buffer elsqlite--results-buffer)
         (other-panel elsqlite--other-panel))

    ;; Switch to schema mode (clears buffer-local vars)
    (let ((inhibit-read-only t))
      ;; Clear buffer and insert formatted schema
      (erase-buffer)
      (insert formatted-sql)

      ;; Switch to schema mode (inherits from sql-mode, so syntax highlighting works)
      (elsqlite-schema-mode)

      ;; Restore buffer-local vars AFTER mode change
      (setq elsqlite--db db
            elsqlite--db-file db-file
            elsqlite--sql-buffer saved-sql-buffer
            elsqlite--results-buffer results-buffer
            elsqlite--other-panel other-panel
            elsqlite-table--parsed-schema parsed-schema)

      ;; Close any image preview and reset tracking (schema has no images)
      (elsqlite-table--close-image-frame)
      (setq elsqlite-table--last-column-index nil)

      ;; Collapse all CREATE statements to show only headers
      (goto-char (point-min))
      (outline-hide-body)

      ;; Move to first CREATE statement
      (goto-char (point-min)))

    (message "Schema viewer loaded. Use TAB to fold/unfold, RET on table name to browse.")))

(defun elsqlite-schema-select-table ()
  "Execute SELECT * FROM table at point."
  (interactive)
  (save-excursion
    (beginning-of-line)
    (when (looking-at "CREATE TABLE \\([a-zA-Z0-9_]+\\)")
      (let* ((table-name (match-string 1))
             (sql (format "SELECT * FROM %s LIMIT %d" table-name elsqlite-table--page-size))
             (saved-sql-buffer elsqlite--sql-buffer))
        ;; Put SQL in SQL buffer and execute it through the normal path
        (when (and saved-sql-buffer (buffer-live-p saved-sql-buffer))
          (with-current-buffer saved-sql-buffer
            (require 'elsqlite-sql)
            (elsqlite-sql-set-query sql)
            (elsqlite-sql-execute)))))))

;;; Schema Browser

(defun elsqlite-table-show-schema ()
  "Display database schema (tables, views, indexes)."
  (interactive)
  (let* ((objects (elsqlite-db-get-schema-objects elsqlite--db))
         (columns '("Name" "Type" "SQL"))
         (rows (mapcar (lambda (obj) (list (nth 0 obj) (nth 1 obj) (or (nth 2 obj) "")))
                       objects)))

    ;; Schema browser has no column types (showing schema itself)
    (setq elsqlite-table--column-types nil)

    ;; Calculate optimal column widths based on content
    (setq tabulated-list-format
          (elsqlite-table--calculate-column-widths columns rows))

    ;; Build entries with header row and proper padding
    (let ((data-entries (cl-loop for (name type sql) in objects
                                 for i from 1
                                 collect
                                 (list i (elsqlite-table--format-row-with-padding
                                         (vector name type (or sql "")))))))
      (setq tabulated-list-entries
            (elsqlite-table--add-header-to-entries data-entries)))

    ;; Update buffer state
    (setq elsqlite-table--view-type 'schema
          elsqlite-table--current-table nil
          elsqlite-table--current-query "SELECT name, type, sql FROM sqlite_master WHERE type IN ('table', 'view', 'index') AND name NOT LIKE 'sqlite_%' ORDER BY type, name"
          elsqlite-table--editable-p nil)

    ;; Update SQL panel
    (elsqlite-table--update-sql-panel elsqlite-table--current-query)

    ;; Render (no header line, we use first row)
    (tabulated-list-print t)))

;;; Table Browser

(defun elsqlite-table-show-table (table-name)
  "Display contents of TABLE-NAME."
  (let* ((count (elsqlite-db-count-rows elsqlite--db table-name))
         (offset elsqlite-table--current-offset)
         (limit elsqlite-table--page-size)
         (sql (format "SELECT * FROM %s LIMIT %d OFFSET %d"
                      table-name limit offset))
         (result (elsqlite-db-select-full elsqlite--db sql))
         (columns (car result))
         (rows (cdr result)))

    ;; Get column types from table schema
    (setq elsqlite-table--column-types
          (elsqlite-table--get-column-types table-name))

    ;; Calculate optimal column widths based on content
    (setq tabulated-list-format
          (elsqlite-table--calculate-column-widths columns rows))

    ;; Build entries with header row and proper padding
    (let ((data-entries (cl-loop for row in rows
                                 for i from 1
                                 collect
                                 (list i (elsqlite-table--format-row-with-padding
                                         (vconcat
                                          (mapcar (lambda (val)
                                                    (elsqlite-table--format-value val))
                                                  row)))))))
      (setq tabulated-list-entries
            (elsqlite-table--add-header-to-entries data-entries)))

    ;; Update buffer state
    (setq elsqlite-table--view-type 'table
          elsqlite-table--current-table table-name
          elsqlite-table--current-query sql
          elsqlite-table--total-rows count
          elsqlite-table--editable-p (elsqlite-db-query-is-editable-p sql))

    ;; Update SQL panel
    (elsqlite-table--update-sql-panel sql)

    ;; Render (no header line, we use first row)
    (tabulated-list-print t)))

(defcustom elsqlite-max-column-width 100
  "Maximum width for displaying column values.
Values longer than this will be truncated with \"...\"."
  :type 'integer
  :group 'elsqlite)

(defun elsqlite-table--format-value (val)
  "Format VAL for display in table.
Truncates long strings and BLOBs to `elsqlite-max-column-width'.
Preserves raw BLOB data as a text property for image preview."
  (cond
   ((null val) "NULL")

   ((numberp val) (number-to-string val))

   ((stringp val)
    ;; Check if string contains binary data (non-printable characters)
    (if (string-match-p "[\000-\010\013-\037\177-\237]" val)
        ;; Binary data (BLOB) - show size info but preserve raw data
        (let ((display-text (format "<BLOB:%d bytes>" (length val))))
          (propertize display-text 'elsqlite-raw-blob val))
      ;; Regular text - truncate if too long
      (if (> (length val) elsqlite-max-column-width)
          (concat (substring val 0 elsqlite-max-column-width) "...")
        val)))

   ;; Vector or other types (shouldn't happen but handle it)
   ((vectorp val)
    (let ((display-text (format "<BLOB:%d bytes>" (length val))))
      (propertize display-text 'elsqlite-raw-blob val)))

   (t (format "%s" val))))

;;; Query Execution

(defun elsqlite-table-execute-query (sql)
  "Execute SQL query and display results.
If result contains \\='elsqlite_schema_dump column, show schema viewer instead."
  (let* ((result (elsqlite-db-select-full elsqlite--db sql))
         (columns (car result))
         (rows (cdr result)))

    ;; Check if this is a schema dump query
    (if (member "elsqlite_schema_dump" columns)
        ;; Show schema viewer
        (elsqlite-table-show-schema-viewer (caar rows))

      ;; Normal table/query view
      ;; Save buffer-local vars before mode change
      (let ((db elsqlite--db)
            (db-file elsqlite--db-file)
            (saved-sql-buffer elsqlite--sql-buffer)
            (results-buffer elsqlite--results-buffer)
            (other-panel elsqlite--other-panel))

        ;; Switch to table mode if not already in it
        (unless (eq major-mode 'elsqlite-table-mode)
          (elsqlite-table-mode))

        ;; Always ensure buffer-local vars are set (not just on mode switch)
        (setq elsqlite--db db
              elsqlite--db-file db-file
              elsqlite--sql-buffer saved-sql-buffer
              elsqlite--results-buffer results-buffer
              elsqlite--other-panel other-panel)

        ;; Reset column tracking so image preview triggers on first navigation
        (setq elsqlite-table--last-column-index nil)

        (let ((table-name (elsqlite-db-extract-table-name sql)))
          ;; Get column types if we can determine the source table
          (setq elsqlite-table--column-types
                (when table-name
                  (elsqlite-table--get-column-types table-name)))

          ;; Calculate optimal column widths based on content
          (setq tabulated-list-format
                (elsqlite-table--calculate-column-widths columns rows))

          ;; Build entries with header row and proper padding
          (let ((data-entries (cl-loop for row in rows
                                       for i from 1
                                       collect
                                       (list i (elsqlite-table--format-row-with-padding
                                               (vconcat
                                                (mapcar (lambda (val)
                                                          (elsqlite-table--format-value val))
                                                        row)))))))
            (setq tabulated-list-entries
                  (elsqlite-table--add-header-to-entries data-entries)))

          ;; Update buffer state
          (setq elsqlite-table--view-type (if table-name 'table 'query)
                elsqlite-table--current-table table-name
                elsqlite-table--current-query sql
                elsqlite-table--total-rows (when table-name
                                             (elsqlite-db-count-rows elsqlite--db table-name))
                elsqlite-table--editable-p (and table-name
                                                (elsqlite-db-query-is-editable-p sql))
                elsqlite-table--current-offset 0)

          ;; Render (no header line, we use first row)
          (tabulated-list-print t)

          (message "Query returned %d row%s" (length rows) (if (= (length rows) 1) "" "s")))))))

;;; Navigation

(defun elsqlite-table-drill-down ()
  "Drill down into the item at point."
  (interactive)
  (pcase elsqlite-table--view-type
    ('schema
     ;; Drilling into schema object
     (let* ((entry (tabulated-list-get-entry))
            (name (when entry (aref entry 0)))
            (type (when entry (aref entry 1)))
            (saved-sql-buffer elsqlite--sql-buffer))
       (when name
         (pcase type
           ((or "table" "view")
            ;; Generate SQL and execute through normal path
            (let ((sql (format "SELECT * FROM %s LIMIT %d"
                               name
                               (if (string= type "table")
                                   elsqlite-table--page-size
                                 50))))
              (when (and saved-sql-buffer (buffer-live-p saved-sql-buffer))
                (with-current-buffer saved-sql-buffer
                  (require 'elsqlite-sql)
                  (elsqlite-sql-set-query sql)
                  (elsqlite-sql-execute)))))
           ("index"
            (message "Index details not yet implemented"))))))

    ((or 'table 'query)
     ;; In future, could show record detail view
     (message "Record detail view not yet implemented"))))

(defun elsqlite-table-up ()
  "Go up one level (e.g., from table to schema)."
  (interactive)
  (when (or (eq elsqlite-table--view-type 'table)
            (eq elsqlite-table--view-type 'query))
    (elsqlite-table-show-schema)))

(defun elsqlite-table-back-to-schema ()
  "Reset SQL editor and return to schema viewer."
  (interactive)
  (when (and elsqlite--sql-buffer
             (buffer-live-p elsqlite--sql-buffer))
    (with-current-buffer elsqlite--sql-buffer
      (require 'elsqlite-sql)
      (elsqlite-sql-set-query "")
      (elsqlite-sql-execute))))

;;; Pagination

(defun elsqlite-table-next-page ()
  "Show next page of results."
  (interactive)
  (unless elsqlite-table--current-table
    (user-error "Pagination only available for table views"))

  (let ((new-offset (+ elsqlite-table--current-offset elsqlite-table--page-size))
        (saved-sql-buffer elsqlite--sql-buffer))

    (if (>= new-offset elsqlite-table--total-rows)
        (message "Already at last page")
      (setq elsqlite-table--current-offset new-offset)
      ;; Build SQL with new offset and execute through normal path
      (let ((sql (format "SELECT * FROM %s LIMIT %d OFFSET %d"
                         elsqlite-table--current-table
                         elsqlite-table--page-size
                         new-offset)))
        (when (and saved-sql-buffer (buffer-live-p saved-sql-buffer))
          (with-current-buffer saved-sql-buffer
            (require 'elsqlite-sql)
            (elsqlite-sql-set-query sql)
            (elsqlite-sql-execute)))))))

(defun elsqlite-table-previous-page ()
  "Show previous page of results."
  (interactive)
  (unless elsqlite-table--current-table
    (user-error "Pagination only available for table views"))

  (if (<= elsqlite-table--current-offset 0)
      (message "Already at first page")
    (let ((new-offset (max 0 (- elsqlite-table--current-offset
                                elsqlite-table--page-size)))
          (saved-sql-buffer elsqlite--sql-buffer))
      (setq elsqlite-table--current-offset new-offset)
      ;; Build SQL with new offset and execute through normal path
      (let ((sql (format "SELECT * FROM %s LIMIT %d OFFSET %d"
                         elsqlite-table--current-table
                         elsqlite-table--page-size
                         new-offset)))
        (when (and saved-sql-buffer (buffer-live-p saved-sql-buffer))
          (with-current-buffer saved-sql-buffer
            (require 'elsqlite-sql)
            (elsqlite-sql-set-query sql)
            (elsqlite-sql-execute)))))))

;;; Column Navigation

(defun elsqlite-table--get-column-positions ()
  "Get list of column start positions based on tabulated-list-format.
Returns list of (start-pos . end-pos) for each column.
Accounts for inter-column spacing (2 spaces between columns)."
  (when tabulated-list-format
    (let ((positions '())
          (pos tabulated-list-padding)
          (separator 1))  ;; Space between columns (observed empirically)
      (dotimes (i (length tabulated-list-format))
        (let* ((col (aref tabulated-list-format i))
               (width (nth 1 col))
               (start pos)
               (end (+ pos width)))
          (push (cons start end) positions)
          ;; Next column starts after this column's width + separator
          (setq pos (+ end separator))))
      (nreverse positions))))

(defun elsqlite-table--current-column ()
  "Return current column index (0-based) or nil."
  (let* ((col-positions (elsqlite-table--get-column-positions))
         (current-col (- (current-column) tabulated-list-padding))
         (col-index 0))
    (catch 'found
      (dolist (pos col-positions)
        (when (and (>= current-col (car pos))
                   (< current-col (cdr pos)))
          (throw 'found col-index))
        (setq col-index (1+ col-index)))
      nil)))

(defun elsqlite-table-next-column ()
  "Move to next column, wrapping to next row if at last column."
  (interactive)
  (let* ((col-positions (elsqlite-table--get-column-positions))
         (current-col (elsqlite-table--current-column))
         (num-cols (length col-positions)))
    (when (and col-positions current-col)
      (if (< current-col (1- num-cols))
          ;; Move to next column on same row
          (let ((next-pos (car (nth (1+ current-col) col-positions))))
            (move-to-column (+ tabulated-list-padding next-pos)))
        ;; At last column - move to first column of next row
        (forward-line 1)
        (move-to-column tabulated-list-padding)))))

(defun elsqlite-table-previous-column ()
  "Move to previous column, wrapping to previous row if at first column."
  (interactive)
  (let* ((col-positions (elsqlite-table--get-column-positions))
         (current-col (elsqlite-table--current-column))
         (num-cols (length col-positions)))
    (when (and col-positions current-col)
      (if (> current-col 0)
          ;; Move to previous column on same row
          (let ((prev-pos (car (nth (1- current-col) col-positions))))
            (move-to-column (+ tabulated-list-padding prev-pos)))
        ;; At first column - move to last column of previous row
        (forward-line -1)
        (when col-positions
          (let ((last-pos (car (nth (1- num-cols) col-positions))))
            (move-to-column (+ tabulated-list-padding last-pos))))))))

;;; Refresh

(defun elsqlite-table-refresh ()
  "Refresh current view."
  (interactive)
  (let ((saved-sql-buffer elsqlite--sql-buffer))
    (pcase elsqlite-table--view-type
      ('schema
       ;; Refresh schema viewer
       (when (and saved-sql-buffer (buffer-live-p saved-sql-buffer))
         (with-current-buffer saved-sql-buffer
           (require 'elsqlite-sql)
           (elsqlite-sql-set-query "")
           (elsqlite-sql-execute))))
      ((or 'table 'query)
       ;; Re-execute the current query from SQL buffer
       (when (and saved-sql-buffer (buffer-live-p saved-sql-buffer))
         (with-current-buffer saved-sql-buffer
           (require 'elsqlite-sql)
           (elsqlite-sql-execute)))))))

;;; SQL Panel Sync

(defun elsqlite-table--update-sql-panel (sql)
  "Update SQL panel buffer with SQL query."
  (when (and elsqlite--sql-buffer
             (buffer-live-p elsqlite--sql-buffer))
    (with-current-buffer elsqlite--sql-buffer
      (require 'elsqlite-sql)
      (elsqlite-sql-set-query sql))))

;;; Evil Mode Integration

;; Set up Evil keybindings automatically when Evil is loaded
(with-eval-after-load 'evil
  (when (fboundp 'evil-define-key*)
    ;; Schema viewer mode
    (evil-define-key* 'normal elsqlite-schema-mode-map
      (kbd "RET") #'elsqlite-schema-select-table
      (kbd "TAB") #'outline-toggle-children
      (kbd "q")   #'elsqlite-quit)

    ;; Table mode
    (evil-define-key* 'normal elsqlite-table-mode-map
      (kbd "^")     #'elsqlite-table-back-to-schema
      (kbd "U")     #'elsqlite-table-back-to-schema
      (kbd "TAB")   #'elsqlite-table-next-column
      (kbd "S-TAB") #'elsqlite-table-previous-column)))

(provide 'elsqlite-table)
;;; elsqlite-table.el ends here
