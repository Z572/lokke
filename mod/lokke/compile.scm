;;; Copyright (C) 2019 Rob Browning <rlb@defaultvalue.org>
;;;
;;; This project is free software; you can redistribute it and/or
;;; modify it under the terms of (at your option) either of the
;;; following two licences:
;;;
;;;   1) The GNU Lesser General Public License as published by the
;;;      Free Software Foundation; either version 2.1, or (at your
;;;      option) any later version.
;;;
;;;   2) The Eclipse Public License; either version 1.0 or (at your
;;;      option) any later version.

(read-set! keywords 'postfix)  ;; srfi-88

(define-module (lokke compile)
  use-module: ((ice-9 match) select: (match))
  use-module: ((ice-9 pretty-print) select: (pretty-print))
  use-module: ((ice-9 receive) select: (receive))
  use-module: ((ice-9 sandbox)
               select: (all-pure-bindings
                        all-pure-and-impure-bindings
                        make-sandbox-module))
  use-module: ((ice-9 vlist) select: (alist->vhash vhash-assq))
  use-module: ((language scheme compile-tree-il) prefix: scheme/)
  use-module: ((language tree-il) prefix: tree-il/)
  use-module: ((lokke collection) select: (seq? seq->scm-list))
  use-module: ((lokke hash-map) select: (assoc get hash-map hash-map? kv-list))
  use-module: ((lokke hash-set) select: (hash-set? into set))
  use-module: ((lokke metadata) select: (meta))
  use-module: ((lokke scm vector)
               select: (lokke-vec lokke-vector? lokke-vector->list))
  use-module: ((lokke symbol)
               select: (parse-symbol scoped-sym? scoped-sym-symbol simple-symbol?))
  use-module: (oop goops)
  use-module: ((srfi srfi-1)
               select: (any
                        every
                        find
                        first
                        fold
                        last
                        second))
  use-module: ((srfi srfi-43) select: (vector-map))
  use-module: ((system base compile)
               select: ((compile . base-compile)
                        compile-file
                        compiled-file-name))
  export: (clj-defmacro
           expand-symbol
           expand-symbols
           literals->clj-instances
           literals->scm-instances
           load-file
           make-lokke-language
           preserve-meta-if-new!
           tree->tree-il
           unexpand-symbols)
  duplicates: (merge-generics replace warn-override-core warn last))

;; Right now the tree walkers in this code tend to be prescriptive,
;; i.e. they reject any type they don't recognize.  That's been
;; helpful with respect to debugging, but we could omit some of the
;; checks and just rely on a catch-all else clause (perhaps controlled
;; via a debug option) if we liked.

(define debug-compile? #f)
(define debug-il? (or debug-compile? #f))
(define enable-invoke? #t)

(define dbg
  (if debug-compile?
      (lambda args (apply format (current-error-port) args))
      (lambda args #t)))

(define (preserve-meta-if-new! orig maybe-new)
  (cond
   ((eq? orig maybe-new) orig)
   ((nil? (meta orig)) maybe-new)
   (else
    ;; set-meta! is safe here since we require that maybe-new be a
    ;; newly created local object, and all relevant meta ops are
    ;; persistent.
    ((@@ (lokke metadata) set-meta!) maybe-new (meta orig)))))

(define (literals->clj-instances expr)
  (define (convert expr)
    (preserve-meta-if-new!
     expr
     (cond
      ((null? expr) expr)
      ((list? expr)
       (case (car expr)
         ((/lokke/reader-hash-set) (set (map convert (cdr expr))))
         ((/lokke/reader-vector) (lokke-vec (map convert (cdr expr))))
         ((/lokke/reader-hash-map)
          (apply hash-map (map convert (cdr expr))))
         (else (map literals->clj-instances expr))))
      (else expr))))
  (convert expr))

(define (items->alist . alternating-keys-and-values)
  (let loop ((kvs alternating-keys-and-values)
             (result '()))
    (cond
     ((null? kvs) result)
     ((null? (cdr kvs)) (error "No value for key:" (car kvs)))
     (else (loop (cddr kvs)
                 (cons (cons (car kvs) (cadr kvs)) result))))))

(define (literals->scm-instances expr)
  (define (convert expr)
    (preserve-meta-if-new!
     expr
     (cond
      ((null? expr) expr)
      ((list? expr)
       (case (car expr)
         ((/lokke/reader-hash-set) (list (map convert (cdr expr))))  ;; for srfi-1
         ((/lokke/reader-vector) (apply vector (map convert (cdr expr))))
         ((/lokke/reader-hash-map) (items->alist (map convert (cdr expr))))
         (else (map literals->scm-instances expr))))
      (else expr))))
  (convert expr))

(define (clj-instances->literals expr)
  ;; This also converts seqs to scheme lists
  (define (convert expr)
    (preserve-meta-if-new!
     expr
     (cond
      ((symbol? expr) expr)
      ((null? expr) expr)
      ((string? expr) expr)
      ((number? expr) expr)
      ((keyword? expr) expr)
      ((boolean? expr) expr)
      ((pair? expr) (cons (convert (car expr)) (convert (cdr expr))))
      ;;((list? expr) (map convert expr))
      ((lokke-vector? expr) `(/lokke/reader-vector ,@(map convert (lokke-vector->list expr))))
      ((hash-map? expr) `(/lokke/reader-hash-map ,@(map convert (kv-list expr))))
      ((hash-set? expr) `(/lokke/reader-hash-set ,@(into '() (map convert expr))))
      ((seq? expr)
       (map convert (seq->scm-list expr)))
      (else (error "Unexpected expression while uninstantiating literals:"
                   expr (class-of expr) (list? expr))))))
  (when debug-compile?
    (format (current-error-port) "uninstantiate:\n")
    (pretty-print expr (current-error-port)))
  (let ((result (convert expr)))
    (when debug-compile?
      (format (current-error-port) "uninstantiated:\n")
      (pretty-print expr (current-error-port))
      (format (current-error-port) "  =>\n")
      (pretty-print result (current-error-port)))
    result))


(define (expand-symbol sym)
  (unless (symbol? sym)
    (error "Asked to expand non-symbol:" sym))
  (case sym
    ;; Pass these through as-is
    ((/
      /lokke/reader-anon-fn
      /lokke/reader-meta
      /lokke/reader-vector
      /lokke/reader-hash-map
      /lokke/reader-hash-set
      /lokke/scoped-sym)
     sym)
    (else (if (simple-symbol? sym) sym (parse-symbol sym)))))

(define (expand-symbols expr)
  ;; This does not have to deal with hash-maps, etc. because we always
  ;; uninstantiate those before calling this.  Also assumes we'll
  ;; never see scheme vector here.
  (define (pass-synquoted-region expr)
    (preserve-meta-if-new!
     expr
     (if (pair? expr)
         (if (eq? 'unquote (car expr))
             (convert expr)
             (map pass-synquoted-region expr))
         expr)))
  (define (convert expr)
    (preserve-meta-if-new!
     expr
     (cond
      ((symbol? expr) (expand-symbol expr))
      ((null? expr) expr)
      ((list? expr)
       (case (car expr)
         ((quote) expr)
         ((syntax-quote) (pass-synquoted-region expr))
         (else (map convert expr))))
      ;;((list? expr) (map convert expr))
      ((string? expr) expr)
      ((number? expr) expr)
      ((keyword? expr) expr)
      ((boolean? expr) expr)
      ((char? expr) expr)
      (else (error "Unexpected expression while desugaring symbols:" expr)))))
  (when debug-compile?
    (format (current-error-port) "expand-symbols:\n")
    (pretty-print expr (current-error-port)))
  (let ((result (convert expr)))
    (when debug-compile?
      (format (current-error-port) "expanded-symbols:\n")
      (pretty-print expr (current-error-port))
      (format (current-error-port) "  =>\n")
      (pretty-print result (current-error-port)))
    result))

(define (unexpand-symbols expr)
  ;; This does not have to deal with hash-maps, etc. because we always
  ;; call this before instantiating those.  Also assumes we'll never
  ;; see scheme vector here.
  (define (convert expr)
    (preserve-meta-if-new!
     expr
     (cond
      ((symbol? expr) expr)
      ((null? expr) expr)
      ((list? expr)
       (if (scoped-sym? expr)
           (scoped-sym-symbol expr)
           (map convert expr)))
      ((string? expr) expr)
      ((number? expr) expr)
      ((keyword? expr) expr)
      ((boolean? expr) expr)
      (else (error "Unexpected expression while sugaring symbols:" expr)))))
  (when debug-compile?
    (format (current-error-port) "unexpand:\n")
    (pretty-print expr (current-error-port)))
  (let ((result (convert expr)))
    (when debug-compile?
      (format (current-error-port) "unexpanded:\n")
      (pretty-print expr (current-error-port))
      (format (current-error-port) "  =>\n")
      (pretty-print result (current-error-port)))
    result))

(eval-when (expand load eval)
  (define (/lokke/prep-form-for-clj-macro form)
    (literals->clj-instances (unexpand-symbols form))))

(eval-when (expand load eval)
  (define (/lokke/convert-form-from-clj-macro form)
    (expand-symbols (clj-instances->literals form))))

(define (make-invoke-ref src)
  (tree-il/make-module-ref src '(lokke invoke) 'invoke #t))

(define (make-vector-fn-ref src)
  (tree-il/make-module-ref src '(lokke scm vector) 'lokke-vector #t))

(define (rewrite-il-call call)
  (define (add-invoke call)
    (tree-il/make-call (tree-il/call-src call)
                       (make-invoke-ref (tree-il/call-src call))
                       (cons (tree-il/call-proc call)
                             (tree-il/call-args call))))
  (if enable-invoke? (add-invoke call) call))

(define il-count 0)

(define (rewrite-il-calls il)
  ;; FIXME: source-properties...
  (define (up tree)
    (let* ((count (begin (set! il-count (1+ il-count)) il-count))
           (_ (when debug-il? (format (current-error-port) "il[~a]: ~s\n" count tree)))
           (result (if (not (tree-il/call? tree))
                       (begin
                         (when debug-il?
                           (format (current-error-port) "il[~a]: <<unchanged>>\n" count))
                         tree)
                       (let ((result (rewrite-il-call tree)))
                         (when debug-il?
                           (format (current-error-port) "il[~a]: ~s\n" count result))
                         result))))
      result))
  (let ((result (tree-il/post-order up il)))
    (when debug-il?
      (format (current-error-port) "tree-il:\n")
      (pretty-print (tree-il/unparse-tree-il il) (current-error-port))
      (format (current-error-port) "  =>\n")
      (pretty-print (tree-il/unparse-tree-il result) (current-error-port)))
    result))

(define (tree->tree-il expr env opts)
  ;; FIXME: source-properties...
  (when debug-compile? (format (current-error-port) "compile: ~s\n" expr))
  ;; At the moment, env and cenv will be the same from the scheme compiler
  (receive (result env cenv)
      (scheme/compile-tree-il expr env opts)
    (when debug-compile?
      (format (current-error-port) "initial-tree-il: ~s\n" result))
    (let ((result (rewrite-il-calls result)))
      (when debug-compile? (format (current-error-port) "final-tree-il: ~s\n" result))
      (values result env env))))

(define (load-file path)
  (let ((compiled (compiled-file-name path)))
    (when (or (not (file-exists? compiled))
              (let ((st-src (stat path))
                    (st-com (stat compiled)))
                (or (<= (stat:mtime st-com) (stat:mtime st-src))
                    (and (= (stat:mtime st-src) (stat:mtime st-com))
                         (<= (stat:mtimensec st-com) (stat:mtimensec st-src))))))
      (compile-file path #:from 'lokke))
    (load-compiled compiled)))

(define (exported-bindings module-name)
  (cons module-name
        (module-map (lambda (name var) name)
                    (resolve-interface module-name))))

(define (compile-uninstantiated form env)
  (tree->tree-il form env '()))

(define (compile form env)
  (compile-uninstantiated (clj-instances->literals form) env))

;; FIXME: there's probably a better way to write this...
(define-syntax clj-defmacro
  (lambda (x)
    (syntax-case x ()
      ((_ name arity-or-arities ...)
       (with-syntax ((fn (datum->syntax x 'fn)))
         (dbg "clj-defmacro ~s\n" #'name)
         #'(begin
             (define-syntax name
               (lambda (x)
                 (syntax-case x ()
                   ((_ macro-args (... ...))
                    (let* ((dummy (dbg "expanding defmacro ~s\n" 'name))
                           (dummy (for-each (lambda (x) (dbg "  ~s\n" x))
                                            (list #'(macro-args (... ...)))))
                           (xform '(fn arity-or-arities ...))
                           (dummy (dbg "macro xform raw ~s\n" xform))
                           (xform (compile-uninstantiated xform (current-module)))
                           (dummy (dbg "macro xform compiled ~s\n" xform))
                           (xform (base-compile xform
                                                #:from 'tree-il
                                                #:to 'value
                                                #:env (current-module)))
                           (dummy (dbg "macro xform value ~s\n" xform))
                           (dummy (dbg "defmacro prep clj args\n"))
                           (clj-args (map (lambda (macro-arg)
                                            (/lokke/prep-form-for-clj-macro
                                             (syntax->datum macro-arg)))
                                          #'(macro-args (... ...))))
                           (dummy (dbg "defmacro clj-args\n"))
                           (dummy (for-each (lambda (x) (dbg "  ~s\n" x))
                                            clj-args))
                           (code (apply xform clj-args))
                           (dummy (dbg "defmacro generated code\n"))
                           (dummy (dbg "~s\n" code))
                           (code (/lokke/convert-form-from-clj-macro code))
                           (dummy (dbg "defmacro final scheme ~s\n" code))
                           (code (datum->syntax x code)))
                      code)))))
             (export name)))))))
