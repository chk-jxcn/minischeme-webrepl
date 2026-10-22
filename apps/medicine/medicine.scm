;;; =========================================================================
;;; Medicine reminder, 320x480 portrait, on the app framework (applib.scm).
;;; The reminder times and the medicines are set on the board's web page
;;; (the app's tab, apps/medicine/web.html): a name, a quantity, a photo
;;; (photos/m<id>.jpg), the time points it is taken at, every day or every
;;; other day. The times go into schedule.ini, so the system starts this app
;;; at each of them, whatever app runs then (API 1.7: app-scheduled,
;;; app-return and the app-schedule hook).
;;;   normal:   the medicines one after another (photo, name, quantity);
;;;             a short press shows the next one
;;;   reminder: "共 N 个药 第 k 个" blinks in the title, the name is drawn
;;;             large; a short press confirms it and shows the next; after
;;;             the last the board returns to the app it ran before
;;; Settings (the app's config.ini, also from its web page): name_scale,
;;; qty_scale (the reminder's name and quantity), list_scale (the name in
;;; normal mode): multiples of the 16 px font, shrunk when a name is too wide.
;;; meds.txt: one medicine per line, "id|name|qty|slots|alt|ref"; slots
;;; "1,3" (time points, from 1), alt 1: every other day, taken on day ref
;;; (days since 1970-01-01) and every second day from it.
;;; =========================================================================

(define MED-PATH "meds.txt")
(define MED-SCHEDULE "schedule.ini")
(define MED-MAX 20)                     ; medicines kept
(define MED-TIMES-MAX 6)                ; time points
(define MED-NAME-MAX 60)                ; bytes of a name
(define MED-QTY-MAX 30)                 ; bytes of a quantity
(define MED-PHOTO-TOP 40)               ; the photo's box starts here (the web page makes them 300 x 280 at most)
(define MED-SHOW-SECONDS 8)             ; normal mode: seconds per medicine
(define MED-DONE-SECONDS 3)             ; "all taken" stays this long before the return
(define MED-WAIT-SECONDS 20)            ; a scheduled start waits this long for the date
(define MED-NL (list->string (list #\newline)))

(define med-list '())                   ; #(id name qty slots alt ref), file order
(define med-times '())                  ; ("08:00" "12:30" ...), the time points in order
(define med-index 0)                    ; normal mode: the medicine shown
(define med-left MED-SHOW-SECONDS)
(define med-info-cache '())             ; (id . image-info) of the photos asked
(define med-due '())                    ; reminder: the medicines still to take, in order
(define med-due-total 0)                ; reminder: how many it has
(define med-due-done 0)                 ; reminder: how many are confirmed
(define med-due-at "")                  ; reminder: its time, "" in normal mode
(define med-done-left 0)                ; seconds the "all taken" screen still stays
(define med-blink #t)
(define med-pending-at #f)              ; a scheduled start waiting for the date
(define med-pending-secs 0)
(define med-scales '())                 ; (key . multiple) of the text sizes, from the settings
(define MED-SCALE-KEYS '(("name_scale" "2" 4) ("qty_scale" "1" 3) ("list_scale" "1" 3)))

;; 1. Medicines and times ------------------------------------------------------------------

(define (med-id m) (vector-ref m 0))
(define (med-name m) (vector-ref m 1))
(define (med-qty m) (vector-ref m 2))
(define (med-slots m) (vector-ref m 3))           ; time points, from 1
(define (med-alt? m) (= (vector-ref m 4) 1))
(define (med-ref m) (vector-ref m 5))
(define (med-photo-path m) (string-append "photos/m" (number->string (med-id m)) ".jpg"))

;; Spaces and control characters off both ends
(define (med-trim s)
  (let* ((n (string-length s))
         (blank? (lambda (i) (<= (char->integer (string-ref s i)) 32)))
         (a (let loop ((i 0)) (if (and (< i n) (blank? i)) (loop (+ i 1)) i)))
         (b (let loop ((j n)) (if (and (> j a) (blank? (- j 1))) (loop (- j 1)) j))))
    (substring s a b)))

(define (med-ints s)                    ; "1,3" -> (1 3)
  (filter integer? (map (lambda (x) (string->number (med-trim x))) (str-split s #\,))))

;; "8:05" / "08:05" -> "08:05", else #f
(define (med-hm s)
  (let ((p (str-split (med-trim s) #\:)))
    (and (= (length p) 2)
         (= (string-length (cadr p)) 2)
         (let ((h (string->number (car p))) (m (string->number (cadr p))))
           (and (integer? h) (integer? m) (>= h 0) (< h 24) (>= m 0) (< m 60)
                (string-append (pad2 h) ":" (pad2 m)))))))

;; "12|阿莫西林|2 片|1,3|0|0" -> #(12 "阿莫西林" "2 片" (1 3) 0 0); #f when malformed
(define (med-parse line)
  (let ((f (str-split (med-trim line) #\|)))
    (and (>= (length f) 6)
         (let ((id (string->number (list-ref f 0))) (ref (string->number (list-ref f 5))))
           (and (integer? id)
                (vector id (list-ref f 1) (list-ref f 2) (med-ints (list-ref f 3))
                        (if (string=? (list-ref f 4) "1") 1 0) (if (integer? ref) ref 0)))))))

(define (med-line m)
  (string-append (number->string (med-id m)) "|" (med-name m) "|" (med-qty m) "|"
                 (web-join (map number->string (med-slots m)) ",") "|"
                 (if (med-alt? m) "1" "0") "|" (number->string (med-ref m))))

(define (med-load!)
  (let ((text (and (fs-exists? MED-PATH) (fs-read MED-PATH))))
    (set! med-list (if (string? text) (filter (lambda (m) m) (map med-parse (str-split text #\newline))) '()))
    (set! med-info-cache '())
    (if (>= med-index (max 1 (length med-list))) (set! med-index 0))))

(define (med-save!)
  (fs-write MED-PATH (web-join (map med-line med-list) MED-NL))
  (set! med-info-cache '())
  (app-invalidate-all))

;; schedule.ini: "times = 08:00, 12:30" (the system reads the same line)
(define (med-load-times!)
  (let* ((text (and (fs-exists? MED-SCHEDULE) (fs-read MED-SCHEDULE)))
         (line (and (string? text)
                    (let loop ((ls (str-split text #\newline)))
                      (cond ((null? ls) #f)
                            ((str-starts? (med-trim (car ls)) "times") (med-trim (car ls)))
                            (else (loop (cdr ls)))))))
         (value (and line (let ((eq (str-split line #\=))) (and (pair? (cdr eq)) (cadr eq)))))
         (value (and value (car (str-split value #\;)))))
    (set! med-times (if value (filter (lambda (t) t) (map med-hm (str-split value #\,))) '()))))

(define (med-save-times! times)
  (set! med-times times)
  (fs-write MED-SCHEDULE
            (string-append "[schedule]" MED-NL
                           "; the reminder times, from the app's web page: the system starts it then" MED-NL
                           "times = " (web-join times ", ") MED-NL))
  (app-invalidate-all))

(define (med-find id)
  (let loop ((l med-list))
    (cond ((null? l) #f) ((= (med-id (car l)) id) (car l)) (else (loop (cdr l))))))

(define (med-next-id)
  (+ 1 (let loop ((l med-list) (hi 0)) (if (null? l) hi (loop (cdr l) (max hi (med-id (car l))))))))

;; One line of at most limit bytes, without | (the file's separator), never
;; cut inside a UTF-8 character
(define (med-clean s limit)
  (let* ((flat (med-trim (list->string (map (lambda (c) (if (or (char=? c #\|) (< (char->integer c) 32)) #\space c))
                                            (string->list s)))))
         (n (string-length flat)))
    (if (<= n limit)
        flat
        (let back ((k limit))
          (if (and (> k 0) (= (quotient (char->integer (string-ref flat k)) 64) 2))   ; 10xxxxxx
              (back (- k 1))
              (substring flat 0 k))))))

;; 2. Days ---------------------------------------------------------------------------------

;; Days since 1970-01-01 of a date (proleptic Gregorian)
(define (med-civil-days y m d)
  (let* ((y (if (<= m 2) (- y 1) y))
         (era (quotient (if (>= y 0) y (- y 399)) 400))
         (yoe (- y (* era 400)))
         (doy (+ (quotient (+ (* 153 (+ m (if (> m 2) -3 9))) 2) 5) (- d 1)))
         (doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)) doy)))
    (+ (* era 146097) doe -719468)))

(define (med-today)
  (let ((t (time-local)))
    (if t (med-civil-days (car t) (cadr t) (caddr t)) #f)))

;; Every day, or every other day from its day ref (unknown date: taken)
(define (med-take-today? m)
  (let ((d (med-today)))
    (or (not (med-alt? m)) (not d) (= (modulo (- d (med-ref m)) 2) 0))))

(define (med-slot-of at)                ; the time point of "08:00", from 1, or #f
  (let loop ((l med-times) (k 1))
    (cond ((null? l) #f) ((string=? (car l) at) k) (else (loop (cdr l) (+ k 1))))))

(define (med-due-at-slot k)
  (filter (lambda (m) (and (memv k (med-slots m)) (med-take-today? m))) med-list))

(define (med-times-of m)                ; "08:00、19:00"
  (let ((ts (filter (lambda (t) t)
                    (map (lambda (k) (and (<= k (length med-times)) (list-ref med-times (- k 1)))) (med-slots m)))))
    (if (null? ts) "未选时间" (web-join ts "、"))))

;; The next time point after now (the first one tomorrow after the last)
(define (med-next-time)
  (if (or (null? med-times) (string=? app-time "--:--"))
      #f
      (let loop ((l med-times) (best #f) (first #f))
        (if (null? l)
            (or best first)
            (let ((t (car l)))
              (loop (cdr l)
                    (if (and (string<? app-time t) (or (not best) (string<? t best))) t best)
                    (if (or (not first) (string<? t first)) t first)))))))

;; 3. Reminder -----------------------------------------------------------------------------

(define (med-reminding?) (not (string=? med-due-at "")))

(define (med-led on)
  (if (defined? 'led-set) (if on (led-set 255 96 0) (led-set 0 0 0))))

;; The time point at: its medicines due today join the ones not yet taken
(define (med-remind! at)
  (let* ((k (med-slot-of at))
         (new (if k (med-due-at-slot k) '()))
         (more (filter (lambda (m) (not (memv (med-id m) (map med-id med-due)))) new)))
    (if (null? med-due)
        (begin (set! med-due-total 0) (set! med-due-done 0)))
    (set! med-due (append med-due more))
    (set! med-due-total (+ med-due-total (length more)))
    (set! med-due-at at)
    (set! med-done-left 0)
    (set! med-blink #t)
    (if (null? med-due)
        (med-finish!)                   ; nothing to take now
        (begin (med-led #t) (app-invalidate-all)))))

;; Back to the app that ran before; when this app is that one, its normal screen
(define (med-finish!)
  (set! med-due '())
  (set! med-due-at "")
  (set! med-due-total 0)
  (set! med-due-done 0)
  (set! med-done-left 0)
  (med-led #f)
  (if (not (app-return))
      (begin (set! med-left MED-SHOW-SECONDS) (app-invalidate-all))))

(define (med-confirm!)
  (if (pair? med-due)
      (begin
        (set! med-due (cdr med-due))
        (set! med-due-done (+ med-due-done 1))
        (if (null? med-due)
            (begin (set! med-done-left MED-DONE-SECONDS) (med-led #f)))
        (app-invalidate-all))))

(define (med-next! step)
  (let ((n (length med-list)))
    (if (> n 0) (set! med-index (modulo (+ med-index step) n)))
    (set! med-left MED-SHOW-SECONDS)
    (app-invalidate-all)))

;; 4. Screen -------------------------------------------------------------------------------

(define (med-photo-info m)
  (let ((hit (assv (med-id m) med-info-cache)))
    (if hit
        (cdr hit)
        (let ((info (image-info (med-photo-path m))))
          (set! med-info-cache (cons (cons (med-id m) info) med-info-cache))
          info))))

;; The photo centered in the box from MED-PHOTO-TOP to bottom; a taller one
;; is cut there (the text below is drawn over a cleared area)
(define (med-render-photo m bottom)
  (let ((info (med-photo-info m)) (cx (quotient (scr-w) 2)) (h (- bottom MED-PHOTO-TOP)))
    (if info
        (gui-image (quotient (- (scr-w) (car info)) 2)
                   (+ MED-PHOTO-TOP (quotient (max 0 (- h (cadr info))) 2))
                   (med-photo-path m))
        (let ((bh (min 160 (- h 20))))
          (if (> bh 40)
              (begin
                (gui-round-rect 70 (+ MED-PHOTO-TOP (quotient (- h bh) 2)) (- (scr-w) 140) bh 10 theme-card-border #f)
                (txt-center cx (- (+ MED-PHOTO-TOP (quotient h 2)) 8) "没有照片" theme-text-muted)))))
    (gui-rect 0 bottom (scr-w) (- (gui-height) bottom) theme-bg #t)))

;; The text sizes: read when the app starts and when its web page sets them
(define (med-load-scales!)
  (set! med-scales
        (map (lambda (k)
               (let ((n (string->number (app-config (car k) (cadr k)))))
                 (cons (car k) (clamp (if (integer? n) n (string->number (cadr k))) 1 (caddr k)))))
             MED-SCALE-KEYS)))

(define (med-scale key) (let ((hit (assoc key med-scales))) (if hit (cdr hit) 1)))

;; The largest multiple up to s at which text fits the screen's width (at least 1)
(define (med-fit-scale s text)
  (if (or (<= s 1) (<= (* s (txt-w text)) (- (scr-w) 16))) (max s 1) (med-fit-scale (- s 1) text)))

;; One line centered at y, k times the font's size; too wide at 1: "..." or a marquee
(define (med-text y text color k)
  (cond ((> k 1) (gui-text-scaled (quotient (- (scr-w) (* k (txt-w text))) 2) y text color k F-TEXT))
        ((<= (txt-w text) (- (scr-w) 16)) (txt-center (quotient (scr-w) 2) y text color))
        (else (txt-fit 8 y (- (scr-w) 16) text color))))

(define (med-header title right bg fg)
  (gui-rect 0 0 (scr-w) HDR-H bg #t)
  (txt-fit 8 8 (- (scr-w) 24 (txt-w right)) title fg)
  (txt-right (- (scr-w) 8) 8 right fg))

(define (med-footer text)
  (let ((y (- (gui-height) FTR-H)))
    (gui-rect 0 y (scr-w) FTR-H theme-card-hdr #t)
    (txt-fit 8 (+ y 3) (- (scr-w) 16) text theme-text-muted)))

(define (med-web-hint)
  (if (wifi-connected?) (string-append "http://" (wifi-ip) "/") "连接 WiFi 后用浏览器设置"))

(define (med-render-empty)
  (let ((cx (quotient (scr-w) 2)))
    (txt-center cx 180 "还没有药品" theme-text-main)
    (txt-center cx 212 "在设备网页的应用标签里添加药品" theme-text-muted)
    (txt-center cx 236 "和提醒时间" theme-text-muted)
    (txt-center cx 272 (med-web-hint) theme-accent)))

(define (med-render-normal)
  (let ((n (length med-list)) (cx (quotient (scr-w) 2)))
    (med-header (if (> n 1) (string-append "吃药提醒  " (number->string (+ med-index 1)) "/" (number->string n))
                    "吃药提醒")
                app-time theme-card-hdr theme-text-main)
    (if (= n 0)
        (med-render-empty)
        (let* ((m (list-ref med-list med-index))
               (k (med-fit-scale (med-scale "list_scale") (med-name m)))
               (note-y (- (gui-height) FTR-H 28))          ; "今天不用服"
               (times-y (- note-y 24))
               (qty-y (- times-y 26))
               (name-y (- qty-y 8 (* 16 k))))
          (med-render-photo m (- name-y 10))
          (med-text name-y (med-name m) theme-text-main k)
          (txt-center cx qty-y (string-append "数量：" (med-qty m)) theme-accent)
          (txt-center cx times-y (string-append (med-times-of m) (if (med-alt? m) "  隔日" "")) theme-text-sub)
          (if (and (med-alt? m) (not (med-take-today? m)))
              (txt-center cx note-y "今天不用服" theme-text-muted))))
    (let ((next (med-next-time)))
      (med-footer (string-append (cond ((null? med-times) "未设置提醒时间")
                                       (next (string-append "下次提醒 " next))
                                       (else ""))
                                 (if (wifi-connected?) (string-append "    网页 " (wifi-ip)) ""))))))

(define (med-render-reminder)
  (let* ((cx (quotient (scr-w) 2))
         (m (car med-due))
         (qty (string-append "数量：" (med-qty m)))
         (kn (med-fit-scale (med-scale "name_scale") (med-name m)))
         (kq (med-fit-scale (med-scale "qty_scale") qty))
         (bar-y (- (gui-height) 44))
         (qty-y (- bar-y 10 (* 16 kq)))
         (name-y (- qty-y 10 (* 16 kn))))
    (med-header (string-append "共 " (number->string med-due-total) " 个药  第 "
                               (number->string (+ med-due-done 1)) " 个")
                med-due-at
                (if med-blink theme-warning theme-card-hdr)
                (if med-blink theme-bg theme-warning))
    (med-render-photo m (- name-y 10))
    (med-text name-y (med-name m) theme-text-main kn)
    (med-text qty-y qty theme-accent kq)
    (gui-rect 0 bar-y (scr-w) 44 theme-accent-dark #t)
    (txt-center cx (+ bar-y 14) "服药后按按钮确认" theme-text-main)))

(define (med-render-done)
  (let ((cx (quotient (scr-w) 2)))
    (med-header (string-append "共 " (number->string med-due-total) " 个药") med-due-at theme-card-hdr theme-text-main)
    (let ((s "已全部服用"))
      (gui-text-scaled (- cx (txt-w s)) 200 s theme-success 2 F-TEXT))
    (txt-center cx 256 "即将回到原来的应用" theme-text-muted)))

(define (med-render-waiting)
  (let ((cx (quotient (scr-w) 2)))
    (med-header "吃药时间" med-pending-at theme-warning theme-bg)
    (txt-center cx 220 "正在读取日期..." theme-text-muted)))

(define (med-render)
  (gui-clear theme-bg)
  (cond ((pair? med-due) (med-render-reminder))
        ((med-reminding?) (med-render-done))
        (med-pending-at (med-render-waiting))
        (else (med-render-normal)))
  (gui-flush))

;; 5. Button, time, the scheduled start ----------------------------------------------------

(define (app-button)
  (cond ((pair? med-due) (med-confirm!))
        ((med-reminding?) (med-finish!))          ; "all taken": return at once
        (med-pending-at #t)
        (else (med-next! 1))))

(define (app-touch x y) (app-button))

;; The system: one of the times came while this app runs
(define (app-schedule at) (med-start! at))

;; Every-other-day plans need the date: a start waits for the first clock tick
(define (med-start! at)
  (if (or (time-local) (>= med-pending-secs MED-WAIT-SECONDS))
      (begin (set! med-pending-at #f) (med-remind! at))
      (begin (set! med-pending-at at) (app-invalidate-all))))

(set! app-tick-proc
      (lambda (tick)
        (cond (med-pending-at
               (set! med-pending-secs (+ med-pending-secs 1))
               (med-start! med-pending-at))
              ((pair? med-due)
               (set! med-blink (not med-blink))
               (med-led med-blink)
               (gui-invalidate 0 0 (scr-w) HDR-H))
              ((med-reminding?)
               (set! med-done-left (- med-done-left 1))
               (if (<= med-done-left 0) (med-finish!)))
              ((and (> (length med-list) 1) (not (info-active?)))
               (set! med-left (- med-left 1))
               (if (<= med-left 0) (med-next! 1))))))

;; 6. The web page's calls (app-web name body) ---------------------------------------------

(define (med->alist m)
  (list (cons 'id (med-id m)) (cons 'name (med-name m)) (cons 'qty (med-qty m))
        (cons 'slots (med-slots m)) (cons 'alt (med-alt? m)) (cons 'today (med-take-today? m))
        (cons 'photo (if (med-photo-info m) #t #f))))

(define (med-answer . extra)
  (apply web-ok (append (list (cons 'times med-times) (cons 'meds (map med->alist med-list))
                              (cons 'max MED-MAX) (cons 'reminding (med-reminding?))
                              (cons 'settings (map (lambda (p) (cons (string->symbol (car p)) (cdr p))) med-scales)))
                        extra)))

;; Saves the sizes body has (each 1..its maximum); #t, or the first key with a bad value
(define (med-save-scales! body)
  (let loop ((ks MED-SCALE-KEYS))
    (if (null? ks)
        (begin (med-load-scales!) (app-invalidate-all) #t)
        (let* ((k (car ks)) (v (web-field body (car k))) (n (and v (string->number v))))
          (cond ((not v) (loop (cdr ks)))
                ((and (integer? n) (>= n 1) (<= n (caddr k))) (app-config-set! (car k) v) (loop (cdr ks)))
                (else (car k)))))))

;; "08:00,12:30" -> the normalized list, or a message
(define (med-parse-times s)
  (let* ((parts (filter (lambda (p) (not (str-empty? (med-trim p)))) (str-split (or s "") #\,)))
         (times (map med-hm parts)))
    (cond ((memv #f times) "时间格式应为 HH:MM")
          ((> (length times) MED-TIMES-MAX) "最多 6 个时间点")
          ((let dup ((l times)) (and (pair? l) (or (member (car l) (cdr l)) (dup (cdr l))))) "时间点重复")
          (else times))))

;; Saves the medicine of body (id 0: a new one); its id, or a message
(define (med-save-from! body)
  (let* ((id (web-field-int body "id" 0))
         (old (and (> id 0) (med-find id)))
         (name (med-clean (or (web-field body "name") "") MED-NAME-MAX))
         (qty (med-clean (or (web-field body "qty") "") MED-QTY-MAX))
         (slots (filter (lambda (k) (and (>= k 1) (<= k MED-TIMES-MAX))) (med-ints (or (web-field body "slots") ""))))
         (alt (if (equal? (web-field body "alt") "1") 1 0))
         (start (web-field body "start"))         ; "0" today, "1" tomorrow, else kept
         (today (or (med-today) 0))
         (ref (cond ((equal? start "0") today)
                    ((equal? start "1") (+ today 1))
                    (old (med-ref old))
                    (else today))))
    (cond ((str-empty? name) "药品名称不能为空")
          ((and (> id 0) (not old)) "没有这个药品")
          ((and (not old) (>= (length med-list) MED-MAX)) "最多 20 个药品")
          (else
           (let ((m (vector (if old id (med-next-id)) name qty slots alt ref)))
             (set! med-list (if old
                                (map (lambda (x) (if (eq? x old) m x)) med-list)
                                (append med-list (list m))))
             (med-save!)
             (med-id m))))))

(define (app-web name body)
  (cond
    ((string=? name "list") (med-load!) (med-load-times!) (app-invalidate-all) (med-answer))
    ((string=? name "times")
     (let ((times (med-parse-times (web-field body "times"))))
       (if (string? times) (web-error times) (begin (med-save-times! times) (med-answer)))))
    ((string=? name "save")
     (let ((r (med-save-from! body)))
       (if (string? r) (web-error r) (med-answer (cons 'id r)))))
    ((string=? name "delete")
     (let ((m (med-find (web-field-int body "id" -1))))
       (if (not m)
           (web-error "没有这个药品")
           (begin (set! med-list (filter (lambda (x) (not (eq? x m))) med-list))
                  (if (>= med-index (max 1 (length med-list))) (set! med-index 0))
                  (med-save!)
                  (med-answer)))))
    ((string=? name "remind")                     ; the page's test: the reminder of a time point now
     (let ((k (web-field-int body "slot" 0)))
       (if (or (< k 1) (> k (length med-times)))
           (web-error "没有这个时间点")
           (begin (med-remind! (list-ref med-times (- k 1))) (med-answer)))))
    ((string=? name "stop") (if (med-reminding?) (med-finish!)) (med-answer))
    ((string=? name "settings")
     (let ((r (med-save-scales! body)))
       (if (string? r) (web-error (string-append "bad value for " r)) (med-answer))))
    (else (web-error (string-append "unknown call: " name)))))

;; 7. Start --------------------------------------------------------------------------------

(med-load!)
(med-load-times!)
(med-load-scales!)
(app-define! "吃药提醒" (list (app-local-page "药品" (lambda (items) #t))))
(set! gui-render-proc med-render)        ; its own header and footer
(let ((at (app-scheduled))) (if at (med-start! at)))
(app-invalidate-all)
