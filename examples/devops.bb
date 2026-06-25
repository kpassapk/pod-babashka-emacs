#!/usr/bin/env bb

(require '[babashka.pods :as pods]
         '[clojure.java.io :as io])

(def here (-> *file* io/file .getCanonicalFile .getParentFile))
(def pod  (.getPath (io/file here ".." "pod-babashka-emacs")))
(def org-file (or (first *command-line-args*)
                  (.getPath (io/file here "devops.org"))))

(pods/load-pod [pod])

(require '[pod.babashka.emacs.devops :as devops])

;; Tangle a file

(prn (devops/tangle {:file org-file :custom-id "upload-file"}))

;; Execute a code block on the heading's target

(prn (devops/execute {:file org-file :name "disk-free"}))
