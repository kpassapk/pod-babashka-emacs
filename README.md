# pod-babashka-emacs

A [babashka pod](https://github.com/babashka/pods) that exposes Emacs to babashka scripts.

## But why?

I got the idea for this project when I was trying out [clime](https://github.com/cosmicz/clime) to expose some elisp functions as a command line (CLI) tool. 
It worked, but I wasn't sure I wanted to learn another CLI framework. What if I could use [lambdaisland/cli][lambdaisland] or [babashka/cli][bb-cli] 
instead?

NB: This pod does not require emacs. It will try to download it when not available, and use it as a library. See the Requirements section.

Is it crazy? yes. But it may already be useful for those of us with a large amount of elisp we have built up over time, and want to use it beyond the editor.

I'm not sure this can be stable, or how this project can go :) File an issue if there is something you need.

[lambdaisland]: https://github.com/lambdaisland/cli
[bb-cli]: https://github.com/babashka/cli

## Org mode

Emacs bundles org mode, a very feature-rich markup language, with its own library for parsing, executing code blocks, exporting documents and source blocks (tangling), etc. 

There are org mode parsers in many languages, including Clojure. These will be the right choice almost always :)

However, iff you want to 
- use the "official" org mode parser (emacs)
- manage to-dos, schedules, agendas using elisp
- tangle files
- execute code blocks

this project might do the trick.

## Requirements

- **babashka** — to run your scripts and load the pod.
- **Emacs** — *optional*. The pod resolves an Emacs binary for the host
  architecture and will download a portable build if the host has none. If you
  already have Emacs on your `PATH`, it is used as-is. See
  [Emacs resolution](#emacs-resolution--running-without-emacs-installed).

## Quickstart

Load the pod by local path and call it:

```clojure
(require '[babashka.pods :as pods])
(pods/load-pod ["./pod-babashka-emacs"])

(require '[pod.babashka.emacs :as emacs]
         '[pod.babashka.emacs.org :as org])

;; Evaluate Emacs Lisp, get EDN back:
(emacs/eval "(+ 1 2)")            ;=> 3
(emacs/eval "(upcase \"hi\")")    ;=> "HI"

;; Read an org file through real org-mode:
(org/outline "examples/sample.org")
;;=>
;; {:file "/abs/path/to/examples/sample.org"
;;  :title "Project Roadmap"
;;  :children [{:level 1 :title "Planning" :begin 42
;;              :children [{:level 2 :title "Define scope" :todo "TODO"
;;                          :priority "A" :tags ["urgent" "planning"]
;;                          :scheduled "<2026-06-25 Thu>"
;;                          :properties {:EFFORT "2h" :CUSTOM_ID "scope"}
;;                          :begin 87
;;                          :children [...]}
;;                         ...]}
;;             ...]}
```

The first call starts the Emacs child process; it stays warm for the rest of
the session, so subsequent calls are fast.

## Run the example

The flagship example reads an org file through Emacs and then does pure-Clojure
analysis over the EDN it gets back:

```
bb examples/org-outline.clj            # uses examples/sample.org
bb examples/org-outline.clj some.org   # or your own file
```

A second example treats an org file as an executable **runbook** — each named
src block is a step, and babashka runs them by name and works with the output:

```
bb examples/org-execute.clj            # runs examples/runbook.org
```

Output:

```
[pod-babashka-emacs] using emacs: /opt/homebrew/bin/emacs (stderr -> ~/.cache/pod-babashka-emacs/emacs.log)
Title: Project Roadmap

Outline:
- Planning
  - TODO Define scope  ["urgent" "planning"]
    - DONE Gather requirements
    - TODO Write one-pager
  - TODO Pick stack
- Implementation
  - TODO Build the pod  ["dev"]
    - TODO Transport layer
    - TODO Org reader
- Done
  - DONE Initial spike  ["dev"]

Open TODOs: 6
  - Define scope (scheduled <2026-06-25 Thu>)
  - Write one-pager
  - Pick stack
  - Build the pod (deadline <2026-07-01 Wed>)
  - Transport layer
  - Org reader

emacs-version: 31.0.50
uppercased via elisp: DONE
```

The first line (and any Emacs warnings) goes to **stderr** — the protocol stream
on stdout stays clean.

## API reference

Payload format is **EDN**. The pod exposes a core namespace
(`pod.babashka.emacs`) plus a set of feature namespaces that load lazily on
first `require`.

### `pod.babashka.emacs`

| Var         | Args               | Returns                              | Notes |
|-------------|--------------------|--------------------------------------|-------|
| `eval`      | `[code]`           | the value of the last form, as EDN   | `code` is a string of one or more top-level elisp forms; they are read and evaluated as a `progn`. |
| `eval-file` | `[path]`           | the file's base name (string)        | `load`s an `.el` file into the (warm) Emacs process. Useful for defining helpers you then call via `funcall`. |
| `funcall`   | `[fn & args]`      | the function's return value, as EDN  | Calls the named elisp function `fn` (string or symbol) with `args`. The args are marshalled from EDN to elisp values, so you pass *data*, not string-spliced code — no `(str "(" ... ")")`. Pairs with `eval-file`: load helpers, then call them with real arguments. |
| `version`   | `[]`               | map                                  | `{:emacs-version "31.0.50" :major-version 31 :exec "/path/to/emacs"}`. |

```clojure
(emacs/eval "(mapcar #'1+ '(1 2 3))")   ;=> (2 3 4)
(emacs/version)
;;=> {:emacs-version "31.0.50", :major-version 31, :exec "/Applications/Emacs.app/Contents/MacOS/Emacs"}

;; funcall passes data, not code — no string-building:
(emacs/funcall "upcase" "hi")            ;=> "HI"
(emacs/funcall "format" "%s-%d" "x" 7)   ;=> "x-7"
;; load your own elisp, then call it with real arguments:
(emacs/eval-file "my-helpers.el")
(emacs/funcall "my-report" {:env "prod"} [1 2 3])
```

**elisp → EDN value mapping** (via `parseedn`, with a thin wrapper for
predictability):

| elisp                         | EDN       |
|-------------------------------|-----------|
| hash-table                    | map       |
| plist / list                  | list      |
| vector                        | vector    |
| keyword                       | keyword   |
| `t`                           | `true`    |
| `nil`                         | `nil`     |
| non-serializable (buffer, fn) | string repr |

### `pod.babashka.emacs.org`

Each reads or runs an org file through real org-mode in a throwaway buffer.

| Var         | Args              | Returns                                          | Notes |
|-------------|-------------------|--------------------------------------------------|-------|
| `outline`   | `[path]` / `[path opts]` | `{:file :title :children [node ...]}`     | Nested headline tree. `:title` is the `#+TITLE:` keyword (may be `nil`). |
| `headlines` | `[path]` / `[path opts]` | vector of nodes (flat, document order)    | Same nodes as `outline` but un-nested (no `:children`). |
| `to-edn`    | `[path]` / `[path opts]` | `{:file :title :children [node ...]}`     | Like `outline`, but every node also gets a `:body` (the entry's text, excluding subheadings). |
| `src-blocks`| `[path]` / `[path opts]` | vector of block nodes (document order)    | Lists every src block so a driver can discover and address them. Each node: `:index` (0-based), `:name` (or `nil`), `:lang`, `:begin`, `:header-args` (map, or `nil`), `:body`. |
| `execute`   | `[path]` / `[path opts]` | the block's result, as EDN                | Runs one org-babel src block and returns its value. Pick the block with `opts` (`:name` / `:index` from `src-blocks`); see below. The block's language backend autoloads (`sh`/`bash`/… → `ob-shell`, else `ob-LANG`). `org-confirm-babel-evaluate` is bound to `nil`, so blocks run without prompting. |

`opts` is an EDN map. Recognized keys:

| Opt          | Type   | Used by      | Effect |
|--------------|--------|--------------|--------|
| `:max-level` | int    | the readers  | Only include headlines at or above this depth (level ≤ N). |
| `:name`      | string | `execute`    | Run the block whose `#+name:` matches. |
| `:index`     | int    | `execute`    | Run the Nth src block (0-based, document order). |

`execute` with no `:name`/`:index` runs the file's sole src block, or errors if
there are several. Out-of-range `:index` and unknown `:name` both error.

```clojure
(org/execute "examples/sample.org" {:index 0})  ;=> "hello"   ; the echo block
(org/execute "tasks.org" {:name "deploy"})       ; run the block named "deploy"
```

```clojure
(org/headlines "examples/sample.org" {:max-level 1})
;;=> [{:level 1 :title "Planning" :begin 42}
;;    {:level 1 :title "Implementation" :begin 388}
;;    {:level 1 :title "Done" :begin 508}]
```

**Node shape.** A headline node is a map. Only `:level`, `:title`, and `:begin`
are always present; the rest appear only when the headline has them:

| Key           | Type             | Always? | Meaning |
|---------------|------------------|---------|---------|
| `:level`      | int              | yes     | Outline depth (1 = top). |
| `:title`      | string           | yes     | Headline text (no TODO/priority/tags). |
| `:begin`      | int              | yes     | Buffer position of the headline. |
| `:todo`       | string           | no      | TODO keyword, e.g. `"TODO"` / `"DONE"`. |
| `:priority`   | string           | no      | Priority cookie, e.g. `"A"`. |
| `:tags`       | vector of string | no      | Headline tags. |
| `:properties` | map              | no      | Drawer properties, keyword-keyed (skips org's built-ins like `CATEGORY`/`PRIORITY`/`TODO`/`TAGS`). |
| `:scheduled`  | string           | no      | `SCHEDULED:` timestamp, raw. |
| `:deadline`   | string           | no      | `DEADLINE:` timestamp, raw. |
| `:children`   | vector of node   | no      | Sub-headlines (omitted on leaves). |
| `:body`       | string           | no      | Entry text. Only from `to-edn`. |

### `pod.babashka.emacs.calc`

Hand arbitrary-precision arithmetic, exact fractions, units, and symbolic
algebra to Emacs' built-in **Calc** and get the formatted result back as a
string.

| Var       | Args           | Returns       | Notes |
|-----------|----------------|---------------|-------|
| `eval`    | `[expr]`       | result string | `expr` is a Calc algebraic expression (e.g. `"2^100"`, `"sqrt(2)"`, `"evalv(pi)"`). Big integers, exact fractions, matrices and symbolic algebra all work. |
| `convert` | `[expr units]` | result string | Re-express `expr` (which carries its own units) in the target `units`. |

Precision is Calc's default; there is no per-call precision knob — Calc caches
precision in process-global state and the Emacs child is long-lived, so a change
would leak into unrelated later calls. Pass an explicit form like `"evalv(pi)"`
for numeric output. A malformed expression throws with Calc's parser message.

```clojure
(calc/eval "2^100")           ;=> "1267650600228229401496703205376"
(calc/eval "sqrt(2)")         ;=> "1.41421356237"
(calc/convert "2 in" "cm")    ;=> "5.08 cm"
(calc/convert "55 mph" "kph") ;=> "88.51392 kph"
```

### `pod.babashka.emacs.project`

Point Emacs' built-in **`project`** library at a path and read the enclosing
project's root and tracked files, using the same VC-aware detection Emacs uses
interactively.

| Var     | Args                     | Returns           | Notes |
|---------|--------------------------|-------------------|-------|
| `root`  | `[path]`                 | root dir (string) | Absolute path of the project enclosing `path`. Throws if `path` is in no project. |
| `files` | `[path]` / `[path opts]` | vector of paths   | The project's tracked files. With `{:relative true}` the paths are relative to the root; otherwise absolute. |

`path` may be any file or directory inside the project.

```clojure
(project/root ".")                   ;=> "/home/me/src/myproj/"
(project/files "." {:relative true}) ;=> ["README.md" "src/core.clj" ...]
```

### `pod.babashka.emacs.org-roam`

Read an [org-roam](https://www.orgroam.com/) knowledge graph as data: the nodes
in a roam directory and the backlinks pointing at any one of them. org-roam is
an external package, so the pod installs it on first `require` (via
`use-package` with `:ensure`).

| Var         | Args            | Returns             | Notes |
|-------------|-----------------|---------------------|-------|
| `nodes`     | `[]` / `[opts]` | vector of node maps | Every node in the roam directory. Each: `:id`, `:title`, `:file`, `:level`, `:tags`. |
| `backlinks` | `[opts]`        | vector of link maps | Backlinks to the node `:id`. Each: `:source-id`, `:source-title`, `:point`. |

`opts` is an EDN map. Recognized keys:

| Opt          | Type   | Used by     | Effect |
|--------------|--------|-------------|--------|
| `:directory` | string | both        | The org-roam directory to read (defaults to the configured `org-roam-directory`). |
| `:id`        | string | `backlinks` | The node whose backlinks to return (required). |

The org-roam SQLite db is synced on each call, so results reflect the
directory's current contents.

```clojure
(org-roam/nodes {:directory "~/roam"})
;;=> [{:id "a1b2…" :title "Zettelkasten" :file "~/roam/zk.org" :level 0 :tags []}
;;    ...]
(org-roam/backlinks {:directory "~/roam" :id "a1b2…"})
;;=> [{:source-id "c3d4…" :source-title "Note-taking" :point 312}]
```

### `pod.babashka.emacs.devops`

Bridge the external [devops](https://github.com/kpassapk/devops.el) package —
which tangles and runs org-babel src blocks against remote TRAMP targets — into
the pod. devops' own commands are interactive and act on the buffer at point;
this namespace drives its noninteractive engine over a file path passed from
babashka. The package is installed on first `require` via `use-package` with
`:vc`.

| Var       | Args     | Returns               | Notes |
|-----------|----------|-----------------------|-------|
| `tangle`  | `[opts]` | vector of result maps | Tangle a heading's src blocks to its devops target(s). Each result: `:tag` (the heading's target tag), `:target` (the resolved TRAMP path), `:files` (count of files written). |
| `execute` | `[opts]` | the block's result    | Run one src block against its enclosing heading's target. Pick the block like `org/execute` (`:name` / `:index`). |

`opts` is an EDN map:

| Opt          | Type   | Used by   | Effect |
|--------------|--------|-----------|--------|
| `:file`      | string | both      | Path to the org file (**required**). |
| `:heading`   | string | `tangle`  | Tangle the heading with this exact title. |
| `:custom-id` | string | `tangle`  | Tangle the heading with this `CUSTOM_ID` (stable across title edits). |
| `:all`       | bool   | `tangle`  | Tangle every target-tagged heading in the file instead. |
| `:name`      | string | `execute` | Run the block whose `#+name:` matches. |
| `:index`     | int    | `execute` | Run the Nth src block (0-based, document order). |

`tangle` needs exactly one of `:heading`, `:custom-id`, or `:all`. A heading's
target tag resolves to a `:dir` that devops injects into the block's babel
params, so the block tangles/runs on its target. `org-confirm-babel-evaluate` is
bound to `nil`.

```clojure
(devops/tangle {:file "infra.org" :all true})
;;=> [{:tag "web01" :target "/ssh:web01:/etc/nginx/" :files 2} ...]
(devops/execute {:file "infra.org" :name "deploy"})
```

### Errors

An elisp error becomes a thrown `ex-info` on the babashka side. The Emacs error
message is the `ex-message`; `ex-data` carries the error symbol and the var:

```clojure
(try
  (emacs/eval "(error \"boom\")")
  (catch clojure.lang.ExceptionInfo e
    (ex-message e)  ;=> "boom"
    (ex-data e)))   ;=> {:type "error", :var "pod.babashka.emacs/eval"}
```

## How it works

A babashka pod talks to babashka over **stdio** using **bencode** framing.
The obvious design — "Emacs *is* the pod" — does not work: `emacs --batch` can
read newline-delimited stdin (`read-string`) but has no way to read babashka's
raw, newline-free bencode stream byte-for-byte.

So the pod is split in two. A thin babashka **shim** owns the babashka-facing
stdio and is a dumb, bencode-unaware byte transcoder: it converts the raw
bencode stream to/from **base64 lines** (ASCII, newline-framed, lossless) for an
`emacs --batch` **brain** that holds all the protocol logic.

```
          raw bencode (stdio)            base64 lines (stdio)
babashka <--------------------> bb shim <--------------------> emacs --batch
                                (dumb pipe)                    (the brain)
```

The shim never parses bencode, so it cannot corrupt the protocol — correctness
lives in one place (the elisp brain), which uses both the elisp `bencode` (wire)
and `parseedn` (EDN payload) libraries. The Emacs child stays warm across calls.

For the full story and the experiments behind the decision, see
[`docs/design.md`](docs/design.md) and
[`docs/adr/0001-transport-architecture.md`](docs/adr/0001-transport-architecture.md).

## Emacs resolution / running without Emacs installed

When the pod starts, the shim resolves an Emacs binary in this order:

1. **`$POD_BABASHKA_EMACS_BIN`** — explicit override; used as-is.
2. **Cached download** — a portable build previously downloaded by the pod
   (under the cache dir).
3. **System `emacs`** on `PATH` (on macOS it also checks
   `/Applications/Emacs.app/Contents/MacOS/Emacs`).
4. **Download a portable build** for the host os/arch into the cache, then use
   it.

This is what lets the pod work even on a machine without Emacs installed.

| Env var                    | Purpose |
|----------------------------|---------|
| `POD_BABASHKA_EMACS_BIN`   | Force a specific Emacs executable (skips all other resolution). |
| `POD_BABASHKA_EMACS_URL`   | Override the portable-build download URL for the host os/arch. |
| `POD_BABASHKA_EMACS_CACHE` | Cache directory for downloaded builds and `emacs.log`. |
| `BABASHKA_PODS_OS_NAME`    | Babashka's os-name override (used to pick the download). |
| `BABASHKA_PODS_OS_ARCH`    | Babashka's os-arch override (used to pick the download). |

**Cache directory** defaults to `$POD_BABASHKA_EMACS_CACHE`, else
`$XDG_CACHE_HOME/pod-babashka-emacs`, else `~/.cache/pod-babashka-emacs`.

Portable builds currently ship for macOS arm64 and x86_64 (Emacs.app `.dmg`
builds that bundle their own lisp). On other platforms, install Emacs, set
`POD_BABASHKA_EMACS_BIN`, or point `POD_BABASHKA_EMACS_URL` at a suitable
archive.

## Troubleshooting

- **See what Emacs is doing.** The Emacs child's stderr (warnings, errors,
  messages) is logged to `<cache>/emacs.log` (e.g.
  `~/.cache/pod-babashka-emacs/emacs.log`). The pod also prints the resolved
  Emacs path to stderr on startup.
- **Wrong / multiple Emacs versions.** Set `POD_BABASHKA_EMACS_BIN` to force a
  specific Emacs and bypass resolution entirely:
  ```
  POD_BABASHKA_EMACS_BIN=/opt/homebrew/bin/emacs bb examples/org-outline.clj
  ```
- **Calls hang.** Almost always an Emacs that wrote something unexpected to
  stdout, or a download in progress. Check `emacs.log` and the startup line.

## Layout

```
pod-babashka-emacs            # the pod executable (babashka launches this)
bb.edn                        # babashka project / test task
src/pod_babashka_emacs/
  shim.clj                    # bb shim: stdio transcoder + child lifecycle
  emacs.clj                   # Emacs resolution / portable-build download
resources/
  pod-emacs.el                # the elisp brain: pod protocol loop + dispatch
  pod-emacs-org.el            # org-mode -> EDN (outline / headlines / to-edn / execute)
  pod-emacs-calc.el           # Calc -> EDN (eval / convert)
  pod-emacs-project.el        # project.el -> EDN (root / files)
  pod-emacs-org-roam.el       # org-roam -> EDN (nodes / backlinks)
  pod-emacs-devops.el         # devops.el -> EDN (tangle / execute)
  pod-emacs-util.el           # shared elisp helpers (hash-tables, EDN encode)
vendor/                       # vendored elisp deps (bencode.el, parseclj, parseedn)
examples/
  org-outline.clj             # flagship example: read org -> EDN -> analyze
  org-execute.clj             # run an org file as a runbook of named src blocks
  sample.org                  # sample org file
  runbook.org                 # named src blocks driven by org-execute.clj
docs/
  design.md                   # full architecture
  adr/0001-transport-architecture.md
scripts/run-tests.clj         # test runner (bb test)
test/                         # clojure.test suite
```

## License

Copyright © 2026 Kyle Passarelli. Distributed under the Eclipse Public License
1.0 — see [LICENSE](LICENSE).
