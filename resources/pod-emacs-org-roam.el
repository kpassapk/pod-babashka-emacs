;;; pod-emacs-org-roam.el --- org-roam -> EDN for pod-babashka-emacs -*- lexical-binding: t; -*-
;;; Commentary:
;; Bridge the `org-roam' knowledge-graph package into the pod, so a babashka
;; driver can read a Zettelkasten as Clojure data: the nodes in a roam
;; directory and the backlinks pointing at any one of them.
;;
;;   pod.babashka.emacs.org-roam/nodes      (&optional OPTS) -> vector of nodes
;;   pod.babashka.emacs.org-roam/backlinks  (OPTS)           -> vector of links
;;
;; OPTS is an EDN map.  Both vars accept:
;;   :directory  <string>  the org-roam directory to read (defaults to the
;;                         configured `org-roam-directory')
;; `backlinks' additionally requires:
;;   :id         <string>  the node id whose backlinks to return
;;
;; Each `nodes' element is {:id :title :file :level :tags}.  Each `backlinks'
;; element is {:source-id :source-title :point}, describing one reference.
;;
;; org-roam keeps its index in a SQLite db; we `org-roam-db-sync' on each call
;; so the data reflects the directory's current contents in this batch run.
;;; Code:

(require 'org)
(require 'org-roam)
(require 'pod-emacs)
(require 'pod-emacs-util)

(defun pod-emacs-org-roam--opt (opts key)
  "Look up KEY in OPTS, which may be a hash-table (from parseedn) or nil."
  (when (hash-table-p opts) (gethash key opts)))

(defun pod-emacs-org-roam--sync (directory)
  "Point org-roam at DIRECTORY and (re)build its database for this batch run.
File watchers make no sense in `emacs --batch', so autosync is disabled and the
db is synced synchronously instead.  DIRECTORY defaults to `org-roam-directory'."
  (let ((dir (expand-file-name (or directory org-roam-directory))))
    (unless (file-directory-p dir)
      (error "org-roam directory does not exist: %s" dir))
    (setq org-roam-directory dir)
    (ignore-errors (org-roam-db-autosync-mode -1))
    (org-roam-db-sync)
    dir))

(defun pod-emacs-org-roam--node->edn (node)
  "Build an EDN hash-table {:id :title :file :level :tags} for org-roam NODE."
  (pod-emacs--ht
   :id    (org-roam-node-id node)
   :title (org-roam-node-title node)
   :file  (org-roam-node-file node)
   :level (org-roam-node-level node)
   :tags  (vconcat (org-roam-node-tags node))))

(defun pod-emacs-org-roam-nodes (&optional opts)
  "Return every node in the org-roam directory as a vector of EDN maps.
OPTS :directory selects the directory (default `org-roam-directory')."
  (pod-emacs-org-roam--sync (pod-emacs-org-roam--opt opts :directory))
  (vconcat (mapcar #'pod-emacs-org-roam--node->edn (org-roam-node-list))))

(defun pod-emacs-org-roam-backlinks (opts)
  "Return the backlinks pointing at the node whose id is OPTS :id.
OPTS :directory selects the directory (default `org-roam-directory').  Each
element is {:source-id :source-title :point} for one referencing location."
  (let ((id (pod-emacs-org-roam--opt opts :id)))
    (unless id (error "backlinks: missing :id"))
    (pod-emacs-org-roam--sync (pod-emacs-org-roam--opt opts :directory))
    (let ((node (org-roam-node-from-id id)))
      (unless node (error "No org-roam node with id: %s" id))
      (vconcat
       (mapcar (lambda (bl)
                 (let ((src (org-roam-backlink-source-node bl)))
                   (pod-emacs--ht
                    :source-id    (org-roam-node-id src)
                    :source-title (org-roam-node-title src)
                    :point        (org-roam-backlink-point bl))))
               (org-roam-backlinks-get node))))))

;;;; ----------------------------------------------------------- registration

(pod-emacs-register
 "pod.babashka.emacs.org-roam"
 `(("nodes"     . ,#'pod-emacs-org-roam-nodes)
   ("backlinks" . ,#'pod-emacs-org-roam-backlinks)))

(provide 'pod-emacs-org-roam)
;;; pod-emacs-org-roam.el ends here
