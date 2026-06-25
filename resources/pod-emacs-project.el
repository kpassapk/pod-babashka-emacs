;;; pod-emacs-project.el --- project.el -> EDN for pod-babashka-emacs -*- lexical-binding: t; -*-
;;; Commentary:
;; Bridge Emacs' built-in `project' library into the pod.  A babashka driver
;; points it at a directory and gets the project's root and tracked-file list
;; back as data, using the same VC-aware detection Emacs uses interactively.
;;
;;   pod.babashka.emacs.project/root   (PATH)                -> root dir string
;;   pod.babashka.emacs.project/files  (PATH &optional OPTS) -> vector of paths
;;
;; PATH is any path inside the project (a file or directory).  Detection uses
;; `project-current', whose default backend walks up to the enclosing VC root,
;; so this works in any git/hg/etc. checkout under `emacs --batch -Q'.
;;
;; `files' OPTS is an EDN map; recognized keys:
;;   :relative  <bool>  return paths relative to the project root, not absolute
;;; Code:

(require 'project)
(require 'pod-emacs)
(require 'pod-emacs-util)

(defun pod-emacs-project--opt (opts key)
  "Look up KEY in OPTS, which may be a hash-table (from parseedn) or nil."
  (when (hash-table-p opts) (gethash key opts)))

(defun pod-emacs-project--current (path)
  "Return the project enclosing PATH, or signal if none is found.
PATH may be a file or directory; a directory should be passed as-is."
  (let* ((dir (file-name-as-directory
               (expand-file-name (or path default-directory))))
         (proj (project-current nil dir)))
    (unless proj (error "No project found at: %s" (or path default-directory)))
    proj))

(defun pod-emacs-project-root (path)
  "Return the root directory of the project enclosing PATH, as an absolute path."
  (expand-file-name (project-root (pod-emacs-project--current path))))

(defun pod-emacs-project-files (path &optional opts)
  "Return the files tracked in the project enclosing PATH as a vector.
With OPTS :relative non-nil the paths are made relative to the project root;
otherwise they are absolute."
  (let* ((proj (pod-emacs-project--current path))
         (root (expand-file-name (project-root proj)))
         (rel  (pod-emacs-project--opt opts :relative)))
    (vconcat (mapcar (lambda (f)
                       (if rel (file-relative-name f root) f))
                     (project-files proj)))))

;;;; ----------------------------------------------------------- registration

(pod-emacs-register
 "pod.babashka.emacs.project"
 `(("root"  . ,#'pod-emacs-project-root)
   ("files" . ,#'pod-emacs-project-files)))

(provide 'pod-emacs-project)
;;; pod-emacs-project.el ends here
