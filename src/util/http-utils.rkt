#lang racket/base
;; HTTP utilities

(provide http-redirection-limit
         http-classify-status-code
         http-interpret-response
         http-simple-interpret-response
         http-follow-redirects
         http-sendrecv/url

         http/interpret-response
         http/simple-interpret-response
         http/follow-redirects)

(require (only-in racket/port port->bytes))
(require (only-in racket/bytes bytes-join))
(require racket/match)
(require net/http-client)
(require net/head)
(require (except-in net/url http-sendrecv/url))

;; (Parameterof Number)
;; Number of redirections to automatically follow when retrieving via GET or HEAD.
(define http-redirection-limit (make-parameter 20))

;; Number -> Symbol
;; Returns the broad classification associated with a given HTTP status code.
(define (http-classify-status-code status-code)
  (cond
    [(<= status-code 99) 'unknown]
    [(<= 100 status-code 199) 'informational]
    [(<= 200 status-code 299) 'success]
    [(<= 300 status-code 399) 'redirection]
    [(<= 400 status-code 499) 'client-error]
    [(<= 500 status-code 599) 'server-error]
    [(<= 600 status-code) 'unknown]))

(define (parse-status-line status-line)
  (match status-line
    [(regexp #px#"^([^ ]+) ([^ ]+)( (.*))?$" (list _ v c _ r))
     (values v (string->number (bytes->string/latin-1 c)) (bytes->string/latin-1 r))]
    [_
     (values #f #f #f)]))

(define (parse-headers response-headers [downcase-header-names? #t])
  (for/list [(h (extract-all-fields (bytes-join response-headers #"\r\n")))]
    (cons (string->symbol ((if downcase-header-names? string-downcase values)
                           (bytes->string/latin-1 (car h))))
          (cdr h))))

;; <customizations ...>
;; -> Bytes (Listof Bytes) InputPort
;; -> (Values (Option Bytes)
;;            (Option Number)
;;            (Option String)
;;            (Listof (Cons Symbol Bytes))
;;            (if read-body? Bytes InputPort))
(define ((http-interpret-response #:downcase-header-names? [downcase-header-names? #t]
                                  #:read-body? [read-body? #t])
         status-line response-headers response-body-port)
  (define-values (http-version status-code reason-phrase) (parse-status-line status-line))
  (values http-version
          status-code
          reason-phrase
          (parse-headers response-headers downcase-header-names?)
          (if read-body?
              (begin0 (port->bytes response-body-port)
                (close-input-port response-body-port))
              response-body-port)))

(define (http-simple-interpret-response status-line response-headers response-body-port)
  (define-values (_http-version
                  status-code
                  _reason-phrase
                  headers
                  body)
    ((http-interpret-response) status-line response-headers response-body-port))
  (values (http-classify-status-code status-code)
          headers
          body))

(define ((http-follow-redirects method
                                #:version [version #"1.1"])
         status-line
         response-headers
         response-body-port)
  (define ((check-response remaining-redirect-count)
           status-line
           response-headers
           response-body-port)
    (log-debug "http-follow-redirects: Checking request result: ~a\n" status-line)
    (define-values (http-version status-code reason-phrase) (parse-status-line status-line))
    (if (and (positive? remaining-redirect-count)
             (eq? (http-classify-status-code status-code) 'redirection))
        (match (assq 'location (parse-headers response-headers))
          [#f (values status-line response-headers response-body-port)]
          [(cons _location-header-label location-urlbytes)
           (define location (string->url (bytes->string/latin-1 location-urlbytes)))
           (void (port->bytes response-body-port)) ;; consume and discard input
           (close-input-port response-body-port)
           (log-debug "http-follow-redirects: Following redirection to ~a\n" location-urlbytes)
           (call-with-values (lambda () (http-sendrecv/url location
                                                           #:version version
                                                           #:method method))
                             (check-response (- remaining-redirect-count 1)))])
        (values status-line response-headers response-body-port)))
  ((check-response (http-redirection-limit))
   status-line
   response-headers
   response-body-port))

;; Already present in net/url, but that variant doesn't take #:version
;; or allow overriding of #:ssl? and #:port.
;;
;; Furthermore, currently 2016-08-14 there is a fd leak when using
;; method HEAD with `http-sendrecv` [1], so we implement our own crude
;; connection management here.
;;
;; [1] https://github.com/racket/racket/issues/1414
;;
(define (http-sendrecv/url u
                           #:ssl? [ssl? (equal? (url-scheme u) "https")]
                           #:port [port (or (url-port u) (if ssl? 443 80))]
                           #:version [version #"1.1"]
                           #:method [method #"GET"]
                           #:headers [headers '()]
                           #:data [data #f]
                           #:content-decode [decodes '(gzip)])
  (define hc (http-conn-open (url-host u) #:ssl? ssl? #:port port))
  (http-conn-send! hc (url->string u)
                   #:version version
                   #:method method
                   #:headers headers
                   #:data data
                   #:content-decode decodes
                   #:close? #t)
  (begin0 (http-conn-recv! hc #:method method #:content-decode decodes #:close? #t)
    (when (member method (list #"HEAD" "HEAD" 'HEAD))
      (http-conn-close! hc))))

(define-syntax-rule (http/interpret-response customization ... req-expr)
  (call-with-values (lambda () req-expr)
                    (http-interpret-response customization ...)))

(define-syntax-rule (http/simple-interpret-response req-expr)
  (call-with-values (lambda () req-expr)
                    http-simple-interpret-response))

(define-syntax-rule (http/follow-redirects customization ... req-expr)
  (call-with-values (lambda () req-expr)
                    (http-follow-redirects customization ...)))

(module+ test
  (require rackunit)

  (http/simple-interpret-response
   (http/follow-redirects
    #"HEAD"
    (http-sendrecv/url (string->url "http://google.com/") #:method #"HEAD")))
  )
