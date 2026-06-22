#!/usr/bin/env bb
;; A babashka driver reads an org file *through Emacs* and
;; works with the result as ordinary EDN/Clojure data.
;;
;;   bb examples/org-outline.clj [path/to/file.org]
;;
;; Emacs does what Emacs is good at (parsing org with the real org-mode);
;; babashka does the driving and data wrangling.

(require '[babashka.pods :as pods]
         '[clojure.java.io :as io]
         '[clojure.pprint :refer [pprint]])

(def here (-> *file* io/file .getCanonicalFile .getParentFile))
(def pod  (.getPath (io/file here ".." "pod-babashka-emacs")))
(def org-file (or (first *command-line-args*)
                  (.getPath (io/file here "sample.org"))))

(pods/load-pod [pod])
(require '[pod.babashka.emacs :as emacs]
         '[pod.babashka.emacs.org :as org])

(let [{:keys [title children] :as outline} (org/outline org-file)]
  (println "Title:" title)
  (println "\nOutline:")
  (letfn [(walk [node depth]
            (println (str (apply str (repeat depth "  "))
                          "- " (when (:todo node) (str (:todo node) " "))
                          (:title node)
                          (when (seq (:tags node)) (str "  " (vec (:tags node))))))
            (doseq [c (:children node)] (walk c (inc depth))))]
    (doseq [c children] (walk c 0)))

  ;; Pure-Clojure analysis over the EDN the pod returned:
  (let [flat (tree-seq :children :children {:children children})
        todos (filter #(= "TODO" (:todo %)) flat)]
    (println "\nOpen TODOs:" (count todos))
    (doseq [t todos]
      (println (str "  - " (:title t)
                    (when (:deadline t) (str " (deadline " (:deadline t) ")"))
                    (when (:scheduled t) (str " (scheduled " (:scheduled t) ")"))))))

  ;; You can also drop into raw elisp whenever you want:
  (println "\nemacs-version:" (:emacs-version (emacs/version)))
  (println "uppercased via elisp:" (emacs/eval "(upcase \"done\")")))
