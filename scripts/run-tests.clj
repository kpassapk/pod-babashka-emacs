#!/usr/bin/env bb
;; Test runner for pod-babashka-emacs.
;;
;;   bb scripts/run-tests.clj      (or: bb test)
;;
;; Requires the test namespace (which loads the pod once), runs all tests, and
;; exits non-zero if anything failed or errored.

(require '[clojure.test :as t])

;; Make sure test/ is on the classpath even when run as a bare script.
(let [here (-> *file* clojure.java.io/file .getCanonicalFile .getParentFile)
      root (.getParentFile here)
      test-dir (.getPath (clojure.java.io/file root "test"))]
  (babashka.classpath/add-classpath test-dir))

(require 'pod-babashka-emacs.pod-test)

(let [{:keys [fail error] :as summary} (t/run-tests 'pod-babashka-emacs.pod-test)]
  (shutdown-agents)
  (System/exit (if (pos? (+ (or fail 0) (or error 0))) 1 0)))
