;;; Copyright (C) 2019-2021 Rob Browning <rlb@defaultvalue.org>
;;; SPDX-License-Identifier: LGPL-2.1-or-later OR EPL-1.0+

;; This is the lowest level, supporting *everything*, including
;; definitions required by code generated by the compiler, etc., and
;; providing bits needed to bootstrap the system by compiling
;; clojure.core, i.e. (lokke ns clojure core).

(define-module (lokke boot)
  #:use-module ((lokke base quote)
                #:select (/lokke/reader-hash-map
                          /lokke/reader-hash-set
                          /lokke/reader-vector
                          clj-quote
                          synerr))
  #:use-module ((lokke compat) #:select (re-export-and-replace!))
  #:use-module ((lokke ns) #:select (ns))
  #:use-module ((lokke transmogrify) #:select (instantiate-tagged))
  #:export (/lokke/reader-meta /lokke/reader-tagged)
  #:re-export (/lokke/reader-hash-map
               /lokke/reader-hash-set
               /lokke/reader-vector
               ns)
  #:replace (unquote unquote-splicing)
  #:duplicates (merge-generics replace warn-override-core warn last))

(re-export-and-replace! '(clj-quote . quote))

;; 3.0 requires this, but it can't go in the (guile) #:select above
;; because *that* crashes 2.2
(cond-expand
  ;; note "guile-3" means >= 3
  (guile-3
   (use-modules ((guile) #:select (... else))))
  (else))


(define-syntax-rule (/lokke/reader-meta x ...)
  (warn (format #f "Ignoring metadata in unsupported position: ~s"
                '(/lokke/reader-meta x ...))))

(define-syntax-rule (/lokke/reader-tagged tag data)
  ((@ (lokke transmogrify) instantiate-tagged) 'tag data))
