;;; pod-emacs-util.el --- shared helpers for pod-babashka-emacs -*- lexical-binding: t; -*-
;;; Commentary:
;; Small helpers shared by the protocol brain (pod-emacs) and feature modules
;; (pod-emacs-org).  Kept separate to avoid a circular require.
;;; Code:

(require 'parseedn)

(defun pod-emacs--ht (&rest pairs)
  "Build an `equal' hash-table from PAIRS (k1 v1 k2 v2 ...).
String keys -> bencode dict keys; keyword keys -> EDN map keys via parseedn."
  (let ((h (make-hash-table :test 'equal :size (max 1 (/ (length pairs) 2)))))
    (while pairs
      (puthash (car pairs) (cadr pairs) h)
      (setq pairs (cddr pairs)))
    h))

(defun pod-emacs--encode-edn (val)
  "Encode elisp VAL as an EDN string, falling back to a string repr."
  (condition-case _
      (parseedn-print-str val)
    (error (parseedn-print-str (format "%S" val)))))

(provide 'pod-emacs-util)
;;; pod-emacs-util.el ends here
