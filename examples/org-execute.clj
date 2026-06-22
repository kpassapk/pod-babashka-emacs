#!/usr/bin/env bb
;; Treat an org file as an executable *runbook*: each named src block is a
;; step. babashka runs the steps by name through the pod and works with the
;; captured output as ordinary Clojure data.
;;
;;   bb examples/org-execute.clj [path/to/runbook.org]
;;
;; org-mode owns the literate document and the babel machinery; babashka owns
;; the orchestration and whatever you do with the results.

(require '[babashka.pods :as pods]
         '[clojure.java.io :as io])

(def here (-> *file* io/file .getCanonicalFile .getParentFile))
(def pod  (.getPath (io/file here ".." "pod-babashka-emacs")))
(def org-file (or (first *command-line-args*)
                  (.getPath (io/file here "runbook.org"))))

(pods/load-pod [pod])
(require '[pod.babashka.emacs.org :as org])

(defn run-step
  "Run the block named NAME; return {:step :result} or {:step :error}."
  [name]
  (print (format "  %-8s … " name)) (flush)
  (try
    (let [r (org/execute org-file {:name name})]
      (println (pr-str r))
      {:step name :result r})
    (catch Exception e
      (println "ERROR:" (ex-message e))
      {:step name :error (ex-message e)})))

(println "Runbook:" org-file \newline)

;; Steps run in the order *we* choose — the driver is in charge, not the file.
(def steps   ["env" "build" "size" "summary"])
(def results (mapv run-step steps))

;; Pure-Clojure handling of what the blocks produced:
(let [ok (remove :error results)]
  (println (format "%n%d/%d steps ok" (count ok) (count steps)))
  (when-let [size (some #(when (= "size" (:step %)) (:result %)) results)]
    (println "artifact name length:" size "bytes")))

;; Blocks can also be selected positionally — first src block, no name needed:
(println "\nfirst block by index:" (pr-str (org/execute org-file {:index 0})))
