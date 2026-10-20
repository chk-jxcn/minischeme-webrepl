;;; combo.scm - a combined app: pages of several apps in one carousel
;;;
;;; The WebREPL's 合并应用 (or tools/build_apps.py for apps/<id>/meta.ini with
;;; [combo] members) puts applib, this file, then each member app's code
;;; followed by (combo-member! "weather" '("front" ...) '(("location" . "auto") ...))
;;; (its English page names and its meta.ini defaults), and (combo-start!) at
;;; the end, into one app.
;;;
;;; - A member's (app-define! title pages) is recorded, not started, and its
;;;   hooks (subtitle, tick, data, long press, views, empty pages) are kept
;;;   per member; the global hooks are cleared for the next member.
;;; - config "entries" lists the pages to show in order, comma separated:
;;;   <app>.<page>, the page an English name of the app's meta.ini page_ids
;;;   (weather.sevendays), front (its first page), a number (1 first) or the
;;;   page's own name; or a view the app declares with app-view!:
;;;   wxpusher.news[0] (its newest message). Empty: every page of every member.
;;; - Each entry becomes a page of this app, so applib's carousel, page turns,
;;;   prefetch and per-URL cache work as in any app. While a member's code
;;;   runs (its URL, render, hooks) app-page-index is its own page number and
;;;   app-config reads the member's own config.ini ((config-get key id),
;;;   firmware with combined apps; never run alone: its meta.ini defaults).
;;; - Short press: next entry. Long press: the entry app's own long press.

