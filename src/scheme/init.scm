(define (map f ls)
  (if (null? ls)
    '()
    (cons (f (car ls)) (map f (cdr ls)))))

(define (qq-expand1-term t)
  (if (symbol? t)
    (list 'quote t)
    (if (pair? t)
      (qq-expand1-list t)
      t)))

(define (qq-expand1-list ls)
  (define head (car ls))
  (if (eq? head 'quote)
    ls
    (if (eq? head 'unquote)
      (cons 'values (cdr ls))
      (if (eq? head 'unquote-splicing)
        (cons 'apply (cons 'values (cdr ls)))
        (cons 'list (map qq-expand1-term ls))))))

(define (qq-expand1 expr)
  (if (pair? expr)
    (if (eq? (car expr) 'quasiquote)
      (qq-expand1-term (car (cdr expr)))
      (map qq-expand1 expr))
    expr))

(qq-expand1 '`(+ 1 2 ,(+ 3 4)))
(qq-expand1 '`(a ,(+ 1 2) ,@(map abs '(4 -5 6)) b))

