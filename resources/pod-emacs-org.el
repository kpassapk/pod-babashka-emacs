;;; pod-emacs-org.el --- org-mode -> EDN for pod-babashka-emacs -*- lexical-binding: t; -*-
;;; Commentary:
;; The flagship feature: read an org file *through Emacs' real org-mode* and
;; return its structure as EDN.  A babashka driver can then work with the
;; outline as ordinary Clojure data.
;;
;;   pod.babashka.emacs.org/outline    -> nested headline tree
;;   pod.babashka.emacs.org/headlines  -> flat headline list (document order)
;;   pod.babashka.emacs.org/to-edn     -> nested tree incl. each entry's body
;;
;; All three accept (PATH &optional OPTS).  OPTS is an EDN map; recognized keys:
;;   :max-level  <int>   only include headlines at or above this depth
;;; Code:

(require 'org)
(require 'pod-emacs-util)
(require 'subr-x)

(defmacro pod-emacs-org--with-file (path &rest body)
  "Open org file PATH in a temp org-mode buffer and run BODY."
  (declare (indent 1))
  `(let ((p (expand-file-name ,path)))
     (unless (file-readable-p p)
       (error "Cannot read org file: %s" p))
     (with-temp-buffer
       (insert-file-contents p)
       (let ((org-inhibit-startup t)
             (org-element-use-cache nil)
             (org-mode-hook nil))
         (delay-mode-hooks (org-mode)))
       ,@body)))

(defun pod-emacs-org--str (s)
  "Strip text properties from string S (or return nil)."
  (when s (substring-no-properties s)))

(defun pod-emacs-org--props ()
  "Return the entry's drawer properties as a keyword-keyed hash-table, or nil."
  (let ((props (org-entry-properties (point) 'standard))
        (skip '("CATEGORY" "FILE" "BLOCKED" "ITEM" "PRIORITY" "TODO" "TAGS" "ALLTAGS"))
        (h (make-hash-table :test 'equal)))
    (dolist (kv props)
      (unless (member (car kv) skip)
        (puthash (intern (concat ":" (car kv)))
                 (pod-emacs-org--str (cdr kv)) h)))
    (when (> (hash-table-count h) 0) h)))

(defun pod-emacs-org--body ()
  "Return the trimmed body text of the entry at point (excludes subheadings)."
  (let ((body (string-trim (or (org-get-entry) ""))))
    (when (> (length body) 0) body)))

(defun pod-emacs-org--entry (include-body)
  "Build an EDN node hash-table for the headline at point.
Returns (LEVEL . NODE)."
  (let* ((level (org-current-level))
         (title (pod-emacs-org--str (org-get-heading t t t t)))
         (todo  (pod-emacs-org--str (org-get-todo-state)))
         (prio  (nth 3 (org-heading-components)))
         (tags  (mapcar #'pod-emacs-org--str (org-get-tags nil t)))
         (props (pod-emacs-org--props))
         (sched (pod-emacs-org--str (org-entry-get nil "SCHEDULED")))
         (dead  (pod-emacs-org--str (org-entry-get nil "DEADLINE")))
         (node  (pod-emacs--ht :level level :title (or title ""))))
    (when todo  (puthash :todo todo node))
    (when prio  (puthash :priority (char-to-string prio) node))
    (when tags  (puthash :tags (vconcat tags) node))
    (when props (puthash :properties props node))
    (when sched (puthash :scheduled sched node))
    (when dead  (puthash :deadline dead node))
    (puthash :begin (point) node)
    (when include-body
      (when-let* ((b (pod-emacs-org--body))) (puthash :body b node)))
    (cons level node)))

(defun pod-emacs-org--collect (include-body max-level)
  "Collect (LEVEL . NODE) pairs for all headlines, in document order."
  (delq nil
        (org-map-entries
         (lambda ()
           (when (or (null max-level) (<= (org-current-level) max-level))
             (pod-emacs-org--entry include-body))))))

(defun pod-emacs-org--nest (flat)
  "Turn FLAT list of (LEVEL . NODE) into a nested list of root nodes.
Children are appended under :children only when present (leaves omit the key)."
  (let ((roots '()) (stack '()))
    (dolist (item flat)
      (let ((level (car item)) (node (cdr item)))
        (while (and stack (>= (caar stack) level))
          (pop stack))
        (if stack
            (let ((parent (cdar stack)))
              (puthash :children
                       (append (gethash :children parent) (list node))
                       parent))
          (push node roots))
        (push (cons level node) stack)))
    (nreverse roots)))

(defun pod-emacs-org--opt (opts key)
  "Look up KEY in OPTS, which may be a hash-table (from parseedn) or nil."
  (when (hash-table-p opts) (gethash key opts)))

(defun pod-emacs-org--file-keyword (kw)
  "Return the value of buffer keyword KW (e.g. \"TITLE\"), or nil."
  (cadr (assoc-string kw (org-collect-keywords (list kw)) t)))

;;;; ----------------------------------------------------------- public vars

(defun pod-emacs-org-outline (path &optional opts)
  "Read org file PATH; return {:file :title :children [..]} as nested EDN."
  (pod-emacs-org--with-file path
    (let* ((max-level (pod-emacs-org--opt opts :max-level))
           (flat (pod-emacs-org--collect nil max-level))
           (roots (pod-emacs-org--nest flat)))
      (pod-emacs--ht :file (expand-file-name path)
                     :title (pod-emacs-org--file-keyword "TITLE")
                     :children roots))))

(defun pod-emacs-org-to-edn (path &optional opts)
  "Like `pod-emacs-org-outline' but also include each entry's :body text."
  (pod-emacs-org--with-file path
    (let* ((max-level (pod-emacs-org--opt opts :max-level))
           (flat (pod-emacs-org--collect t max-level))
           (roots (pod-emacs-org--nest flat)))
      (pod-emacs--ht :file (expand-file-name path)
                     :title (pod-emacs-org--file-keyword "TITLE")
                     :children roots))))

(defun pod-emacs-org-headlines (path &optional opts)
  "Read org file PATH; return a flat vector of headline nodes (document order)."
  (pod-emacs-org--with-file path
    (let* ((max-level (pod-emacs-org--opt opts :max-level))
           (flat (pod-emacs-org--collect nil max-level)))
      (vconcat (mapcar #'cdr flat)))))

(provide 'pod-emacs-org)
;;; pod-emacs-org.el ends here