(define combo-members '())       ; #(id title pages subtitle tick data long views empty ids defaults has-ini)
(define combo-pending #f)        ; (title . pages) of the member being loaded
(define combo-entries (vector))  ; per page of this app: #(member local-page view-proc view-index)
(define combo-ctx #f)            ; the member whose code runs now, #f this app's own
(define combo-index #f)          ; this app's page index while a member's code runs

(define combo-applib-define! app-define!)
(define combo-applib-config app-config)
(define combo-applib-start-feed! app-start-feed!)
(define combo-applib-set-url! app-set-url!)
(define combo-default-button app-button)
(define app-long-press #f)       ; a member may define its own: kept per member

;; A member's app-define!: recorded (combo-member! keeps it)
(define (app-define! title pages) (set! combo-pending (cons title pages)))

(define (combo-id m) (vector-ref m 0))
(define (combo-title m) (vector-ref m 1))
(define (combo-pages m) (vector-ref m 2))

;; A member's setting, as the app gets it when it runs alone: its own
;; config.ini (a key empty there: config.ini's), else the default its code
;; gives; a member that never ran alone has no config.ini yet: its meta.ini
;; defaults stand in for it (as the file the firmware would write from them)
(define (combo-nonempty v) (and (string? v) (> (string-length v) 0) v))

(define (app-config key default)
  (if (not combo-ctx)
      (combo-applib-config key default)
      (let* ((m combo-ctx)
             (d (and (not (vector-ref m 11)) (assoc key (vector-ref m 10))))
             (v (or (and d (combo-nonempty (cdr d)))
                    (combo-nonempty (config-get key (combo-id m))))))
        (or v default))))

;; Runs thunk as the member's code: its page number, its settings
(define (combo-in m local thunk)
  (let ((saved-index app-page-index) (saved-ctx combo-ctx) (saved-combo combo-index))
    (set! combo-index (if combo-index combo-index app-page-index))
    (set! combo-ctx m)
    (set! app-page-index local)
    (let ((r (thunk)))
      (set! app-page-index saved-index)
      (set! combo-ctx saved-ctx)
      (set! combo-index saved-combo)
      r)))

;; A member restarting its page's fetch: this app's page, not the member's number
(define (app-start-feed!)
  (if combo-index
      (let ((local app-page-index))
        (set! app-page-index combo-index)
        (combo-applib-start-feed!)
        (set! app-page-index local))
      (combo-applib-start-feed!)))

;; A member changing its page i's URL: every entry showing that page
(define (app-set-url! i url)
  (if combo-ctx
      (let ((m combo-ctx) (local app-page-index))
        (if combo-index (set! app-page-index combo-index))
        (let loop ((k 0))
          (if (< k (vector-length combo-entries))
              (let ((e (vector-ref combo-entries k)))
                (if (and (eq? (vector-ref e 0) m) (= (vector-ref e 1) i))
                    (combo-applib-set-url! k url))
                (loop (+ k 1)))))
        (set! app-page-index local))
      (combo-applib-set-url! i url)))

;; After each member's code: keep what it defined, clear the hooks
(define (combo-member! id ids defaults)
  (let ((title (if combo-pending (car combo-pending) id))
        (pages (if combo-pending (list->vector (cdr combo-pending)) (vector))))
    (set! combo-members
          (append combo-members
                  (list (vector id title pages app-subtitle-proc app-tick-proc app-data-proc
                                app-long-press app-views app-render-empty-pages ids defaults
                                (and (defined? 'app-has-config?) (app-has-config? id))))))
    (set! combo-pending #f)
    (set! app-subtitle-proc #f)
    (set! app-header-proc #f)
    (set! app-tick-proc #f)
    (set! app-data-proc #f)
    (set! app-long-press #f)
    (set! app-views '())
    (set! app-render-empty-pages '())
    (set! app-button combo-default-button)))

(define (combo-find-member id)
  (let loop ((ms combo-members))
    (cond ((null? ms) #f)
          ((string=? (combo-id (car ms)) id) (car ms))
          (else (loop (cdr ms))))))

;; The first position of character ch in s at or after start, else #f
(define (combo-char-pos s ch start)
  (let loop ((i start))
    (cond ((>= i (string-length s)) #f)
          ((char=? (string-ref s i) ch) i)
          (else (loop (+ i 1))))))

(define (combo-trim s)
  (let loop ((a 0) (b (string-length s)))
    (cond ((and (< a b) (char=? (string-ref s a) #\space)) (loop (+ a 1) b))
          ((and (< a b) (char=? (string-ref s (- b 1)) #\space)) (loop a (- b 1)))
          (else (substring s a b)))))

(define (combo-position x lst)
  (let loop ((l lst) (k 0))
    (cond ((null? l) #f) ((string=? (car l) x) k) (else (loop (cdr l) (+ k 1))))))

;; The page of member m called rest: an English page name, front, a number
;; (1 first) or the page's own name; #f when none
(define (combo-page-of m rest)
  (let* ((pages (combo-pages m)) (n (vector-length pages)) (named (combo-position rest (vector-ref m 9))))
    (cond ((string=? rest "front") (and (> n 0) 0))
          (named (and (< named n) named))
          ((string->number rest) (let ((k (- (string->number rest) 1))) (and (>= k 0) (< k n) k)))
          (else (let loop ((k 0))
                  (cond ((>= k n) #f)
                        ((string=? (vector-ref (vector-ref pages k) 0) rest) k)
                        (else (loop (+ k 1)))))))))

;; "weather.sevendays" / "stocks.front" / "wxpusher.news[0]" -> an entry, #f
;; when the app or the page is unknown
(define (combo-parse spec)
  (let* ((s (combo-trim spec)) (dot (combo-char-pos s #\. 0))
         (m (and dot (combo-find-member (substring s 0 dot))))
         (rest (if dot (substring s (+ dot 1) (string-length s)) "")))
    (and m
         (let* ((open (combo-char-pos rest #\[ 0))
                (close (and open (combo-char-pos rest #\] open))))
           (if (and open close)          ; a view
               (let* ((name (substring rest 0 open))
                      (idx (or (string->number (substring rest (+ open 1) close)) 0))
                      (v (let loop ((vs (vector-ref m 7)))
                           (cond ((null? vs) #f) ((string=? (car (car vs)) name) (car vs)) (else (loop (cdr vs)))))))
                 (and v (< (cadr v) (vector-length (combo-pages m))) (vector m (cadr v) (caddr v) idx)))
               (let ((k (combo-page-of m rest)))
                 (and k (vector m k #f 0))))))))

;; Every page of every member, in order (entries left empty)
(define (combo-all-entries)
  (let loop ((ms combo-members) (acc '()))
    (if (null? ms)
        (reverse acc)
        (loop (cdr ms)
              (let pages ((k 0) (acc acc))
                (if (< k (vector-length (combo-pages (car ms))))
                    (pages (+ k 1) (cons (vector (car ms) k #f 0) acc))
                    acc))))))

;; The entry's name in the header: its page's name (and the view's number)
(define (combo-entry-name e)
  (let ((page (vector-ref (combo-pages (vector-ref e 0)) (vector-ref e 1))))
    (if (vector-ref e 2)
        (string-append (vector-ref page 0) " " (number->string (+ (vector-ref e 3) 1)))
        (vector-ref page 0))))

;; The entry as a page of this app: the member's URL, interval and render
;; (or its view), each run as the member's code
(define (combo-entry-page e)
  (let* ((m (vector-ref e 0)) (local (vector-ref e 1)) (page (vector-ref (combo-pages m) local))
         (view (vector-ref e 2)) (vi (vector-ref e 3)))
    (vector (combo-entry-name e)
            (lambda () (combo-in m local (lambda () ((vector-ref page 1)))))
            (vector-ref page 2)
            (lambda (items)
              (combo-in m local (lambda () (if view (view items vi) ((vector-ref page 3) items))))))))

(define (combo-cur) (vector-ref combo-entries app-page-index))

;; Header: the entry's app and the page (or the app's own subtitle on its first page)
(define (app-header-title items) (combo-title (vector-ref (combo-cur) 0)))

(define (app-header-sub items)
  (let* ((e (combo-cur)) (m (vector-ref e 0)) (sub (vector-ref m 3)))
    (if (and sub items (= (vector-ref e 1) 0) (not (vector-ref e 2)))
        (or (combo-in m 0 (lambda () (sub items))) (combo-entry-name e))
        (combo-entry-name e))))

;; The document that arrived belongs to the entries with its URL: their app's data hook
(define (combo-data items)
  (let ((url (json-feed-url)))
    (let loop ((k 0) (seen '()))
      (if (< k (vector-length combo-entries))
          (let* ((e (vector-ref combo-entries k)) (m (vector-ref e 0)) (proc (vector-ref m 5)))
            (if (and proc (equal? (vector-ref app-urls k) url) (not (memq m seen)))
                (begin (combo-in m (vector-ref e 1) (lambda () (proc items)))
                       (loop (+ k 1) (cons m seen)))
                (loop (+ k 1) seen)))))))

;; Every second: the shown entry's app
(define (combo-tick tick)
  (if (> (vector-length combo-entries) 0)
      (let* ((e (combo-cur)) (m (vector-ref e 0)) (proc (vector-ref m 4)))
        (if proc (combo-in m (vector-ref e 1) (lambda () (proc tick)))))))

(define (combo-long-press)
  (let* ((e (combo-cur)) (m (vector-ref e 0)) (proc (vector-ref m 6)))
    (if proc (combo-in m (vector-ref e 1) proc))))

;; The pages entries lists (unknown ones left out; empty: all of them)
(define (combo-start! title)
  (let* ((specs (filter (lambda (s) (> (string-length (combo-trim s)) 0))
                        (str-split (app-config "entries" "") #\,)))
         (entries (if (null? specs)
                      (combo-all-entries)
                      (filter (lambda (e) e) (map combo-parse specs)))))
    (set! combo-entries (list->vector entries))
    (set! app-index-always #t)
    (set! app-data-proc combo-data)
    (set! app-tick-proc combo-tick)
    (set! app-long-press combo-long-press)   ; after the members: wxpusher defines its own
    ;; entries drawn before their data: their app's local or empty-drawn pages
    (set! app-render-empty-pages
          (let loop ((k 0) (acc '()))
            (if (< k (vector-length combo-entries))
                (let ((e (vector-ref combo-entries k)))
                  (loop (+ k 1) (if (memv (vector-ref e 1) (vector-ref (vector-ref e 0) 8)) (cons k acc) acc)))
                acc)))
    (if (null? entries)
        (combo-applib-define! title
                              (list (app-local-page "合集"
                                                    (lambda (items)
                                                      (txt-wrap 16 (+ HDR-H 20) (- (scr-w) 32) 200
                                                                "没有可显示的页面：本应用设置里的 entries 写的应用或页面不存在，例如 weather.front, calendar.today, wxpusher.news[0]"
                                                                theme-warning)))))
        (combo-applib-define! title (map combo-entry-page entries)))))
