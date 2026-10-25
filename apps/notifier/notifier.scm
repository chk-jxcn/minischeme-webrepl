;;; =========================================================================
;;; Notifier (消息提示器), 320x480 portrait, on the app framework (applib.scm).
;;; Messages come two ways and are kept on the board (notifier.txt in its folder,
;;; the newest "keep" of them, 30 by default):
;;;   - pushed to the app proxy (GET/POST /notify?text=..&title=..&level=..; a
;;;     public server: mac=<device id>&password=<its app service password>),
;;;     which keeps all of them (its user portal lists and deletes them) and
;;;     which this app polls at /app/notifier?n=<keep> every 5 s;
;;;   - straight to the board: its web page's app tab, or
;;;     POST /api/app/call?fn=notify (title, text, level, from).
;;; A new message turns to page 1 and blinks the LED (urgent: until read);
;;; a short press marks everything read, then turns pages. Each new message is
;;; also an alert (applib section 9) over any page, in a combined app too:
;;; urgent priority 8 until a press, warn 6 and info 4 also closing by
;;; themselves (60 s, 30 s); a short press on it reads that message.
;;;   1 the newest message   2 all messages
;;; File: first line "P|<last proxy id>", then "id|pid|level|read|time|from|title|text".
;;; An app may touch only its own folder: relative paths are in it.
;;; =========================================================================

(define NOTE-PATH "notifier.txt")        ; in the app's own folder
(define (note-keep) (clamp (or (string->number (app-config "keep" "30")) 30) 5 200))   ; messages kept here
(define NOTE-INTERVAL 5000)

