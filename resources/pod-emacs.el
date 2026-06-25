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

;;;; ---------------------------------------------------------------- registry

;; Feature modules (pod-emacs-org, and any pod-emacs-* you add later) register
;; themselves here instead of being hard-wired into describe/dispatch.  Core
;; knows nothing of their internals; the dependency runs one way (modules
;; require core).  Modules load *lazily*: a feature's namespace is advertised
;; as deferred in `describe', and the module is `require'd only when the
;; babashka client first requires that namespace (a `load-ns' op).

(defvar pod-emacs--namespaces nil
  "Registered namespaces, an alist (NS-NAME . VARS).
NS-NAME is the fully-qualified namespace string; VARS is an alist of
\(VAR-NAME . HANDLER), where HANDLER is applied to the invoke args.")

(defvar pod-emacs--deferred
  '(("pod.babashka.emacs.org" . pod-emacs-org)
    ("pod.babashka.emacs.calc" . pod-emacs-calc)
    ("pod.babashka.emacs.project" . pod-emacs-project)
    ("pod.babashka.emacs.devops" .
     (pod-emacs-devops . (:use-package devops
				       :ensure t
				       :vc (:url "https://github.com/kpassapk/devops.el"))))
    ("pod.babashka.emacs.org-roam" .
     (pod-emacs-org-roam . (:use-package org-roam :ensure t))))
  "Alist of clojure namespace (string) -> deferred elisp feature SPEC.
On the first `load-ns' for a namespace its SPEC is resolved, the feature
`require'd, and the module is expected to `pod-emacs-register' as it loads.
Loading is lazy: nothing here runs at startup, so scripts that never require
a deferred namespace never pay for it.  SPEC is one of:

  FEATURE                      a feature symbol, just `require'd.
  (FEATURE . (:use-package . DECL))
                               `package-initialize', then evaluate
                               (use-package . DECL) to install/load the
                               package, *before* `require'ing FEATURE.

To add a feature, drop a `pod-emacs-FOO.el' on the load path and add an entry
here.  This is the only place core learns a feature exists — no filesystem
scanning, no environment variables.")

(defun pod-emacs-register (ns vars)
  "Register namespace NS (string) exposing VARS.
VARS is an alist of (VAR-NAME . HANDLER); HANDLER is `apply'd to the
decoded invoke args.  Re-registering NS replaces its previous vars."
  (setf (alist-get ns pod-emacs--namespaces nil nil #'equal) vars))

;;;; ---------------------------------------------------------------- describe

(defun pod-emacs--var (name &rest kvs)
  "A describe var entry named NAME, with optional extra string-keyed KVS."
  (apply #'pod-emacs--ht "name" name kvs))

(defun pod-emacs--describe-reply ()
  "Build the describe reply hash-table.
Eagerly-registered namespaces (core) ship their vars; each not-yet-loaded
entry in `pod-emacs--deferred' ships as a `defer' stub, so the client loads
it — and its elisp module — on first `require' via a `load-ns' op."
  (let* ((loaded (mapcar #'car pod-emacs--namespaces))
         (eager (mapcar (lambda (ns)
                          (pod-emacs--ht
                           "name" (car ns)
                           "vars" (mapcar (lambda (v) (pod-emacs--var (car v)))
                                          (cdr ns))))
                        (reverse pod-emacs--namespaces)))
         (deferred (delq nil
                         (mapcar (lambda (d)
                                   (unless (member (car d) loaded)
                                     (pod-emacs--ht "name" (car d)
                                                    "defer" "true")))
                                 pod-emacs--deferred))))
    (pod-emacs--ht
     "format" "edn"
     "namespaces" (append eager deferred)
     "ops" (pod-emacs--ht "shutdown" (make-hash-table :test 'equal)
                          "load-ns" (make-hash-table :test 'equal)))))

(defun pod-emacs--prepare-config (config)
  "Run a deferred namespace's CONFIG before its feature is `require'd.
CONFIG is the cdr of a `pod-emacs--deferred' cons SPEC; its head keyword
selects an action.  Only `:use-package' is supported: `package-initialize',
then evaluate the `(use-package PKG ...)' declaration spliced from the rest of
CONFIG, so the external package is installed/loaded before the `pod-emacs-FOO'
module requires it."
  (pcase config
    (`(:use-package . ,decl)
     (require 'package)
     (package-initialize)
     (require 'use-package)
     (eval `(use-package ,@decl) t))
    (_ (error "Unsupported deferred config: %S" config))))

(defun pod-emacs--load-ns (ns id)
  "Handle a `load-ns' request for namespace NS, replying to request ID.
Resolve the SPEC mapped in `pod-emacs--deferred', run any `:use-package'
config, `require' the feature (which registers NS), then send back its vars.
On failure reply with an error status so the client's `require' throws cleanly."
  (condition-case err
      (let* ((spec (alist-get ns pod-emacs--deferred nil nil #'equal))
             (feature (if (consp spec) (car spec) spec)))
        (unless spec (error "No such deferred namespace: %s" ns))
        (when (consp spec) (pod-emacs--prepare-config (cdr spec)))
        (require feature)
        (let ((vars (alist-get ns pod-emacs--namespaces nil nil #'equal)))
          (unless vars (error "Namespace %s registered no vars on load" ns))
          (pod-emacs--send
           (pod-emacs--ht
            "name" ns
            "vars" (mapcar (lambda (v) (pod-emacs--var (car v))) vars)
            "id" id))))
    (error
     (pod-emacs--send
      (pod-emacs--ht
       "id" id
       "ex-message" (error-message-string err)
       "ex-data" (pod-emacs--encode-edn
                  (pod-emacs--ht :type (symbol-name (car err)) :ns ns))
       "status" (list "done" "error"))))))

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

(defun pod-emacs--funcall (f &rest args)
  "Call the elisp function named F with ARGS (already EDN-decoded values).
ARGS are real data, so nothing is string-spliced into elisp."
  (unless f (error "funcall: missing function name"))
  (apply (if (symbolp f) f (intern f)) args))

(defun pod-emacs--version ()
  "Build the version reply hash-table."
  (pod-emacs--ht :emacs-version emacs-version
                 :major-version emacs-major-version
                 :exec (or (car command-line-args) "emacs")))

;; Core's own namespace, registered like any feature module.
(pod-emacs-register
 "pod.babashka.emacs"
 `(("eval"      . ,#'pod-emacs--eval-string)
   ("eval-file" . ,(lambda (path)
                     (load (expand-file-name path) nil t t)
                     (file-name-nondirectory path)))
   ("funcall"   . ,#'pod-emacs--funcall)
   ("version"   . ,#'pod-emacs--version)))

(defun pod-emacs--dispatch (var args)
  "Run pod VAR (a fully-qualified \"ns/name\" string) with ARGS (a list)."
  (let* ((slash (string-search "/" var))
         (ns    (and slash (substring var 0 slash)))
         (name  (and slash (substring var (1+ slash))))
         (handler (alist-get name
                             (alist-get ns pod-emacs--namespaces nil nil #'equal)
                             nil nil #'equal)))
    (if handler
        (apply handler args)
      (error "Unknown pod var: %s" var))))

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
     ((equal op "load-ns")
      (pod-emacs--load-ns (gethash "ns" msg) id) nil)
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
  "Run the pod protocol loop over base64-framed stdin/stdout.
Only core is loaded at startup; feature modules load lazily on `load-ns'."
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
