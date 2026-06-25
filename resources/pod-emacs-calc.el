;;; pod-emacs-calc.el --- Emacs Calc -> EDN for pod-babashka-emacs -*- lexical-binding: t; -*-
;;; Commentary:
;; Bridge Emacs' built-in `calc' engine into the pod, so a babashka driver can
;; hand off arbitrary-precision arithmetic, fractions, units and symbolic
;; algebra to Emacs and get the formatted result back as a string.
;;
;;   pod.babashka.emacs.calc/eval     (EXPR)        -> result string
;;   pod.babashka.emacs.calc/convert  (EXPR UNITS)  -> result string
;;
;; EXPR is a Calc algebraic expression string (e.g. "2^100", "sqrt(2)",
;; "deg(pi/4)", "evalv(pi)").  `eval' returns Calc's formatted result; `convert'
;; reads EXPR (which carries its own units, e.g. "2 in") and re-expresses it in
;; the target UNITS, e.g. (convert "2 in" "cm") -> "5.08 cm".
;;
;; Precision is Calc's default.  We deliberately do not expose a per-call
;; precision knob: `calc-eval' caches precision in process-global state, and the
;; pod is one long-lived Emacs, so a precision change would leak into unrelated
;; later calls.  Pass an explicit form (e.g. "evalv(pi)") for numeric output.
;;
;; A malformed expression signals so the client's `invoke' throws with Calc's
;; own parser message.
;;; Code:

(require 'calc)
(require 'calc-units)
(require 'pod-emacs)
(require 'pod-emacs-util)

(defun pod-emacs-calc--read (s)
  "Parse Calc expression string S to an internal form, or signal on a parse error.
`math-read-expr' returns (error POS MESSAGE) for malformed input."
  (let ((expr (math-read-expr s)))
    (if (eq (car-safe expr) 'error)
        (error "calc: %s" (nth 2 expr))
      expr)))

(defun pod-emacs-calc-eval (expr)
  "Evaluate Calc algebraic EXPR (a string); return the formatted result string.
Calc handles big integers, exact fractions, matrices, units and symbolic
algebra, so EXPR like \"2^100\" or \"sqrt(2)\" return exact/formatted text.
A malformed expression signals with Calc's parser message."
  (unless (stringp expr) (error "calc/eval: EXPR must be a string"))
  (let ((result (calc-eval expr)))
    (if (consp result)                  ; calc-eval returns (POS . MSG) on error
        (error "calc: %s" (cdr result))
      result)))

(defun pod-emacs-calc-convert (expr units)
  "Convert Calc EXPR into UNITS using Calc's units engine; return the string.
EXPR carries its own units (e.g. \"2 in\"); UNITS is the target (e.g. \"cm\"),
so (convert \"2 in\" \"cm\") -> \"5.08 cm\".  Either string failing to parse
signals."
  (unless (and (stringp expr) (stringp units))
    (error "calc/convert: EXPR and UNITS must be strings"))
  (math-format-value
   (math-convert-units (pod-emacs-calc--read expr)
                       (pod-emacs-calc--read units))))

;;;; ----------------------------------------------------------- registration

(pod-emacs-register
 "pod.babashka.emacs.calc"
 `(("eval"    . ,#'pod-emacs-calc-eval)
   ("convert" . ,#'pod-emacs-calc-convert)))

(provide 'pod-emacs-calc)
;;; pod-emacs-calc.el ends here
