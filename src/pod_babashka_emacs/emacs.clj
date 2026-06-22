(ns pod-babashka-emacs.emacs
  "Resolve an Emacs binary for the host, downloading a portable build if the
  host has none.  This is what lets the pod work even without Emacs installed."
  (:require [babashka.fs :as fs]
            [babashka.process :as p]
            [cheshire.core :as json]
            [clojure.string :as str]))

(defn log [& xs]
  ;; pod stdout is the protocol channel; everything human-facing goes to stderr.
  (binding [*out* *err*] (apply println "[pod-babashka-emacs]" xs)))

(defn os-arch
  "Return [os arch] as normalized keywords, honoring babashka's pod override env."
  []
  (let [os   (or (System/getenv "BABASHKA_PODS_OS_NAME")
                 (System/getProperty "os.name"))
        arch (or (System/getenv "BABASHKA_PODS_OS_ARCH")
                 (System/getProperty "os.arch"))
        os*  (let [o (str/lower-case os)]
               (cond (str/includes? o "mac")     :macos
                     (str/includes? o "darwin")  :macos
                     (str/includes? o "win")     :windows
                     :else                       :linux))
        arch* (let [a (str/lower-case arch)]
                (cond (or (= a "aarch64") (= a "arm64")) :aarch64
                      (or (= a "x86_64") (= a "amd64"))  :x86_64
                      :else (keyword a)))]
    [os* arch*]))

(defn cache-dir []
  (let [base (or (System/getenv "POD_BABASHKA_EMACS_CACHE")
                 (some-> (System/getenv "XDG_CACHE_HOME")
                         (str "/pod-babashka-emacs"))
                 (str (System/getProperty "user.home")
                      "/.cache/pod-babashka-emacs"))]
    (fs/file base)))

;;;; ----------------------------------------------------- portable build source

;; macOS: jimeh/emacs-builds ships standalone Emacs.app bundles (their own lisp)
;; as GitHub release assets.  We resolve the *latest* release dynamically via the
;; API so date/version-stamped asset names don't rot.
(def ^:private github-repo "jimeh/emacs-builds")

(defn- arch-dmg-suffix [arch]
  (case arch
    :aarch64 "arm64.dmg"
    :x86_64  "x86_64.dmg"
    (str (name arch) ".dmg")))

(defn- github-latest-dmg-url [arch]
  (let [api (str "https://api.github.com/repos/" github-repo "/releases/latest")
        {:keys [out exit err]} (p/shell {:out :string :err :string :continue true}
                                        "curl" "-fsSL"
                                        "-H" "Accept: application/vnd.github+json"
                                        api)]
    (when-not (zero? exit)
      (throw (ex-info (str "GitHub API request failed: " err) {:api api})))
    (let [release (json/parse-string out true)
          suffix  (arch-dmg-suffix arch)
          asset   (->> (:assets release)
                       (filter #(and (str/ends-with? (:name %) suffix)
                                     (not (str/ends-with? (:name %) ".sha256"))))
                       first)]
      (when-not asset
        (throw (ex-info "No matching Emacs asset in latest release"
                        {:arch arch :tag (:tag_name release)})))
      (:browser_download_url asset))))

(defn- extract-dmg!
  "Mount DMG, copy the .app bundle into DEST-DIR, detach.  Return the path to the
  Emacs executable inside the copied bundle.  macOS only."
  [dmg dest-dir]
  (let [mount (str (fs/create-temp-dir {:prefix "pod-emacs-mnt"}))]
    (try
      (p/shell {:out :string :err :string}
               "hdiutil" "attach" "-nobrowse" "-mountpoint" mount (str dmg))
      (let [app (->> (fs/list-dir mount)
                     (filter #(str/ends-with? (str (fs/file-name %)) ".app"))
                     first)]
        (when-not app (throw (ex-info "No .app in dmg" {:dmg (str dmg)})))
        (fs/create-dirs dest-dir)
        (let [target (fs/file dest-dir (fs/file-name app))]
          (when (fs/exists? target) (fs/delete-tree target))
          (fs/copy-tree (str app) (str target))
          (str (fs/file target "Contents" "MacOS" "Emacs"))))
      (finally
        (p/shell {:out :string :err :string :continue true}
                 "hdiutil" "detach" "-force" mount)))))

(defn download-emacs!
  "Download and extract a portable Emacs for [os arch]; return the binary path.
  Honors POD_BABASHKA_EMACS_URL (a direct .dmg URL) for any platform."
  [[os arch]]
  (let [url (or (System/getenv "POD_BABASHKA_EMACS_URL")
                (case os
                  :macos (github-latest-dmg-url arch)
                  (throw (ex-info
                          (str "No automatic Emacs download for " (name os) "/" (name arch)
                               ". Install Emacs, or set POD_BABASHKA_EMACS_BIN, "
                               "or set POD_BABASHKA_EMACS_URL to a .dmg URL.")
                          {:os os :arch arch}))))
        dest    (fs/file (cache-dir) "emacs")
        archive (fs/file (cache-dir) (last (str/split url #"/")))]
    (log "downloading portable Emacs for" (name os) (name arch) "from" url)
    (fs/create-dirs (cache-dir))
    (p/shell "curl" "-fSL" "-o" (str archive) url)
    (when-not (str/ends-with? (str archive) ".dmg")
      (throw (ex-info "Only .dmg archives are supported for download"
                      {:archive (str archive)})))
    (let [bin (extract-dmg! archive dest)]
      (when-not (fs/executable? bin)
        (throw (ex-info "Extracted Emacs is not executable" {:bin bin})))
      (fs/create-dirs (fs/file (cache-dir) "current"))
      (spit (fs/file (cache-dir) "current" "bin") bin)
      (fs/delete-if-exists archive)
      (log "installed Emacs:" bin)
      bin)))

;;;; ----------------------------------------------------- resolution

(defn- which-emacs []
  (when-let [hit (or (fs/which "emacs")
                     (let [app "/Applications/Emacs.app/Contents/MacOS/Emacs"]
                       (when (fs/executable? app) app)))]
    (str hit)))

(defn- cached-emacs []
  (let [marker (fs/file (cache-dir) "current" "bin")]
    (when (fs/exists? marker)
      (let [bin (str/trim (slurp (fs/file marker)))]
        (when (fs/executable? bin) bin)))))

(defn resolve-emacs
  "Return an absolute path to an Emacs executable, downloading one if needed.
  Order: $POD_BABASHKA_EMACS_BIN, cached download, system PATH, download."
  []
  (or (System/getenv "POD_BABASHKA_EMACS_BIN")
      (cached-emacs)
      (which-emacs)
      (download-emacs! (os-arch))))
