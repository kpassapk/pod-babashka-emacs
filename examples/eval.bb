#!/usr/bin/env bb

(require '[babashka.pods :as pods]
         '[clojure.java.io :as io])

;; Loading emacs packages is deferred, so startup time is fast:
;;
;; $ time bb eval.bb
;; 2
;; ________________________________________________________
;; Executed in  474.89 millis    fish           external
;;    usr time  200.81 millis    0.75 millis  200.06 millis
;;    sys time   56.19 millis    1.89 millis   54.30 millis

(def here (-> *file* io/file .getCanonicalFile .getParentFile))
(def pod  (.getPath (io/file here ".." "pod-babashka-emacs")))

(pods/load-pod [pod])
(require '[pod.babashka.emacs :as emacs])

(prn (emacs/eval "(+ 1 1)"))
