;;; pod-emacs-devops.el --- devops.el -> EDN for pod-babashka-emacs -*- lexical-binding: t; -*-
;;; Commentary:
;; Bridge the `devops' package (org-babel tangle/execute to remote TRAMP
;; targets) into the pod.  devops' commands are interactive and operate on the
;; current org buffer at point; here we drive its noninteractive engine over a
;; file passed from babashka.
;;
;;   pod.babashka.emacs.devops/tangle   (OPTS)  -> [{:tag :target :files}]
;;   pod.babashka.emacs.devops/execute  (OPTS)  -> <block result>
;;
;; OPTS is an EDN map.  `tangle' recognizes:
;;   :file       <string>  path to the org file (required)
;;   :heading    <string>  exact headline title to tangle
;;   :custom-id  <string>  CUSTOM_ID property of the heading to tangle
;;   :all        <bool>    tangle every target-tagged heading instead
;;
;; `execute' recognizes:
;;   :file     <string>  path to the org file (required)
;;   :name     <string>  run the block whose `#+name:' matches
;;   :index    <int>     run the Nth src block, 0-based, in document order
;;
;; A block's enclosing heading target tag is resolved to a :dir and injected
;; into its babel params by `devops''s advice, so the block runs on its target.
;;; Code:

(require 'org)
(require 'devops)
(require 'pod-emacs)
(require 'pod-emacs-org)
(require 'pod-emacs-util)

(defmacro pod-emacs-devops--with-file (path &rest body)
  "Open org file PATH in a temp org-mode buffer and run BODY.
`default-directory' is set to the file's directory so relative :tangle
paths resolve as they would when the file is visited."
  (declare (indent 1))
  `(let ((p (expand-file-name ,path)))
     (unless (file-readable-p p)
       (error "Cannot read org file: %s" p))
     (with-temp-buffer
       (insert-file-contents p)
       (setq default-directory (or (file-name-directory p) default-directory))
       (let ((org-inhibit-startup t)
             (org-element-use-cache nil)
             (org-mode-hook nil))
         (delay-mode-hooks (org-mode)))
       ,@body)))

(defun pod-emacs-devops--opt (opts key)
  "Look up KEY in OPTS, which may be a hash-table (from parseedn) or nil."
  (when (hash-table-p opts) (gethash key opts)))

(defun pod-emacs-devops--results->edn (results)
  "Turn RESULTS, a list of (TAG TARGET N), into a list of EDN maps."
  (mapcar (lambda (r)
            (pod-emacs--ht :tag    (nth 0 r)
                           :target (nth 1 r)
                           :files  (nth 2 r)))
          results))

(defun pod-emacs-devops-tangle (&optional opts)
  "Tangle an org file's source blocks to their devops TRAMP target(s).
OPTS is an EDN map (see commentary).  Returns a list of {:tag :target :files}.
Pass :heading or :custom-id to tangle one headline, or :all to tangle every
target-tagged headline in the file."
  (let ((file      (pod-emacs-devops--opt opts :file))
        (heading   (pod-emacs-devops--opt opts :heading))
        (custom-id (pod-emacs-devops--opt opts :custom-id))
        (all       (pod-emacs-devops--opt opts :all)))
    (unless file (error "tangle: missing :file"))
    (pod-emacs-devops--with-file file
      (let ((org-confirm-babel-evaluate nil))
        (pod-emacs-devops--results->edn
         (cond
          (all       (devops-tangle-all (current-buffer)))
          (custom-id (devops-tangle-custom-id (current-buffer) custom-id))
          (heading   (devops-tangle-headline (current-buffer) heading))
          (t (error "tangle: pass :heading, :custom-id or :all"))))))))

(defun pod-emacs-devops-execute (&optional opts)
  "Execute a source block in an org file against its devops target.
OPTS is an EDN map (see commentary).  Selects a block with :name or :index;
with neither, the file must hold exactly one block.  The block's enclosing
heading target tag resolves to a :dir, injected into the block's babel params
by `devops''s `org-babel-execute-src-block' advice, so the block runs on its
remote/local target.  Returns the block's result."
  (let ((file (pod-emacs-devops--opt opts :file)))
    (unless file (error "execute: missing :file"))
    (pod-emacs-devops--with-file file
      (let ((org-confirm-babel-evaluate nil))
        (pod-emacs-org--goto-block file opts)
        (pod-emacs-org--require-lang (car (org-babel-get-src-block-info t)))
        (org-babel-execute-src-block)))))

;;;; ----------------------------------------------------------- registration

(pod-emacs-register
 "pod.babashka.emacs.devops"
 `(("tangle"  . ,#'pod-emacs-devops-tangle)
   ("execute" . ,#'pod-emacs-devops-execute)))

(provide 'pod-emacs-devops)
;;; pod-emacs-devops.el ends here
