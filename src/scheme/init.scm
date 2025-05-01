;;; init.scm
;;; This file contains enough code to bootstrap eval and the macro expander
;;; We only have access to the definitions from builtins.scm.
;;; In particular, we don't yet have and macros like let, cond, case ...
;;; so some definitions are fairly ugly.

;;; The definitions here are not necessarily fault tolerant, so may be
;;; redefined in a later file

;;; ~~ Some useful list manipulations (srfi-1) ~~
(define (cadr x) (car (cdr x)))
(define (cddr x) (cdr (cdr x)))
(define (caddr x) (car (cdr (cdr x))))
(define (cdddr x) (cdr (cdr (cdr x))))

(define (map f ls)
  (if (null? ls)
    '()
    (cons (f (car ls)) (map f (cdr ls)))))

(define (find-tail proc ls)
  (if (pair? ls)
    (if (proc (car ls))
      ls
      (find-tail proc (cdr ls)))
    #f))

(define (find proc ls)
  (define tail (find-tail proc ls))
  (if tail (car tail) #f))

(define (assv key alist)
  (find (lambda (p) (eqv? (car p) key)) alist))

(define (assq key alist)
  (find (lambda (p) (eq? (car p) key)) alist))

(define (assoc key alist cmp)
  (find (lambda (p) (cmp (car p) key)) alist))

(define (qq-expand-term t)
  (if (symbol? t)
    (list 'quote t)
    (if (pair? t)
      (qq-expand-list t)
      t)))

(define (qq-expand-list ls)
  (define head (car ls))
  (if (eq? head 'quote)
    ls
    (if (eq? head 'unquote)
      (cons 'values (cdr ls))
      (if (eq? head 'unquote-splicing)
        (cons 'apply (cons 'values (cdr ls)))
        (cons 'list (map qq-expand-term ls))))))

(define (qq-expand expr)
  (if (pair? expr)
    (if (eq? (car expr) 'quasiquote)
      (qq-expand-term (car (cdr expr)))
      (map qq-expand expr))
    expr))

;;; ~~ Identifiers ~~
(define identifier (make-struct-type 'identifier 'symbol 'scope))
(define (identifier-symbol x) (struct-ref x 0))
(define (identifier-scope x) (struct-ref x 1))

(define (preidentifier? x) 
  (if (symbol? x)
    #t
    (eq? (struct-type x) identifier)))
(define (identifier? x)
  (eq? (struct-type x) identifier))

(define (bound-identifier=? a b)
  (if (eq? (struct-ref a 0) (struct-ref b 0))
    (eqv? (struct-ref a 1) (struct-ref b 1))
    #f))

;; http://www.phyast.pitt.edu/~micheles/scheme/scheme30.html
;; The standard mandates free-identifier=?, but that's weird.
(define (symbol-identifier=? a b)
  (define (unwrap x) (if (identifier? x) (identifier-symbol x) x))
  (eq? (unwrap a) (unwrap b)))

;;; ~~ Macros (i.e. bound transformers) ~~
(define macro (make-struct-type 'macro 'transformer 'env))
(define (macro-transformer x) (struct-ref x 0))
(define (macro-env x) (struct-ref x 1))
(define (macro? x) (eq? (struct-type x) macro))

;;; ~~ The macro expander ~~
;;; This runs in steps, roughly as in the KFFD algorithm:
;;;  - Add scope markings for the whole expression
;;;  - Recursively expand macros, adding scopes for new identifiers
;;;  - Replace bound identifiers from macros with gensyms
;;;  - Replace unbound identifiers from macros with lookups

;; Macro expander state (this should be local to macroexpand)
(define j 0)
(define (reset-timestamp) (set! j 0))
(define (next-timestamp) (set! j (+ j 1)))

;; assv map scopes -> environments
(define envs ())

;; Mark all symbols in expression as identifiers with scope
(define (add-scope expr scope)
  (if (pair? expr)
    (cons (add-scope (car expr) scope) (add-scope (cdr expr) scope))
    (if (symbol? expr)
      (make-struct identifier expr scope)
      expr)))

(define (form? expr label)
  (if (pair? expr)
    (begin
      (define first (car expr))
      (if (eq? first label)
        #t
        (if (identifier? first)
          (eq? (struct-ref first 0) label)
          #f)))
    #f))

(define (lookup-macro expr)
  (if (pair? expr)
    (if (identifier? (car expr))
      (begin
        (define env (cdr (assv (identifier-scope (car expr)) envs)))
        (define value (env-ref env (identifier-symbol (car expr)) #f))
        (if (macro? value)
          value
          #f))
      #f)
    #f))
         
(define (print . x) (map display x) (newline))

(define (expand expr)
  (if (pair? expr)
    (begin
      (define macro (lookup-macro expr))
      (if macro
        (begin
          (define macro-env (next-timestamp))
          (set! envs (cons (cons macro-env (struct-ref macro 1)) envs))
          (expand ((macro-transformer macro) expr 0 macro-env)))
        (map expand expr)))
    expr))

(define (new-bindings args current) 
  (append (map (lambda (s) (cons s (gensym))) args) current))

(define (unstamp-identifier id bindings)
  (if (= (identifier-scope id) 0)
    (identifier-symbol id)
    (begin
      (define gensym-name (assoc id bindings bound-identifier=?))
      (if gensym-name
        (cdr gensym-name)
        (list 'env-ref (cdr (assv (struct-ref (car expr) 1) envs)) (struct-ref id 0))))))

(define (unstamp expr bindings)
  (if (form? expr 'lambda)
    (begin
      (define new (new-bindings (cadr expr) bindings))
      (list 'lambda (unstamp (cadr expr) new) (apply values (unstamp (cddr expr) new))))
    (if (pair? expr)
      (map (lambda (v) (unstamp v bindings)) expr)
      (if (eq? (struct-type expr) identifier)
        (unstamp-identifier expr bindings)
        expr))))

(define (macroexpand expr env)
  (set! envs (list (cons 0 env)))
  (print 'input: expr)
  (set! expr (add-scope expr (reset-timestamp)))
  ;(print 'timestamped: expr)
  (set! expr (expand expr))
  ;(print 'expanded: expr)
  (set! expr (unstamp expr ()))
  (print 'unstamped: expr)
  expr)  
   
(define gensym
  ;; Massive hack for testing right now
  (begin
    (define pool '(g0 g1 g2 g3 g4 g5 g6 g7))
    (lambda ()
      (define s (car pool))
      (set! pool (cdr pool))
      s)))


(define (er-macro-transformer f)
  (lambda (expr caller-env macro-env)
    (define (rename x) (add-scope x macro-env))
    (add-scope
      (f expr rename symbol-identifier=?)
      caller-env)))

(define (ir-macro-transformer f)
  (lambda (expr caller-env macro-env)
    (define (inject x) (add-scope x caller-env))
    (add-scope
      (f expr inject symbol-identifier=?)
      macro-env)))

(define let1t (ir-macro-transformer
               (lambda (expr inject compare)
                 (define sym (cadr expr))
                 (define value (caddr expr))
                 (define body (cdddr expr))
                 (list (list 'lambda (list sym) (apply values body)) value))))

(define let1 (make-struct macro let1t (current-env)))

(define ort (er-macro-transformer
              (lambda (expr rename compare)
                (define first (cadr expr))
                (define rest (cddr expr))
                (define x (rename 'x))
                (if (null? rest)
                  first
                  (list 'let1 x first (list 'if x x (cons 'or rest)))))))

(define or (make-struct macro ort (current-env)))

(macroexpand source (current-env))
(macroexpand 'a (current-env))
(macroexpand '(or (a) (b) (c)) (current-env))

(define (eval expr env)
  ((compile (macroexpand (qq-expand expr) env) env)))

(eval
  '(or (> 2 3) 10)
  (current-env))

