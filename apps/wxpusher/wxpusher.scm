;;; =========================================================================
;;; WxPusher receiver, 320x480 portrait, on the app framework (applib.scm).
;;; The app proxy (minischeme-proxy) is a WxPusher client device: it keeps
;;; the service's WebSocket and collects the messages pushed to the user's
;;; WeChat; this app polls them at /app/wxpusher every 5 s and keeps them on
;;; the board (wxpusher.txt in its folder). Without a login the proxy sends
;;; the login QR code (its modules), drawn here with gui-bitmap to scan with
;;; WeChat. A public proxy keeps one login per device (the encrypted channel
;;; names it); a local one, one for the boards of its network.
;;;   home: the messages: the subject (【新】 on the right while unread), under
;;;   it the topic on the left and the time on the right
;;;   short press: the full messages, newest to oldest, then home again
;;;   long press at home: everything read
;;;   long press on a message: unread -> read; already read -> home
;;;   a new message: an alert (applib section 9) shows it over any page, in a
;;;   combined app too (the feed is watched while another app shows); a short
;;;   press marks it read
;;; Messages deleted here (the web page) are deleted at the proxy too: the
;;; feed URL carries ?del=<ids> until a document from it arrives; the proxy
;;; drops them and deletes them on the WxPusher service. 退出登录 on the web
;;; page goes the same way: ?logout=1 until a document comes back.
;;; File: first line "L|<newest id taken>", then "D|<ids to delete at the
;;; proxy>" while there are any, then "id|read|time|title|text"; time is
;;; "MM-DD HH:MM", then after a space the topic (the item's "topic").
;;; An app may touch only its own folder: relative paths are in it.
;;; =========================================================================

(define WX-PATH "wxpusher.txt")         ; in the app's own folder
(define WX-MAX 20)
(define WX-INTERVAL 5000)
(define WX-ROW-H 46)
(define WX-WHITE 65535)
(define WX-BLACK 0)

(define wx-list '())                    ; #(id read time title text), newest first; ids are digit strings
(define wx-last "")                     ; the newest message id taken ("" none yet)
(define wx-view #f)                     ; #f: the list, else the id of the message shown
(define wx-state "")                    ; the proxy's: starting, login, ok, error ("" no data yet)
(define wx-info "")
(define wx-left 0)                      ; seconds the QR code stays valid
(define wx-qr-n 0)                      ; modules per side
(define wx-qr #f)                       ; the QR code as a 1-bit bitmap (gui-bitmap data), or #f
(define wx-qr-key "")                   ; the rows as sent: decoded again only when they change
(define wx-alert 0)                     ; seconds of LED blinking left
(define wx-del '())                     ; ids deleted here, not yet taken by the proxy
(define wx-logout #f)                   ; the web page's 退出登录, not yet taken by the proxy

;; 1. Storage ---------------------------------------------------------------------------------

(define (wx-id m) (vector-ref m 0))
(define (wx-read? m) (vector-ref m 1))
(define (wx-time m) (vector-ref m 2))           ; "MM-DD HH:MM topic"
(define WX-TIME-LEN 11)                         ; "MM-DD HH:MM"
(define (wx-clock m)
  (let ((t (wx-time m))) (if (> (string-length t) WX-TIME-LEN) (substring t 0 WX-TIME-LEN) t)))
(define (wx-topic m)
  (let ((t (wx-time m)))
    (if (> (string-length t) (+ WX-TIME-LEN 1)) (substring t (+ WX-TIME-LEN 1) (string-length t)) "")))
(define (wx-title m) (vector-ref m 3))
(define (wx-text m) (vector-ref m 4))

;; Message ids are too long for fixnums: compared as digit strings
(define (wx-id>? a b)
  (or (> (string-length a) (string-length b))
      (and (= (string-length a) (string-length b)) (string>? a b))))

(define (wx-find id)
  (let loop ((l wx-list))
    (cond ((null? l) #f)
          ((string=? (wx-id (car l)) id) (car l))
          (else (loop (cdr l))))))

;; The message after (older than) id, #f past the oldest or when id is gone
(define (wx-after id)
  (let loop ((l wx-list))
    (cond ((null? l) #f)
          ((string=? (wx-id (car l)) id) (if (pair? (cdr l)) (cadr l) #f))
          (else (loop (cdr l))))))

;; The positions of the first n "|" in line, or #f
(define (wx-bars line n)
  (let loop ((i 0) (acc '()))
    (cond ((= (length acc) n) (reverse acc))
          ((>= i (string-length line)) #f)
          ((char=? (string-ref line i) #\|) (loop (+ i 1) (cons i acc)))
          (else (loop (+ i 1) acc)))))

(define (wx-parse line)
  (let ((b (wx-bars line 4)))
    (if (not b)
        #f
        (let ((field (lambda (k)
                       (substring line (if (= k 0) 0 (+ 1 (list-ref b (- k 1))))
                                  (if (= k 4) (string-length line) (list-ref b k))))))
          (vector (field 0) (string=? (field 1) "1") (field 2) (field 3) (field 4))))))

(define (wx-load!)
  (let ((text (and (fs-exists? WX-PATH) (fs-read WX-PATH))))
    (set! wx-list '())
    (if (string? text)
        (for-each (lambda (line)
                    (cond ((str-starts? line "L|") (set! wx-last (substring line 2 (string-length line))))
                          ((str-starts? line "D|")
                           (set! wx-del (filter (lambda (id) (not (str-empty? id)))
                                                (str-split (substring line 2 (string-length line)) #\,))))
                          (else (let ((m (wx-parse line))) (if m (set! wx-list (append wx-list (list m))))))))
                  (str-split text #\newline)))))

;; "|" and line ends would break a line: only the text (the last field) may hold "|"
(define (wx-safe s keep-bar)
  (list->string (map (lambda (c) (if (or (and (not keep-bar) (char=? c #\|)) (char=? c #\newline) (char=? c #\return))
                                     #\space c))
                     (string->list (or s "")))))

(define (wx-line m)
  (string-append (wx-id m) "|" (if (wx-read? m) "1" "0") "|" (wx-time m) "|" (wx-title m) "|" (wx-text m)))

(define (wx-save!)
  (fs-write WX-PATH (web-join (append (list (string-append "L|" wx-last))
                                      (if (pair? wx-del) (list (string-append "D|" (web-join wx-del ","))) '())
                                      (map wx-line wx-list))
                              (list->string (list #\newline))))
  (app-invalidate-all))

;; The feed URL: with del=<ids> while deletions wait for the proxy, and
;; logout=1 while the logout does
(define (wx-base-url) (app-url "/app/wxpusher"))
(define (wx-url)
  (let ((q (append (if (null? wx-del) '() (list (string-append "del=" (web-join wx-del ","))))
                   (if wx-logout '("logout=1") '()))))
    (if (null? q) (wx-base-url) (string-append (wx-base-url) "?" (web-join q "&")))))

;; Messages deleted here: gone from the board, sent to the proxy with the next fetch
(define (wx-delete! ids)
  (set! wx-list (filter (lambda (m) (not (member (wx-id m) ids))) wx-list))
  (if (and wx-view (not (wx-find wx-view))) (set! wx-view #f))
  (set! wx-del (append wx-del (filter (lambda (id) (not (member id wx-del))) ids)))
  (if (= (wx-unread) 0) (begin (set! wx-alert 0) (ws2812-clear)))
  (wx-save!)
  (app-set-url! 0 (wx-url)))

(define (wx-unread) (length (filter (lambda (m) (not (wx-read? m))) wx-list)))

(define (wx-alert-key m) (string-append "m" (wx-id m)))

(define (wx-mark-read! m)
  (vector-set! m 1 #t)
  (app-alert-done! (wx-alert-key m))
  (if (= (wx-unread) 0) (begin (set! wx-alert 0) (ws2812-clear))))

;; 2. The proxy's document ----------------------------------------------------------------------

(define (wx-hex-val c)
  (let ((n (char->integer c))) (if (>= n 97) (- n 87) (- n 48))))

;; One hex row (4 modules a digit, the first the high bit) as the (n + 7) / 8
;; bytes gui-bitmap reads: two digits a byte, a missing digit as 0
(define (wx-row-bytes hex n)
  (let ((len (string-length hex)))
    (let loop ((k (- (quotient (+ n 7) 8) 1)) (acc '()))
      (if (< k 0)
          acc
          (let ((hi (if (< (* 2 k) len) (wx-hex-val (string-ref hex (* 2 k))) 0))
                (lo (if (< (+ (* 2 k) 1) len) (wx-hex-val (string-ref hex (+ (* 2 k) 1))) 0)))
            (loop (- k 1) (cons (integer->char (+ (* hi 16) lo)) acc)))))))

;; The proxy's QR rows as one bitmap, built once per code (drawn as one
;; display-list command, not one rectangle per run of modules)
(define (wx-take-qr! items n)
  (let* ((parts (map it-b (items-all items "qr")))
         (key (web-join parts ",")))
    (if (not (string=? key wx-qr-key))
        (begin
          (set! wx-qr-key key)
          (set! wx-qr-n n)
          (set! wx-qr (if (> n 0)
                          (list->string (apply append (map (lambda (hex) (wx-row-bytes hex n)) (str-split key #\,))))
                          #f))))))

;; The stored time field: "MM-DD HH:MM", then after a space the topic (the
;; "topic" key; an older proxy put it in c after the time already)
(define (wx-item-time it)
  (let ((topic (it-key it "topic")))
    (if (str-empty? topic) (it-c it) (string-append (it-c it) " " topic))))

;; The newest stored id, "" with none
(define (wx-newest-stored)
  (let loop ((l wx-list) (hi ""))
    (cond ((null? l) hi)
          ((or (string=? hi "") (wx-id>? (wx-id (car l)) hi)) (loop (cdr l) (wx-id (car l))))
          (else (loop (cdr l) hi)))))

;; wx-last newer than every message of the document while neither the
;; document nor the board has it: nothing backs it (a test feed, another
;; proxy), and it would hide every real message. Back to the newest stored
;; ("" with none: the document's messages come in).
(define (wx-check-last! msgs)
  (if (and (pair? msgs) (not (string=? wx-last ""))
           (not (wx-find wx-last))
           (null? (filter (lambda (it) (string=? (it-a it) wx-last)) msgs))
           (null? (filter (lambda (it) (not (wx-id>? wx-last (it-a it)))) msgs)))
      (set! wx-last (wx-newest-stored))))

;; New messages: ids past the newest taken, oldest first. "m" is unread,
;; "h" was read on the service before (history); new unread ones blink the LED.
(define (wx-data! items)
        ;; a document fetched with del= or logout=1: the proxy has them
        (if (and (or (pair? wx-del) wx-logout) (equal? (json-feed-url) (wx-url)))
            (begin
              (set! wx-del '())
              (set! wx-logout #f)
              (wx-save!)
              (app-set-url! 0 (wx-url))))
        (let ((st (items-find items "state")))
          (if st
              (begin
                (set! wx-state (it-a st))
                (set! wx-info (it-b st))
                (set! wx-left (or (it-int st 4) 0))
                (wx-take-qr! items (if (string=? wx-state "login") (or (it-int st 3) 0) 0)))))
        (wx-check-last! (filter (lambda (it) (and (memq (it-t it) '(m h)) (not (str-empty? (it-a it))))) items))
        (let ((fresh (filter (lambda (it)
                               (and (memq (it-t it) '(m h)) (not (str-empty? (it-a it)))
                                    (or (string=? wx-last "") (wx-id>? (it-a it) wx-last))))
                             (reverse items))))
          (if (pair? fresh)
              (let ((news '()))                ; the new unread ones, oldest first
                (for-each (lambda (it)
                            (let ((m (vector (it-a it) (eq? (it-t it) 'h) (wx-safe (wx-item-time it) #f)
                                             (wx-safe (it-b it) #f)
                                             (wx-safe (string-append (it-d it) (it-e it)) #t))))
                              (set! wx-list (cons m wx-list))
                              (if (eq? (it-t it) 'm) (set! news (append news (list m)))))
                            (set! wx-last (it-a it)))
                          fresh)
                (if (> (length wx-list) WX-MAX) (set! wx-list (take wx-list WX-MAX)))
                (if (pair? news) (set! wx-alert 20))
                (wx-save!)
                ;; the newest three as alerts (a burst of messages does not bury the screen)
                (for-each wx-raise-alert! (if (> (length news) 3) (list-tail news (- (length news) 3)) news))))))

(set! app-data-proc wx-data!)

;; 3. The screen ------------------------------------------------------------------------------

(define WX-NEW "【新】")

(define (wx-render-qr)
  (let* ((n wx-qr-n) (box (+ n 8))
         (m (max 1 (min 6 (quotient (- (scr-w) 20) box))))
         (side (* box m))
         (x0 (quotient (- (scr-w) side) 2))
         (y0 (+ (body-top) 34)))
    (txt-center (quotient (scr-w) 2) (+ (body-top) 6) "用微信扫码登录" theme-text-main)
    (gui-rect x0 y0 side side WX-WHITE #t)               ; the quiet zone, 4 modules around
    (gui-bitmap (+ x0 (* 4 m)) (+ y0 (* 4 m)) n n wx-qr m WX-BLACK)
    (let ((y (+ y0 side 10)))
      (txt-wrap 14 y (- (scr-w) 28) 60
                "扫码后，推送到这个微信的消息会显示在这里" theme-text-sub)
      (if (> wx-left 0)
          (txt-center (quotient (scr-w) 2) (+ y 48)
                      (string-append "二维码 " (number->string (quotient (+ wx-left 59) 60)) " 分钟内有效")
                      theme-text-muted)))))

(define (wx-render-login-waiting)
  (txt 14 70 "WxPusher 未登录" theme-text-main)
  (txt-wrap 14 100 (- (scr-w) 28) 100
            (if (str-empty? wx-info) "等待代理生成登录二维码..." wx-info) theme-text-sub))

(define (wx-hint)
  (cond ((str-empty? (app-proxy)) "在系统设置中填写应用代理")
        ((string=? wx-state "error") (string-append "代理连接 WxPusher 失败：" wx-info))
        (else "推送到你微信的消息会显示在这里")))

(define (wx-render-row m y)
  (let* ((w (scr-w)) (unread (not (wx-read? m))) (nw (if unread (+ (txt-w WX-NEW) 4) 0))
         (clock (wx-clock m)) (cw (+ (txt-w clock) 10)))
    (txt-fit 10 (+ y 4) (- w 20 nw) (wx-title m) (if unread theme-text-main theme-text-sub))
    (if unread (txt-right (- w 8) (+ y 4) WX-NEW theme-danger))
    (txt-fit 10 (+ y 24) (- w 20 cw) (wx-topic m) theme-accent)
    (txt-right (- w 10) (+ y 24) clock theme-text-muted)
    (gui-line 10 (- (+ y WX-ROW-H) 1) (- w 10) (- (+ y WX-ROW-H) 1) theme-divider)))

(define (wx-render-list)
  (if (null? wx-list)
      (begin
        (txt 14 70 "暂无消息" theme-text-muted)
        (txt-wrap 14 100 (- (scr-w) 28) 80 (wx-hint) theme-text-sub))
      (let ((rows (quotient (- (body-bottom) (body-top)) WX-ROW-H)))
        (let loop ((l wx-list) (i 0) (y (body-top)))
          (if (and (pair? l) (< i rows))
              (begin
                (if (gui-visible? y WX-ROW-H) (wx-render-row (car l) y))
                (loop (cdr l) (+ i 1) (+ y WX-ROW-H))))))))

(define (wx-position id)
  (let loop ((l wx-list) (i 1))
    (cond ((null? l) 0)
          ((string=? (wx-id (car l)) id) i)
          (else (loop (cdr l) (+ i 1))))))

;; As a row of the list, larger: the mark and the position, the subject
;; (two lines), the topic on the left and the time on the right, the text
(define (wx-render-message m)
  (let* ((w (scr-w)) (y (+ (body-top) 2)) (unread (not (wx-read? m)))
         (clock (wx-clock m)) (cw (+ (txt-w clock) 10)))
    (txt 10 y (if unread WX-NEW "已读") (if unread theme-danger theme-text-muted))
    (txt-right (- w 10) y (string-append (number->string (wx-position (wx-id m))) "/"
                                         (number->string (length wx-list)))
               theme-text-muted)
    (txt-wrap 10 (+ y 26) (- w 20) 40 (wx-title m) theme-text-main)
    (txt-fit 10 (+ y 70) (- w 20 cw) (wx-topic m) theme-accent)
    (txt-right (- w 10) (+ y 70) clock theme-text-muted)
    (gui-line 10 (+ y 94) (- w 10) (+ y 94) theme-divider)
    (txt-wrap 10 (+ y 102) (- w 20) (- (body-bottom) y 102 26)
              (if (str-empty? (wx-text m)) (wx-title m) (wx-text m)) theme-text-main)
    (txt-fit 10 (- (body-bottom) 20) (- w 20)
             (string-append (if unread "长按：标为已读" "长按：返回列表")
                            (if (wx-after (wx-id m)) "  短按：下一条" "  短按：返回列表"))
             theme-text-muted)))

(define (wx-render items)
  (let ((m (and wx-view (wx-find wx-view))))
    (cond (m (wx-render-message m))
          ((and (string=? wx-state "login") wx-qr) (wx-render-qr))
          ((string=? wx-state "login") (wx-render-login-waiting))
          (else (wx-render-list)))))

;; The alert of a new message: its subject, topic and time, its text; a short press reads it
(define (wx-render-alert m)
  (let* ((w (scr-w)) (y (+ (body-top) 4)) (clock (wx-clock m)) (cw (+ (txt-w clock) 10)))
    (txt-wrap 10 y (- w 20) 44 (wx-title m) theme-text-main)
    (txt-fit 10 (+ y 48) (- w 20 cw) (wx-topic m) theme-accent)
    (txt-right (- w 10) (+ y 48) clock theme-text-muted)
    (gui-line 10 (+ y 72) (- w 10) (+ y 72) theme-divider)
    (txt-wrap 10 (+ y 80) (- w 20) (- (body-bottom) y 84)
              (if (str-empty? (wx-text m)) (wx-title m) (wx-text m)) theme-text-main)))

(define (wx-raise-alert! m)
  (app-alert! (wx-alert-key m) "新消息" (lambda () (wx-render-alert m))
              (list (cons 'ack (lambda () (wx-mark-read! m) (wx-save!)))
                    (cons 'priority 6) (cons 'exit 'both) (cons 'seconds 60))))

;; 4. Buttons, alert ---------------------------------------------------------------------------

;; Short press: the newest message, then each older one, then the list again
(set! app-button
      (lambda ()
        (let ((next (if wx-view (wx-after wx-view) (if (pair? wx-list) (car wx-list) #f))))
          (set! wx-view (if next (wx-id next) #f))
          (app-invalidate-all))))

;; Long press: at home everything read; on a message read it, or (read
;; already) back to the list
(define (app-long-press)
  (let ((m (and wx-view (wx-find wx-view))))
    (cond ((not wx-view)
           (if (> (wx-unread) 0)
               (begin (for-each wx-mark-read! wx-list) (wx-save!))))
          ((and m (not (wx-read? m))) (wx-mark-read! m) (wx-save!))
          (else (set! wx-view #f)))
    (app-invalidate-all)))

(set! app-tick-proc
      (lambda (tick)
        (if (> wx-alert 0)
            (begin
              (if (= (remainder tick 2) 0) (ws2812-set 0 160 60) (ws2812-clear))
              (set! wx-alert (- wx-alert 1))
              (if (= wx-alert 0) (ws2812-clear))))))

(set! app-subtitle-proc
      (lambda (items)
        (cond ((string=? wx-state "login") "未登录")
              ((string=? wx-state "error") "连接中断")
              ((> (wx-unread) 0) (string-append "未读 " (number->string (wx-unread))))
              (else #f))))

;; 5. The web page's calls --------------------------------------------------------------------------

(define (wx->alist m)
  (list (cons 'id (wx-id m)) (cons 'read (wx-read? m)) (cons 'time (wx-clock m)) (cons 'topic (wx-topic m))
        (cons 'title (wx-title m)) (cons 'text (wx-text m))))

(define (wx-answer)
  (web-ok (cons 'messages (map wx->alist wx-list)) (cons 'unread (wx-unread)) (cons 'state wx-state)
          (cons 'info wx-info) (cons 'proxy (app-proxy))
          (cons 'pending (length wx-del)) (cons 'logout wx-logout)
          ;; the login QR code as the proxy sent it: rows of hex, n modules a side
          (cons 'qr (if (and wx-qr (string=? wx-state "login")) wx-qr-key "")) (cons 'qrn wx-qr-n)))

(define (app-web name body)
  (cond
    ((string=? name "list") (wx-answer))
    ((string=? name "read")
     (let ((id (or (web-field body "id") "")))
       (for-each (lambda (m) (if (or (string=? id "") (string=? (wx-id m) id)) (wx-mark-read! m))) wx-list)
       (wx-save!)
       (wx-answer)))
    ((string=? name "delete")
     (let ((id (or (web-field body "id") "")))
       (if (wx-find id) (wx-delete! (list id)))
       (wx-answer)))
    ((string=? name "clear")
     (wx-delete! (map wx-id wx-list))
     (wx-answer))
    ((string=? name "logout")             ; sent with the next fetch
     (set! wx-logout #t)
     (app-set-url! 0 (wx-url))
     (wx-answer))
    (else (web-error (string-append "unknown call: " name)))))

;; 6. Start ------------------------------------------------------------------------------------------

(wx-load!)
(app-keys! "topic")                    ; beyond t, a..e: the message's topic
(set! app-render-empty-pages '(0))     ; the board's own messages, also before (or without) the proxy

;; For a combined app (apps/lib/combo.scm): wxpusher.news[i], message i (0 the
;; newest), the list when there are fewer
(app-view! "news" 0
           (lambda (items i)
             (let ((m (and (< i (length wx-list)) (list-ref wx-list i))))
               (if m (wx-render-message m) (wx-render-list)))))

(app-watch! wx-url 15000 wx-data!)   ; new messages also while another app's page shows (a combined app)

(app-define! "WxPusher"
  (list (app-page "消息" wx-url WX-INTERVAL wx-render)))