(define note-list '())                  ; #(id pid level read time from title text), newest first
(define note-last-pid 0)                ; the newest proxy message taken
(define note-alert 0)                   ; seconds of LED blinking left; -1: until read (urgent)
(define note-synced #f)                 ; a proxy document arrived since the start

;; 1. Storage ---------------------------------------------------------------------------------

(define (note-id m) (vector-ref m 0))
(define (note-pid m) (vector-ref m 1))
(define (note-level m) (vector-ref m 2))
(define (note-read? m) (vector-ref m 3))
(define (note-time m) (vector-ref m 4))
(define (note-from m) (vector-ref m 5))
(define (note-title m) (vector-ref m 6))
(define (note-text m) (vector-ref m 7))

;; The positions of the first n "|" in line, or #f
(define (note-bars line n)
  (let loop ((i 0) (acc '()))
    (cond ((= (length acc) n) (reverse acc))
          ((>= i (string-length line)) #f)
          ((char=? (string-ref line i) #\|) (loop (+ i 1) (cons i acc)))
          (else (loop (+ i 1) acc)))))

(define (note-parse line)
  (let ((b (note-bars line 7)))
    (if (not b)
        #f
        (let ((field (lambda (k)
                       (substring line (if (= k 0) 0 (+ 1 (list-ref b (- k 1))))
                                  (if (= k 7) (string-length line) (list-ref b k))))))
          (vector (or (string->number (field 0)) 0) (or (string->number (field 1)) 0) (field 2)
                  (string=? (field 3) "1") (field 4) (field 5) (field 6) (field 7))))))

(define (note-load!)
  (let ((text (and (fs-exists? NOTE-PATH) (fs-read NOTE-PATH))))
    (set! note-list '())
    (if (string? text)
        (for-each (lambda (line)
                    (if (str-starts? line "P|")
                        (set! note-last-pid (or (string->number (substring line 2 (string-length line))) 0))
                        (let ((m (note-parse line))) (if m (set! note-list (append note-list (list m)))))))
                  (str-split text #\newline)))))

;; "|" would end a field early: only the text (the last field) may hold it
(define (note-safe s)
  (list->string (map (lambda (c) (if (or (char=? c #\|) (char=? c #\newline) (char=? c #\return)) #\space c))
                     (string->list (or s "")))))

(define (note-line m)
  (string-append (number->string (note-id m)) "|" (number->string (note-pid m)) "|" (note-level m) "|"
                 (if (note-read? m) "1" "0") "|" (note-time m) "|" (note-from m) "|" (note-title m) "|"
                 (note-text m)))

(define (note-save!)
  (fs-write NOTE-PATH (web-join (cons (string-append "P|" (number->string note-last-pid)) (map note-line note-list))
                                (list->string (list #\newline))))
  (app-invalidate-all))

(define (note-next-id)
  (+ 1 (let loop ((l note-list) (hi 0)) (if (null? l) hi (loop (cdr l) (max hi (note-id (car l))))))))

(define (note-unread) (length (filter (lambda (m) (not (note-read? m))) note-list)))

(define (note-level-ok level) (if (member level '("info" "warn" "urgent")) level "info"))

;; A new message, newest first; alert unless quiet
(define (note-add! pid level time from title text quiet)
  (let* ((cut (lambda (s n) (if (> (string-length s) n) (substring s 0 n) s)))
         (m (vector (note-next-id) pid (note-level-ok level) quiet (note-safe time) (note-safe (cut from 30))
                    (note-safe (cut title 60)) (note-safe (cut text 400)))))
    (set! note-list (cons m note-list))
    (if (> (length note-list) (note-keep)) (set! note-list (take note-list (note-keep))))
    (if (not quiet)
        (begin
          (set! note-alert (if (string=? (note-level m) "urgent") -1 20))
          (if (not (= app-page-index 0)) (app-goto! 0))
          (note-raise-alert! m)))
    m))

(define (note-alert-key m) (string-append "n" (number->string (note-id m))))

;; One message read (its alert's short press); the LED stops with the last one
(define (note-read-one! m)
  (vector-set! m 3 #t)
  (if (= (note-unread) 0) (begin (set! note-alert 0) (ws2812-clear)))
  (note-save!))

(define (note-render-alert m)
  (let ((y (+ (body-top) 6)))
    (note-badge 10 y m)
    (txt-right 310 (+ y 3) (note-meta-text m) theme-text-muted)
    (txt-wrap 10 (+ y 32) 300 44 (if (str-empty? (note-title m)) "（无标题）" (note-title m)) theme-accent)
    (txt-wrap 10 (+ y 82) 300 (- (body-bottom) y 86) (note-text m) theme-text-main)))

(define (note-raise-alert! m)
  (let ((l (note-level m)))
    (app-alert! (note-alert-key m) (car (note-level-badge m)) (lambda () (note-render-alert m))
                (list (cons 'ack (lambda () (note-read-one! m)))
                      (cons 'priority (cond ((string=? l "urgent") 8) ((string=? l "warn") 6) (else 4)))
                      (cons 'exit (if (string=? l "urgent") 'button 'both))
                      (cons 'seconds (if (string=? l "warn") 60 30))))))

(define (note-mark-read!)
  (for-each (lambda (m) (vector-set! m 3 #t) (app-alert-done! (note-alert-key m))) note-list)
  (set! note-alert 0)
  (ws2812-clear)
  (note-save!))

(define (note-now) (if (string=? app-time "--:--") "" app-time))

;; 2. The proxy's messages -----------------------------------------------------------------------

;; Each new document: messages with ids past the last taken one, oldest first.
;; The proxy's ids start again at 1 when it restarts (its counter fell back).
(define (note-data! items)
        (let* ((meta (items-find items "meta")) (seq (if meta (or (it-int meta 1) 0) 0))
               (first-sync (and (not note-synced) (= note-last-pid 0) (null? note-list))))
          (set! note-synced #t)
          (if (< seq note-last-pid) (set! note-last-pid 0))
          (let ((fresh (filter (lambda (it) (> (or (it-int it 1) 0) note-last-pid)) (reverse (items-all items "msg")))))
            (if (pair? fresh)
                (begin
                  (for-each (lambda (it)
                              (note-add! (it-int it 1) (it-d it) (str-part (it-e it) #\space 0)
                                         (let ((e (it-e it))) (if (> (string-length e) 6) (substring e 6 (string-length e)) ""))
                                         (it-b it) (it-c it) first-sync))   ; on a first start: no alarm for old ones
                            fresh)
                  (set! note-last-pid (list-max (map (lambda (it) (it-int it 1)) fresh)))
                  (note-save!))))))

(set! app-data-proc note-data!)

;; 3. The screen ------------------------------------------------------------------------------

(define (note-level-badge m)
  (let ((l (note-level m)))
    (cond ((string=? l "urgent") (list "紧急" theme-danger))
          ((string=? l "warn") (list "提醒" theme-warning))
          (else (list "通知" theme-accent)))))

(define (note-badge x y m)
  (let* ((b (note-level-badge m)) (w (+ (txt-w (car b)) 12)))
    (gui-round-rect x y w 22 5 (cadr b) (not (note-read? m)))
    (txt (+ x 6) (+ y 3) (car b) (if (note-read? m) (cadr b) theme-bg))
    w))

(define (note-meta-text m)
  (string-append (note-time m) (if (str-empty? (note-from m)) "" (string-append "  " (note-from m)))))

(define (note-hint)
  (if (wifi-connected?)
      (string-append "发送：浏览器打开 http://" (wifi-ip) "/ ，或向代理的 /notify 推送")
      "连接 WiFi 后，从网页或代理的 /notify 推送消息"))

(define (note-render-latest items)
  (if (null? note-list)
      (begin
        (txt 14 70 "暂无消息" theme-text-muted)
        (txt-wrap 14 100 (- (scr-w) 28) 80 (note-hint) theme-text-sub))
      (let* ((m (car note-list)) (y (+ (body-top) 6)) (w (note-badge 10 y m)))
        (txt-right 310 (+ y 3) (note-meta-text m) theme-text-muted)
        (txt-fit 10 (+ y 32) 300 (if (str-empty? (note-title m)) "（无标题）" (note-title m))
                 (if (note-read? m) theme-text-main theme-accent))
        (gui-round-rect 10 (+ y 60) 300 200 8 theme-card-border #f)
        (txt-wrap 20 (+ y 70) 280 180 (note-text m) theme-text-main)
        (let loop ((l (cdr note-list)) (yy (+ y 272)) (i 0))
          (if (and (pair? l) (< i 3))
              (let ((o (car l)))
                (txt 10 yy (note-time o) theme-text-muted)
                (txt-fit 64 yy 246 (string-append (if (str-empty? (note-title o)) "" (string-append (note-title o) "：")) (note-text o))
                         (if (note-read? o) theme-text-sub theme-text-main))
                (loop (cdr l) (+ yy 26) (+ i 1))))))))

(define (note-render-all items)
  (if (null? note-list)
      (txt 14 70 "暂无消息" theme-text-muted)
      (let loop ((l note-list) (y (+ (body-top) 2)) (i 0))
        (if (and (pair? l) (< i 8))
            (let ((m (car l)))
              (if (gui-visible? y 50)
                  (begin
                    (note-badge 10 y m)
                    (txt-fit 64 (+ y 2) 170 (if (str-empty? (note-title m)) (note-text m) (note-title m))
                             (if (note-read? m) theme-text-sub theme-text-main))
                    (txt-right 310 (+ y 2) (note-time m) theme-text-muted)
                    (txt-fit 10 (+ y 26) 300 (note-text m) theme-text-muted)
                    (gui-line 10 (+ y 49) 310 (+ y 49) theme-divider)))
              (loop (cdr l) (+ y 52) (+ i 1)))))))

;; 4. Alert, button --------------------------------------------------------------------------------

(set! app-tick-proc
      (lambda (tick)
        (if (not (= note-alert 0))
            (begin
              (if (= (remainder tick 2) 0)
                  (if (= note-alert -1) (ws2812-set 255 0 0) (ws2812-set 255 140 0))
                  (ws2812-clear))
              (if (> note-alert 0)
                  (begin (set! note-alert (- note-alert 1))
                         (if (= note-alert 0) (ws2812-clear))))))))

;; A short press first marks everything read
(set! app-button
      (lambda ()
        (if (> (note-unread) 0) (note-mark-read!) (app-next-page!))))

(set! app-subtitle-proc
      (lambda (items)
        (let ((n (note-unread))) (if (> n 0) (string-append "未读 " (number->string n)) #f))))

;; 5. The web page's calls --------------------------------------------------------------------------

(define (note->alist m)
  (list (cons 'id (note-id m)) (cons 'level (note-level m)) (cons 'read (note-read? m)) (cons 'time (note-time m))
        (cons 'from (note-from m)) (cons 'title (note-title m)) (cons 'text (note-text m))))

(define (note-answer)
  (web-ok (cons 'messages (map note->alist note-list)) (cons 'unread (note-unread)) (cons 'proxy (app-proxy))))

(define (app-web name body)
  (cond
    ((string=? name "list") (note-answer))
    ((string=? name "notify")
     (let ((text (or (web-field body "text") "")) (title (or (web-field body "title") "")))
       (if (and (str-empty? text) (str-empty? title))
           (web-error "empty message")
           (begin
             (note-add! 0 (or (web-field body "level") "info") (note-now) (or (web-field body "from") "") title text #f)
             (note-save!)
             (note-answer)))))
    ((string=? name "read") (note-mark-read!) (note-answer))
    ((string=? name "delete")
     (let ((id (web-field-int body "id" -1)))
       (set! note-list (filter (lambda (m) (not (= (note-id m) id))) note-list))
       (note-save!)
       (note-answer)))
    ((string=? name "clear")
     (set! note-list '())
     (set! note-alert 0)
     (ws2812-clear)
     (note-save!)
     (note-answer))
    (else (web-error (string-append "unknown call: " name)))))

;; 6. Start ------------------------------------------------------------------------------------------

(note-load!)
(set! app-render-empty-pages '(0 1))    ; drawn from the board's own list, also without the proxy

(define (note-url) (app-url (string-append "/app/notifier?n=" (number->string (min 50 (note-keep))))))

(app-watch! note-url 15000 note-data!)   ; new messages also while another app's page shows

(app-define! "消息提示"
  (list (app-page "最新" note-url NOTE-INTERVAL note-render-latest)
        (app-page "全部" note-url NOTE-INTERVAL note-render-all)))
