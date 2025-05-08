;;; init-2.scm
;;; This file is run through the interpreter created from init-1.scm

;; Regular (non-named) let
(define-syntax let
  (ir-macro-transformer
    (lambda (expr inject compare)
      (define args (cadr expr))
      (define body (cddr expr))
      `((lambda (,@(map car args)) ,@body) ,@(map cadr args)))))

(let ([x 3] [y 2])
  (+ x x y))

(define-syntax or
  (ir-macro-transformer
    (lambda (expr inject compare)
      (define args (cdr expr))
      (if (null? args)
        #f
        `(let ([tmp ,(car args)])
           (if tmp tmp (or ,@(cdr args))))))))

(or #f 2 1)
