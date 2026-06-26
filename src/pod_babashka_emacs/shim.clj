(ns pod-babashka-emacs.shim
  "The pod executable. Owns babashka-facing stdio and transcodes the raw bencode
  byte stream to/from base64 lines for an `emacs --batch' child.

  See doc/adr/0001-transport-architecture.md."
  (:require [babashka.fs :as fs]
            [babashka.process :as p]
            [pod-babashka-emacs.emacs :as emacs])
  (:import [java.io InputStream OutputStream BufferedReader InputStreamReader
            FileOutputStream]
           [java.nio.charset StandardCharsets]
           [java.util Base64 Arrays])
  (:refer-clojure :exclude [dec]))

(def ^:private enc (Base64/getEncoder))   ; no line breaks
(def ^:private dec (Base64/getDecoder))

(defn- pump-in!
  "babashka stdin -> base64 lines -> emacs stdin.
  Reads raw bytes, base64-encodes each chunk, writes one line per chunk."
  [^InputStream babashka-in ^OutputStream emacs-in]
  (let [buf (byte-array 65536)]
    (try
      (loop []
        (let [n (.read babashka-in buf)]
          (if (neg? n)
            (.close emacs-in)                       ; EOF -> let emacs finish
            (let [line (.encodeToString enc (Arrays/copyOfRange buf 0 n))]
              (.write emacs-in (.getBytes line StandardCharsets/US_ASCII))
              (.write emacs-in (int \newline))
              (.flush emacs-in)
              (recur)))))
      (catch Exception e
        (emacs/log "pump-in error:" (.getMessage e))
        (try (.close emacs-in) (catch Exception _))))))

(defn- pump-out!
  "emacs stdout (base64 lines) -> raw bytes -> babashka stdout."
  [^BufferedReader emacs-out ^OutputStream babashka-out]
  (loop []
    (when-let [line (.readLine emacs-out)]
      (when (pos? (.length line))
        (let [bytes (.decode dec line)]
          (.write babashka-out bytes)
          (.flush babashka-out)))
      (recur))))

(defn run
  "Resolve Emacs, launch the brain, and transcode until either side ends.
  ROOT is the pod's install directory (holds resources/ and vendor/)."
  [root]
  (let [root      (fs/file root)
        vendor    (str (fs/file root "vendor"))
        resources (str (fs/file root "resources"))
        emacs-bin (emacs/resolve-emacs)
        logfile   (fs/file (emacs/cache-dir) "emacs.log")]
    (fs/create-dirs (emacs/cache-dir))
    (let [err-stream (FileOutputStream. (fs/file logfile))
          proc (p/process [emacs-bin "--batch" "-Q"
                           "--eval" (str "(setq byte-compile-warnings nil "
                                         "warning-minimum-level :emergency "
                                         "native-comp-jit-compilation nil "
                                         "native-comp-async-report-warnings-errors 'silent)")
                           "-L" vendor "-L" resources
                           "-l" "pod-emacs" "-f" "pod-emacs-main"]
                          {:in :stream :out :stream :err err-stream
                           :extra-env {"EMACS_INHIBIT_AUTOMATIC_NATIVE_COMPILATION" "1"}})
          emacs-in  ^OutputStream (:in proc)
          emacs-out (BufferedReader.
                     (InputStreamReader. ^InputStream (:out proc)
                                         StandardCharsets/US_ASCII))
          t-in (doto (Thread. #(pump-in! System/in emacs-in)) (.setDaemon true) (.start))]
      ;; pump emacs->babashka on the main thread; returns when emacs closes stdout
      (pump-out! emacs-out System/out)
      (.join t-in 200)
      (let [code (or (some-> ^Process (:proc proc) (.waitFor)) 0)]
        (System/exit code)))))
