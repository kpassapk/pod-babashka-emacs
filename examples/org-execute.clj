#!/usr/bin/env bb
;; An *interactive* runbook: treat an org file as a menu of executable steps.
;; Each named src block is a step; this TUI lists the blocks and lets you pick
;; one to run through the pod, then shows the captured result as Clojure data.
;;
;;   bb examples/org-execute.clj [path/to/runbook.org]
;;
;; org-mode owns the literate document and the babel machinery; babashka owns
;; the orchestration, the UI, and whatever you do with the results.  The TUI is
;; built on JLine, which ships *inside* babashka — no extra dependency.

(require '[babashka.pods :as pods]
         '[clojure.java.io :as io]
         '[clojure.string :as str])

(import '[org.jline.terminal TerminalBuilder]
        '[org.jline.utils NonBlockingReader])

(def here (-> *file* io/file .getCanonicalFile .getParentFile))
(def pod  (.getPath (io/file here ".." "pod-babashka-emacs")))
(def org-file (or (first *command-line-args*)
                  (.getPath (io/file here "runbook.org"))))

(pods/load-pod [pod])
(require '[pod.babashka.emacs :as emacs]
         '[pod.babashka.emacs.org :as org])

;;;; ---------------------------------------------------- read the menu via org

(defn src-blocks
  "Ask Emacs' real org-mode to list every src block in PATH, in document order.
  Returns a vector of {:index :name :lang}; :name is nil for unnamed blocks."
  [path]
  (let [elisp
        (str "(let ((p (expand-file-name " (pr-str path) ")))"
             "  (with-temp-buffer"
             "    (insert-file-contents p)"
             "    (let ((org-inhibit-startup t) (org-element-use-cache nil) (org-mode-hook nil))"
             "      (delay-mode-hooks (org-mode)))"
             "    (let (acc (i 0))"
             "      (org-babel-map-src-blocks nil"
             "        (let* ((info (org-babel-get-src-block-info t))"
             "               (lang (nth 0 info))"
             "               (name (nth 4 info)))"
             "          (push (pod-emacs--ht :index i"
             "                               :name (and name (> (length name) 0)"
             "                                          (substring-no-properties name))"
             "                               :lang lang) acc)"
             "          (setq i (1+ i))))"
             "      (vconcat (nreverse acc)))))")]
    (vec (emacs/eval elisp))))

(defn block-label [b]
  (or (:name b) (format "«block %d»" (:index b))))

(defn block-selector
  "How org/execute should address this block: by :name if it has one, else :index."
  [b]
  (if (:name b) {:name (:name b)} {:index (:index b)}))

;;;; ---------------------------------------------------------- terminal drawing

(def ESC "")
(defn- clear       [] (str ESC "[2J" ESC "[H"))
(defn- hide-cursor [] (str ESC "[?25l"))
(defn- show-cursor [] (str ESC "[?25h"))

(defn render
  "Build the full-screen menu as a string (raw mode -> explicit CR+LF)."
  [blocks idx]
  (str (clear) (hide-cursor)
       "Runbook: " org-file "\r\n"
       "Pick a src block to run.  ↑/↓ or j/k to move, Enter to run, q to quit.\r\n\r\n"
       (str/join "\r\n"
                 (map-indexed
                  (fn [i b]
                    (let [row (format "%-16s [%s]" (block-label b) (:lang b))]
                      (if (= i idx)
                        (str ESC "[7m> " row ESC "[0m")   ; reverse-video cursor row
                        (str "  " row))))
                  blocks))
       "\r\n"))

(defn read-key
  "Block for one keystroke; decode arrow escapes and control keys to keywords."
  [^NonBlockingReader r]
  (let [c (.read r)]
    (cond
      (= c 27) (let [c2 (.read r 50)]                ; ESC: maybe an arrow sequence
                 (if (= c2 (int \[))
                   (case (char (.read r 50))
                     \A :up \B :down \C :right \D :left :other)
                   :esc))
      (or (= c 13) (= c 10)) :enter
      (or (= c 3) (= c 4))   :quit                   ; Ctrl-C / Ctrl-D
      (neg? c)               :quit                   ; EOF
      :else (char c))))

;;;; ------------------------------------------------------------------- running

(defn run-block!
  "Execute B through the pod and show the result; wait for a keypress."
  [terminal b]
  (let [w (.writer terminal)
        result (try (org/execute org-file (block-selector b))
                    (catch Exception e {::error (ex-message e)}))]
    (.print w (str (clear) (show-cursor)
                   "Ran " (block-label b) "\r\n\r\n"
                   (if (and (map? result) (::error result))
                     (str "ERROR: " (::error result))
                     (str "=> " (pr-str result)))
                   "\r\n\r\nPress any key to return …"))
    (.flush w)
    (read-key (.reader terminal))))

(defn tui [terminal blocks]
  (let [reader (.reader terminal)
        w      (.writer terminal)
        n      (count blocks)]
    (.enterRawMode terminal)
    (loop [idx 0]
      (.print w (render blocks idx)) (.flush w)
      (case (read-key reader)
        (:up   \k) (recur (mod (dec idx) n))
        (:down \j) (recur (mod (inc idx) n))
        :enter     (do (run-block! terminal (nth blocks idx)) (recur idx))
        (\q :quit) :done
        (recur idx)))))

;;;; --------------------------------------------------- dumb-terminal fallback

(defn fallback
  "No real TTY (piped/redirected): a plain numbered prompt instead of the TUI."
  [blocks]
  (println "Runbook:" org-file)
  (doseq [[i b] (map-indexed vector blocks)]
    (println (format "  %d) %-16s [%s]" i (block-label b) (:lang b))))
  (print "Select block number (q to quit): ") (flush)
  (let [in (str/trim (or (read-line) ""))]
    (when-not (#{"q" ""} in)
      (if-let [b (get blocks (parse-long in))]
        (println "=>" (pr-str (org/execute org-file (block-selector b))))
        (println "No such block:" in)))))

;;;; ---------------------------------------------------------------------- main

(let [blocks   (src-blocks org-file)
      terminal (-> (TerminalBuilder/builder) (.system true) (.build))]
  (cond
    (empty? blocks)               (println "No src blocks in" org-file)
    (= "dumb" (.getType terminal)) (do (fallback blocks) (.close terminal))
    :else
    (try
      (tui terminal blocks)
      (finally
        (doto (.writer terminal) (.print (str (show-cursor) "\r\n")) (.flush))
        (.close terminal)))))   ; close restores the original terminal attributes
