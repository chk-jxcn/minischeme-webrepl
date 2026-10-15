;;; =========================================================================
;;; Memo, 320x480 portrait, on the app framework (applib.scm).
;;; The memos live on the board (memo.txt in the app's folder); they are written on
;;; the board's web page (the app's tab, apps/memo/web.html), whose calls come
;;; to (app-web name body) below. No proxy needed.
;;;   1 to do: pinned first, newest first   2 done
;;; File: one memo per line, "id|flags|time|text"; flags: p pinned, d done.
;;; =========================================================================

(define MEMO-PATH "memo.txt")            ; in the app's own folder
(define MEMO-MAX 40)                    ; memos kept
(define MEMO-TEXT-MAX 300)              ; bytes of one memo
(define MEMO-CARD-H 66)

(define memo-list '())                  ; #(id flags time text), file order (oldest first)

;; 1. Storage -------------------------------------------------------------------------------

(define (memo-id m) (vector-ref m 0))
(define (memo-flags m) (vector-ref m 1))
(define (memo-time m) (vector-ref m 2))
(define (memo-text m) (vector-ref m 3))
(define (memo-flag? m ch)
  (let ((f (memo-flags m)))
    (let loop ((i 0))
      (cond ((>= i (string-length f)) #f)
            ((char=? (string-ref f i) ch) #t)
            (else (loop (+ i 1)))))))
(define (memo-pinned? m) (memo-flag? m #\p))
(define (memo-done? m) (memo-flag? m #\d))

;; The index of ch in s from start, or #f
(define (memo-index s ch start)
  (let loop ((i start))
    (cond ((>= i (string-length s)) #f)
          ((char=? (string-ref s i) ch) i)
          (else (loop (+ i 1))))))

;; "12|p|10月11日 15:30|text" -> #(12 "p" "10月11日 15:30" "text"); #f when malformed
(define (memo-parse line)
  (let* ((a (memo-index line #\| 0))
         (b (and a (memo-index line #\| (+ a 1))))
         (c (and b (memo-index line #\| (+ b 1))))
         (id (and a (string->number (substring line 0 a)))))
    (if (and c id)
        (vector id (substring line (+ a 1) b) (substring line (+ b 1) c)
                (substring line (+ c 1) (string-length line)))
        #f)))

(define (memo-load!)
  (let ((text (and (fs-exists? MEMO-PATH) (fs-read MEMO-PATH))))
    (set! memo-list
          (if (string? text)
              (filter (lambda (m) m) (map memo-parse (str-split text #\newline)))
              '()))))

(define (memo-line m)
  (string-append (number->string (memo-id m)) "|" (memo-flags m) "|" (memo-time m) "|" (memo-text m)))

(define (memo-save!)
  (fs-write MEMO-PATH (web-join (map memo-line memo-list) (list->string (list #\newline))))
  (app-invalidate-all))

(define (memo-next-id)
  (+ 1 (let loop ((l memo-list) (hi 0))
         (if (null? l) hi (loop (cdr l) (max hi (memo-id (car l))))))))

;; One line, at most MEMO-TEXT-MAX bytes, never cut inside a UTF-8 character
(define (memo-clean s)
  (let* ((flat (list->string (map (lambda (c) (if (or (char=? c #\newline) (char=? c #\return)) #\space c))
                                  (string->list s))))
         (n (string-length flat)))
    (if (<= n MEMO-TEXT-MAX)
        flat
        (let back ((k MEMO-TEXT-MAX))
          (if (and (> k 0) (= (quotient (char->integer (string-ref flat k)) 64) 2))   ; 10xxxxxx
              (back (- k 1))
              (substring flat 0 k))))))

(define (memo-now)
  (if (string=? app-time "--:--") "" (string-append app-date " " app-time)))

(define (memo-find id)
  (let loop ((l memo-list))
    (cond ((null? l) #f)
          ((= (memo-id (car l)) id) (car l))
          (else (loop (cdr l))))))

;; flags with ch set (on #t) or cleared
(define (memo-set-flag flags ch on)
  (let ((rest (list->string (filter (lambda (c) (not (char=? c ch))) (string->list flags)))))
    (if on (string-append rest (list->string (list ch))) rest)))

(define (memo-add! text pin)
  (let ((m (vector (memo-next-id) (if pin "p" "") (memo-now) (memo-clean text))))
    (set! memo-list (append memo-list (list m)))
    ;; past MEMO-MAX the oldest done memo goes first, else the oldest one
    (if (> (length memo-list) MEMO-MAX)
        (let ((old (or (let loop ((l memo-list)) (cond ((null? l) #f) ((memo-done? (car l)) (car l)) (else (loop (cdr l)))))
                       (car memo-list))))
          (set! memo-list (filter (lambda (x) (not (eq? x old))) memo-list))))
    (memo-save!)
    m))

;; 2. The screen ---------------------------------------------------------------------------

;; Pinned first, then newest first
(define (memo-shown done)
  (let* ((l (reverse (filter (lambda (m) (eq? (memo-done? m) done)) memo-list)))
         (pinned (filter memo-pinned? l)))
    (append pinned (filter (lambda (m) (not (memo-pinned? m))) l))))

(define (memo-rows) (quotient (- (body-bottom) (body-top) 24) MEMO-CARD-H))

(define (memo-render-card m y)
  (let ((w (- (scr-w) 20)))
    (gui-round-rect 10 y w (- MEMO-CARD-H 6) 6 (if (memo-pinned? m) theme-accent theme-card-border) #f)
    (if (memo-pinned? m) (gui-rect 10 (+ y 8) 3 (- MEMO-CARD-H 22) theme-accent #t))
    (txt-wrap 20 (+ y 4) (- w 20) 40 (memo-text m) (if (memo-done? m) theme-text-muted theme-text-main))
    (txt-right (- (scr-w) 18) (+ y 40) (memo-time m) theme-text-muted)
    (if (memo-pinned? m) (txt 20 (+ y 40) "置顶" theme-accent))))

(define (memo-hint)
  (if (wifi-connected?)
      (string-append "在浏览器打开 http://" (wifi-ip) "/ 添加和编辑")
      "连接 WiFi 后在浏览器中添加和编辑"))

(define (memo-render-list done)
  (let* ((shown (memo-shown done)) (rows (memo-rows)) (n (length shown)))
    (if (null? shown)
        (begin
          (txt 14 70 (if done "没有已完成的备忘" "暂无备忘") theme-text-muted)
          (txt-wrap 14 100 (- (scr-w) 28) 60 (memo-hint) theme-text-sub))
        (let loop ((l shown) (i 0) (y (+ (body-top) 2)))
          (if (and (pair? l) (< i rows))
              (begin
                (if (gui-visible? y MEMO-CARD-H) (memo-render-card (car l) y))
                (loop (cdr l) (+ i 1) (+ y MEMO-CARD-H)))
              (if (> n rows)
                  (txt 14 (+ y 2) (string-append "还有 " (number->string (- n rows)) " 条，在网页中查看")
                       theme-text-muted)))))))

(define (memo-render-todo items) (memo-render-list #f))
(define (memo-render-done items) (memo-render-list #t))

(define (memo-footer!)
  (set! app-footer-text
        (string-append "待办 " (number->string (length (memo-shown #f)))
                       "  已完成 " (number->string (length (memo-shown #t)))
                       (if (wifi-connected?) (string-append "  网页 " (wifi-ip)) ""))))

;; 3. The web page's calls -------------------------------------------------------------------

(define (memo->alist m)
  (list (cons 'id (memo-id m)) (cons 'text (memo-text m)) (cons 'time (memo-time m))
        (cons 'pinned (memo-pinned? m)) (cons 'done (memo-done? m))))

(define (memo-answer)
  (memo-footer!)
  (web-ok (cons 'memos (map memo->alist (append (memo-shown #f) (memo-shown #t))))
          (cons 'max MEMO-MAX)))

;; Applies change to memo id (a field of body), then answers the list
(define (memo-change! body change)
  (let ((m (memo-find (web-field-int body "id" -1))))
    (if (not m)
        (web-error "no such memo")
        (begin
          (change m)
          (memo-save!)
          (memo-answer)))))

(define (app-web name body)
  (cond
    ((string=? name "list") (memo-answer))
    ((string=? name "add")
     (let ((text (web-field body "text")))
       (if (str-empty? text)
           (web-error "empty memo")
           (begin (memo-add! text (equal? (web-field body "pin") "1")) (memo-answer)))))
    ((string=? name "edit")
     (let ((text (web-field body "text")))
       (if (str-empty? text)
           (web-error "empty memo")
           (memo-change! body (lambda (m) (vector-set! m 3 (memo-clean text)))))))
    ((string=? name "done")
     (memo-change! body (lambda (m) (vector-set! m 1 (memo-set-flag (memo-flags m) #\d (not (memo-done? m)))))))
    ((string=? name "pin")
     (memo-change! body (lambda (m) (vector-set! m 1 (memo-set-flag (memo-flags m) #\p (not (memo-pinned? m)))))))
    ((string=? name "delete")
     (let ((m (memo-find (web-field-int body "id" -1))))
       (if (not m)
           (web-error "no such memo")
           (begin (set! memo-list (filter (lambda (x) (not (eq? x m))) memo-list))
                  (memo-save!)
                  (memo-answer)))))
    ((string=? name "clear-done")
     (set! memo-list (filter (lambda (m) (not (memo-done? m))) memo-list))
     (memo-save!)
     (memo-answer))
    (else (web-error (string-append "unknown call: " name)))))

;; 4. Start --------------------------------------------------------------------------------------

(memo-load!)
(memo-footer!)

;; the footer's address once WiFi is up
(set! app-tick-proc
      (lambda (tick) (if (= (remainder tick 10) 0) (memo-footer!))))

;; the header: how many to do
(set! app-subtitle-proc
      (lambda (items) (string-append "待办 " (number->string (length (memo-shown #f))))))

(app-define! "备忘录"
  (list (app-local-page "待办" memo-render-todo)
        (app-local-page "已完成" memo-render-done)))
