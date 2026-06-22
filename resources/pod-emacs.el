;;; pod-emacs.el --- Emacs Lisp brain for pod-babashka-emacs -*- lexical-binding: t; -*-

;; This runs inside `emacs --batch'.  It is the protocol brain of the pod:
;; it speaks the babashka pod protocol (bencode framing, EDN payloads) with a
;; thin babashka shim sitting between it and babashka itself.
;;
;; Transport (see docs/adr/0001-transport-architecture.md): the shim owns the
;; babashka-facing stdio and transcodes the raw bencode byte stream to/from
;; *base64 lines*, because `emacs --batch' can only read newline-delimited
;; stdin (read-string) but not arbitrary raw bytes.  So here:
;;
;;   in:  read-string -> base64-decode -> accumulate bytes -> bencode-decode
;;   out: bencode-encode -> base64-encode -> send-string-to-terminal + "\n"
;;
;; `send-string-to-terminal' is used (not `princ') because batch stdout is
;; block-buffered for pipes; send-string-to-terminal flushes immediately.

;;; Code:

(require 'bencode)
(require 'parseedn)
(require 'cl-lib)
(require 'pod-emacs-util)
(require 'pod-emacs-org)

(defvar pod-emacs--in-buffer-name " *pod-emacs-in*"
  "Name of the unibyte buffer accumulating raw bencode bytes from stdin.")

;;;; ---------------------------------------------------------------- helpers

(defun pod-emacs--send (ht)
  "Bencode-encode reply HT, base64 it, and write one line to stdout."
  (let* ((enc (bencode-encode ht))             ; unibyte string
         (b64 (base64-encode-string enc t)))    ; t = no line breaks
    ;; send-string-to-terminal flushes; chunk very large payloads to be safe.
    (let ((i 0) (n (length b64)) (chunk 65536))
      (while (< i n)
        (send-string-to-terminal (substring b64 i (min n (+ i chunk))))
        (setq i (+ i chunk))))
    (send-string-to-terminal "\n")))

;;;; ---------------------------------------------------------------- describe

(defun pod-emacs--var (name &rest kvs)
  "A describe var entry named NAME, with optional extra string-keyed KVS."
  (apply #'pod-emacs--ht "name" name kvs))

(defun pod-emacs--describe-reply ()
  "Build the describe reply hash-table."
  (pod-emacs--ht
   "format" "edn"
   "namespaces"
   (list
    (pod-emacs--ht
     "name" "pod.babashka.emacs"
     "vars" (list (pod-emacs--var "eval")
                  (pod-emacs--var "eval-file")
                  (pod-emacs--var "version")))
    (pod-emacs--ht
     "name" "pod.babashka.emacs.org"
     "vars" (list (pod-emacs--var "outline")
                  (pod-emacs--var "headlines")
                  (pod-emacs--var "to-edn")
                  (pod-emacs--var "execute"))))
   "ops" (pod-emacs--ht "shutdown" (make-hash-table :test 'equal))))

;;;; ---------------------------------------------------------------- eval

(defun pod-emacs--eval-string (code)
  "Read and evaluate all top-level forms in CODE, returning the last value."
  (let ((forms nil) (pos 0) (len (length code)))
    (condition-case _
        (while (< pos len)
          (let ((res (read-from-string code pos)))
            (push (car res) forms)
            (setq pos (cdr res))))
      (end-of-file nil))
    (if forms
        (eval (cons 'progn (nreverse forms)) t)
      nil)))

(defun pod-emacs--dispatch (var args)
  "Run pod VAR (a fully-qualified string) with ARGS (a list)."
  (cond
   ((equal var "pod.babashka.emacs/eval")
    (pod-emacs--eval-string (nth 0 args)))
   ((equal var "pod.babashka.emacs/eval-file")
    (load (expand-file-name (nth 0 args)) nil t t)
    (file-name-nondirectory (nth 0 args)))
   ((equal var "pod.babashka.emacs/version")
    (pod-emacs--ht :emacs-version emacs-version
                   :major-version emacs-major-version
                   :exec (or (car command-line-args) "emacs")))
   ((equal var "pod.babashka.emacs.org/outline")
    (pod-emacs-org-outline (nth 0 args) (nth 1 args)))
   ((equal var "pod.babashka.emacs.org/headlines")
    (pod-emacs-org-headlines (nth 0 args) (nth 1 args)))
   ((equal var "pod.babashka.emacs.org/to-edn")
    (pod-emacs-org-to-edn (nth 0 args)))
   ((equal var "pod.babashka.emacs.org/execute")
    (pod-emacs-org-execute (nth 0 args) (nth 1 args)))
   (t (error "Unknown pod var: %s" var))))

;;;; ---------------------------------------------------------------- dispatch

(defun pod-emacs--invoke (msg id)
  "Handle an invoke MSG with request ID."
  (let* ((var (gethash "var" msg))
         (args-edn (gethash "args" msg))
         (args (when (and args-edn (> (length args-edn) 0))
                 (append (parseedn-read-str args-edn) nil))))
    (condition-case err
        (let ((result (pod-emacs--dispatch var args)))
          (pod-emacs--send
           (pod-emacs--ht "id" id
                          "value" (pod-emacs--encode-edn result)
                          "status" (list "done"))))
      (error
       (pod-emacs--send
        (pod-emacs--ht
         "id" id
         "ex-message" (error-message-string err)
         "ex-data" (pod-emacs--encode-edn
                    (pod-emacs--ht :type (symbol-name (car err))
                                   :var (or var :unknown)))
         "status" (list "done" "error")))))))

(defun pod-emacs--handle (msg)
  "Dispatch a decoded protocol MSG. Return :shutdown to stop the loop."
  (let ((op (gethash "op" msg))
        (id (gethash "id" msg)))
    (cond
     ((equal op "describe")
      (pod-emacs--send (pod-emacs--describe-reply)) nil)
     ((equal op "invoke")
      (pod-emacs--invoke msg id) nil)
     ((equal op "shutdown")
      (pod-emacs--send (pod-emacs--ht "id" id "status" (list "done")))
      :shutdown)
     (t
      (when id
        (pod-emacs--send
         (pod-emacs--ht "id" id
                        "ex-message" (format "Unknown op: %s" op)
                        "status" (list "done" "error"))))
      nil))))

;;;; ---------------------------------------------------------------- main loop

(defun pod-emacs--drain ()
  "Process all complete bencode messages buffered in the current buffer.
Return nil to request shutdown, t to keep running."
  (let ((keep t) (more t))
    (while (and more (> (buffer-size) 0))
      (goto-char (point-min))
      (condition-case _
          (let ((msg (bencode-decode-from-buffer :dict-type 'hash-table
                                                 :list-type 'list)))
            (delete-region (point-min) (point))
            (when (eq (pod-emacs--handle msg) :shutdown)
              (setq keep nil more nil)))
        (bencode-end-of-file
         ;; partial message: wait for more bytes from stdin
         (setq more nil))))
    keep))

(defun pod-emacs-main ()
  "Run the pod protocol loop over base64-framed stdin/stdout."
  (set-binary-mode 'stdin t)
  (let ((buf (get-buffer-create pod-emacs--in-buffer-name)))
    (with-current-buffer buf
      (set-buffer-multibyte nil)
      (let ((line nil) (running t))
        (while (and running
                    (setq line (condition-case _
                                   (read-string "")
                                 ((end-of-file error) nil))))
          (when (> (length line) 0)
            (goto-char (point-max))
            (insert (base64-decode-string line)))
          (setq running (pod-emacs--drain))))))
  (kill-emacs 0))

(provide 'pod-emacs)
;;; pod-emacs.el ends here
