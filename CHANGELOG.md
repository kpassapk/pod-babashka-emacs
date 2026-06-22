# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `pod.babashka.emacs.org/execute` — run a single org-babel src block and return
  its result as EDN. Select the block with `:name` or `:index` (0-based); a
  lone block runs with no selector. The language backend autoloads (shell
  dialects → `ob-shell`, else `ob-LANG`) and `org-confirm-babel-evaluate` is
  bound to `nil` so blocks run unattended under `emacs --batch`.

## [0.1.0] - 2026-06-21

Initial release of `pod-babashka-emacs`, a babashka pod that exposes Emacs to
babashka scripts.

### Added

- **`pod.babashka.emacs` namespace** for driving Emacs Lisp from babashka:
  - `eval` — evaluate an elisp string and return the result as EDN.
  - `eval-file` — `load` an `.el` file into the warm Emacs process.
  - `version` — report the running Emacs version and executable path.
- **`pod.babashka.emacs.org` namespace** — read org files through real org-mode
  and get the structure back as EDN:
  - `outline` — nested headline tree.
  - `headlines` — flat list of headlines in document order.
  - `to-edn` — nested tree including each entry's body text.
  - All three accept a `:max-level` option. Nodes carry `:level`, `:title`,
    `:begin`, and (when present) `:todo`, `:priority`, `:tags`, `:properties`,
    `:scheduled`, `:deadline`, `:children`, and `:body`.
- **elisp → EDN value mapping** via `parseedn` (hash-table → map, list → list,
  vector → vector, keyword → keyword, `t`/`nil` → `true`/`nil`, non-serializable
  values → string repr).
- **Error propagation**: an elisp error becomes a thrown `ex-info` on the
  babashka side, with the Emacs message as the `ex-message` and
  `{:type "<error-symbol>" :var "..."}` as `ex-data`.
- **Emacs bundling / "works without Emacs installed"**: the pod resolves an
  Emacs binary in order — `$POD_BABASHKA_EMACS_BIN`, cached download, system
  `emacs` on `PATH`, then a downloaded portable build for the host os/arch.
  Configurable via `POD_BABASHKA_EMACS_BIN`, `POD_BABASHKA_EMACS_URL`,
  `POD_BABASHKA_EMACS_CACHE`, and babashka's `BABASHKA_PODS_OS_NAME` /
  `BABASHKA_PODS_OS_ARCH`. Portable builds ship for macOS arm64 and x86_64.
- **Transport architecture**: a thin babashka shim transcodes the raw bencode
  protocol stream to/from base64 lines for an `emacs --batch` brain that holds
  the protocol logic, working around `emacs --batch`'s inability to read a raw,
  newline-free byte stream. See `docs/adr/0001-transport-architecture.md`.
- Flagship example (`examples/org-outline.clj` + `examples/sample.org`) and a
  `clojure.test` suite (`bb test`).

[Unreleased]: https://github.com/kpassapk/pod-babashka-emacs/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/kpassapk/pod-babashka-emacs/releases/tag/v0.1.0
