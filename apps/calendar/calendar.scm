;;; =========================================================================
;;; Calendar (万年历), 320x480 portrait, on the app framework (applib.scm).
;;; Data: the app proxy's /app/calendar (lunar_python's almanac and the
;;; sky computed on the PC):
;;;   1 today: countdowns on top, the time, world clocks, the date, the
;;;     lunar date, the solar term, festivals, 宜 and 忌
;;;   2 the month: every day with its lunar day (or term, festival, month)
;;;   3 the sky: the moon's phase, the sun's and the moon's bearing and height
;;; =========================================================================

;; 1. Settings (apps/calendar.ini, defaults in apps/calendar/meta.ini) ----------

(define (cal-today-url)
  (app-url (string-append "/app/calendar?view=today&cd=" (url-encode (app-config "countdown" ""))
                          "&wc=" (url-encode (app-config "world_clock" "")))))

(define (cal-month-url) (app-url "/app/calendar?view=month"))

(define (cal-sky-url)
  (app-url (string-append "/app/calendar?view=sky&loc=" (url-encode (app-config "location" "auto")))))

;; Day numbers in the month: simhei-24 from the font ROM when there, else the text font
(define cal-day-font (if (use-font 3 "simhei" 24 'system) 3 F-TEXT))

(define cal-moon-lit 61175)              ; #e8dfb8: the lit moon
(define cal-moon-dark 8583)              ; #26303c: its dark side

;; 2. Today -------------------------------------------------------------------------

(define cal-clock-y 0)                   ; where the clock is drawn (redrawn every second)
(define cal-world-y 0)                   ; where the world clocks are (redrawn every minute), 0: none
(define cal-world-hm "")                 ; the minute they show
(define cal-world-h 0)                   ; the height of their row (it takes the page's spare room)

;; "距 春节 还有 119 天" (or "今天是 春节"), centred, the name and the number in color
(define (cal-countdown y cd)
  (let* ((days (it-b cd)) (name (it-a cd))
         (parts (if (string=? days "0")
                    (list (list "今天是 " theme-text-muted) (list name theme-accent))
                    (list (list "距 " theme-text-muted) (list name theme-accent) (list " 还有 " theme-text-muted)
                          (list days theme-warning) (list " 天" theme-text-muted))))
         (width (fold-left + 0 (map (lambda (p) (txt-w (car p))) parts))))
    (let loop ((ps parts) (x (quotient (- (scr-w) width) 2)))
      (if (pair? ps)
          (begin
            (txt x y (car (car ps)) (cadr (car ps)))
            (loop (cdr ps) (+ x (txt-w (car (car ps))))))))))

(define (cal-clock y)
  (let* ((hm app-time)
         (n (string-length app-sec))      ; the device gives ":30" (":--" unsynced)
         (sec (cond ((= n 3) (substring app-sec 1 3)) ((= n 2) app-sec) (else "--")))
         (dw 38) (dh 70) (dt 7) (sw 18) (sh 34) (st 4)
         (hm-w (gui-seg7-width dw dt hm))
         (total (+ hm-w 10 (gui-seg7-width sw st sec)))
         (x (quotient (- (scr-w) total) 2)))
    (gui-seg7 x y dw dh dt hm theme-seg-on theme-seg-off theme-seg-on theme-seg-on)
    (gui-seg7 (+ x hm-w 10) (+ y (- dh sh)) sw sh st sec theme-seg-on theme-seg-off theme-seg-on theme-seg-on)))

;; World clocks. The proxy gives each place's UTC offset (DST included, see
;; world_clocks in tools/app_proxy.py); the time runs here from the UTC
;; second of the day (app-utc-sec) and the device's own offset, worked out
;; from its local time.
(define (cal-local-sec)                  ; "20:29" ":06" -> seconds of the day, #f unsynced
  (let ((n (string-length app-sec)))
    (and (= (string-length app-time) 5) (>= n 2)
         (let ((h (string->number (substring app-time 0 2))) (m (string->number (substring app-time 3 5)))
               (s (string->number (substring app-sec (- n 2) n))))
           (and h m s (+ (* h 3600) (* m 60) s))))))

(define (cal-day t) (quotient (- t (modulo t 86400)) 86400))   ; floor(t / 86400)

;; (hh:mm . days) of a place at offset `off`; days: its date against ours (-1, 0, 1)
(define (cal-world-time local off)
  (let* ((utc app-utc-sec)
         (mine (let ((d (modulo (- local utc) 86400))) (if (> d 50400) (- d 86400) d)))  ; UTC-12 .. UTC+14
         (t (+ utc off)) (tm (modulo t 86400)))
    (cons (string-append (pad2 (quotient tm 3600)) ":" (pad2 (quotient (remainder tm 3600) 60)))
          (- (cal-day t) (cal-day (+ utc mine))))))

;; The digit height of the world clocks: as tall as the room allows (22..40
;; px) and narrow enough for a column with a "+1" beside it
(define (cal-world-dh room cw)
  (let loop ((dh (max 22 (min 40 room))))
    (if (and (> dh 22) (> (+ (gui-seg7-width (quotient (* dh 11) 20) (max 3 (quotient dh 9)) "88:88") 22) (- cw 8)))
        (loop (- dh 2))
        dh)))

;; Up to 4 columns in a row of height h: padding, the name (with the zone's
;; abbreviation when it fits), seven-segment digits dh tall, and +1 / -1
;; when the date there is not ours; the padding splits what is left
(define (cal-world y h dh wcs)
  (let* ((n (length wcs)) (cw (quotient (scr-w) n)) (local (cal-local-sec))
         (pad (quotient (- h 22 dh) 2)) (dw (quotient (* dh 11) 20)) (dt (max 3 (quotient dh 9)))
         (ty (+ y pad)) (dy (+ y pad 22)))
    (let loop ((ws wcs) (i 0))
      (if (pair? ws)
          (let* ((wc (car ws)) (x (* i cw)) (cx (+ x (quotient cw 2)))
                 (full (if (str-empty? (it-b wc)) (it-a wc) (string-append (it-a wc) " " (it-b wc))))
                 (name (if (<= (txt-w full) (- cw 6)) full (it-a wc)))
                 (wt (if local (cal-world-time local (it-int wc 3)) (cons "--:--" 0)))
                 (mark (cond ((> (cdr wt) 0) "+1") ((< (cdr wt) 0) "-1") (else "")))
                 (seg-w (gui-seg7-width dw dt (car wt)))
                 (mark-w (if (str-empty? mark) 0 (+ 4 (txt-w mark))))
                 (dx (- cx (quotient (+ seg-w mark-w) 2))))
            (if (> i 0) (gui-line x (+ ty 2) x (+ dy dh -2) theme-divider))
            (if (<= (txt-w name) (- cw 6))
                (txt-center cx ty name theme-text-sub)
                (txt-fit (+ x 3) ty (- cw 6) name theme-text-sub))
            (gui-seg7 dx dy dw dh dt (car wt) theme-seg-on theme-seg-off theme-seg-on theme-seg-on)
            (if (> mark-w 0) (txt (+ dx seg-w 4) (+ dy (- dh 18)) mark theme-warning))
            (loop (cdr ws) (+ i 1)))))))

;; 宜 and 忌 on a grid: a column holds a word of two characters and half a
;; character of space, a longer word takes two columns, and a word that does
;; not fit moves whole to the next line. Every word starts on a column, so
;; the words and the spaces line up from one line to the next.
(define (cal-spaces n)
  (let loop ((n n) (s ""))
    (if (<= n 0) s (loop (- n 1) (string-append s " ")))))

;; The words of text (space separated) as lines of at most width px
(define (cal-grid-lines text width)
  (let* ((ch (txt-w "宜"))
         (sp (max 1 (txt-w " ")))
         (gap (* sp (max 1 (quotient (+ (quotient ch 2) (quotient sp 2)) sp))))
         (cell (+ ch ch gap))
         (cols (max 1 (quotient (+ width gap) cell)))
         (words (filter (lambda (s) (not (str-empty? s))) (str-split text #\space))))
    (let loop ((ws (if (null? words) '("无") words)) (col 0) (lw 0) (line "") (acc '()))
      (if (null? ws)
          (reverse (if (> col 0) (cons line acc) acc))
          (let* ((wd (car ws)) (wpx (txt-w wd))
                 (k (min cols (max 1 (quotient (+ wpx gap cell -1) cell)))))
            (if (and (> col 0) (> (+ col k) cols))
                (loop ws 0 0 "" (cons line acc))
                (let ((pad (quotient (- (* col cell) lw) sp)))
                  (loop (cdr ws) (+ col k) (+ lw (* pad sp) wpx)
                        (string-append line (cal-spaces pad) wd) acc))))))))

;; Rows for 宜 and 忌 (lines a and b) out of four: all of both when they fit;
;; one that needs a single row leaves the other three; else two each, and
;; the rest pages (config.ini [text] wrap_marquee)
(define (cal-yiji-rows a b)
  (cond ((<= (+ a b) 4) (list a b))
        ((<= b 1) (list 3 1))
        ((<= a 1) (list 1 3))
        (else (list 2 2))))

(define (cal-join-lines lines)
  (if (null? lines)
      ""
      (let loop ((ls (cdr lines)) (s (car lines)))
        (if (null? ls) s (loop (cdr ls) (string-append s "\n" (car ls)))))))

;; The laid-out lines, kept while the day's words stay the same (the render
;; runs for every band and every clock second)
(define cal-yiji-key #f)
(define cal-yiji-lines '())

(define (cal-yiji-layout yi ji width)
  (let ((key (list yi ji width)))
    (if (not (equal? key cal-yiji-key))
        (begin
          (set! cal-yiji-key key)
          (set! cal-yiji-lines (list (cal-grid-lines yi width) (cal-grid-lines ji width)))))
    cal-yiji-lines))

;; A round badge with one character, then the lines beside it in rows rows
(define (cal-yiji y ch color lines rows)
  (gui-round-rect 12 (+ y 1) 24 22 6 color #t)
  (txt 16 (+ y 4) ch theme-bg)
  (txt-wrap 44 (+ y 4) (- (scr-w) 56) (* LINE-H rows) (cal-join-lines lines) theme-text-sub))

(define (cal-render-today items)
  (let* ((w (scr-w)) (cx (quotient w 2))
         (cds (items-all items "cd"))
         (shown (if (> (length cds) 2) (take cds 2) cds))
         (y (body-top)))
    (for-each (lambda (cd) (cal-countdown y cd) (set! y (+ y 24))) shown)
    (if (pair? shown) (set! y (+ y 6)))
    (set! cal-clock-y y)
    (cal-clock (+ y 4))
    (set! y (+ y 80))
    (set! cal-world-y 0)
    (let ((date (items-find items "cdate")) (lunar (items-find items "lunar"))
          (term (items-find items "term")) (fest (items-find items "fest"))
          (wcs (items-all items "wclk")))
      ;; the world clocks take the room the rest of the page leaves: the
      ;; date to the solar term below need 104 px (+ 22 for a festival, + 100 for 宜忌)
      (if (pair? wcs)
          (let* ((spare (- (body-bottom) y 104 (if fest 22 0) (if (pair? items) 100 0)))
                 (dh (cal-world-dh (- spare 22 16) (quotient w (length wcs))))
                 (h (+ 22 dh (* 2 (max 4 (min 20 (quotient (- spare 22 dh) 2)))))))
            (set! cal-world-y y)
            (set! cal-world-h h)
            (set! cal-world-hm app-time)
            (cal-world y h dh wcs)
            (set! y (+ y h)))
          (set! y (+ y 6)))
      ;; the full date from the document (a new day fetches it again, see below)
      (txt-center cx y (if date (string-append (it-a date) "  " (it-b date)) (string-append app-date "  " app-week))
                  theme-text-main)
      (set! y (+ y 26))
      (cond (lunar
             (txt-center cx y (string-append "农历" (it-a lunar) "  " (it-b lunar)) theme-accent)
             (txt-center cx (+ y 22) (it-c lunar) theme-text-muted))
            ((null? items)                  ; no proxy yet: the device's own lunar date
             (if (> (string-length app-lunar) 0)
                 (txt-center cx y app-lunar theme-accent))  ; already "农历..."
             (txt-center cx (+ y 22) "节气与宜忌等待代理数据" theme-text-muted)))
      (set! y (+ y 48))
      (if term
          (txt-fit 12 y (- w 24)
                   (string-append (if (string=? (it-b term) "今日") (string-append "今日" (it-a term))
                                      (string-append (it-a term) (it-b term)))
                                  "  下一节气 " (it-c term) " " (it-d term))
                   theme-text-sub))
      (set! y (+ y 24))
      (if fest (txt-fit 12 y (- w 24) (it-a fest) theme-warning))
      (set! y (+ y (if fest 28 6)))
      (if (pair? items)
          (let* ((yi (items-find items "yi")) (ji (items-find items "ji"))
                 (lines (cal-yiji-layout (if yi (it-a yi) "") (if ji (it-a ji) "") (- w 56)))
                 (rows (cal-yiji-rows (length (car lines)) (length (cadr lines)))))
            (gui-line 12 y (- w 12) y theme-divider)
            (cal-yiji (+ y 8) "宜" theme-success (car lines) (car rows))
            (cal-yiji (+ y 8 (* LINE-H (car rows)) 10) "忌" theme-danger (cadr lines) (cadr rows)))))))

;; 3. The month ---------------------------------------------------------------------

(define CAL-WEEK '("日" "一" "二" "三" "四" "五" "六"))

(define (cal-render-month items)
  (let* ((m (items-find items "month")) (days (items-all items "day"))
         (w (scr-w)) (cw (quotient (- w 4) 7)) (x0 (quotient (- w (* cw 7)) 2))
         (first (if m (it-int m 2) 0)) (today (if m (it-int m 4) 0))
         (rows (quotient (+ first (length days) 6) 7))
         (top (body-top)))
    (if m (txt-center (quotient w 2) top (it-a m) theme-text-main))
    (let loop ((i 0) (names CAL-WEEK))      ; 日 一 ... 六
      (if (pair? names)
          (begin
            (txt-center (+ x0 (* i cw) (quotient cw 2)) (+ top 26) (car names)
                        (if (or (= i 0) (= i 6)) theme-danger theme-text-muted))
            (loop (+ i 1) (cdr names)))))
    (gui-line x0 (+ top 48) (- w x0) (+ top 48) theme-divider)
    (let* ((gy (+ top 52)) (rh (min 60 (quotient (- (body-bottom) gy) (max rows 1)))))
      (let loop ((ds days) (k first))
        (if (pair? ds)
            (let* ((d (car ds)) (col (remainder k 7)) (row (quotient k 7))
                   (x (+ x0 (* col cw))) (y (+ gy (* row rh))) (n (it-int d 1))
                   (num (it-a d)) (num-h (if (= cal-day-font F-TEXT) 18 26)))
              (if (and today (= n today))
                  (begin
                    (gui-round-rect (+ x 1) (+ y 1) (- cw 2) (- rh 2) 8 theme-accent-dark #t)
                    (gui-round-rect (+ x 1) (+ y 1) (- cw 2) (- rh 2) 8 theme-accent #f)))
              (gui-text-styled (- (+ x (quotient cw 2)) (quotient (gui-text-width num cal-day-font) 2)) (+ y 5)
                               num (cond ((and today (= n today)) theme-accent)
                                         ((or (= col 0) (= col 6)) theme-danger)
                                         (else theme-text-main))
                               cal-day-font)
              (txt-center (+ x (quotient cw 2)) (+ y 5 num-h) (it-b d)
                          (if (string=? (it-c d) "1") theme-accent theme-text-muted))
              (loop (cdr ds) (+ k 1))))))))

;; 4. The sky -----------------------------------------------------------------------

(define CAL-PI 3.14159265)
(define (cal-rad deg) (* deg (/ CAL-PI 180.0)))
(define (cal-int x) (inexact->exact (round x)))

(define (cal-dir az)
  (list-ref '("北" "东北" "东" "东南" "南" "西南" "西" "西北") (remainder (quotient (+ az 22) 45) 8)))

;; The moon as seen: a dark disc, then the lit part row by row (2 px rows).
;; elong: the moon's angle from the sun, 0 new, 180 full; waxing lit on the right.
(define (cal-moon cx cy r elong)
  (gui-circle cx cy r cal-moon-dark #t)
  (let ((c (cos (cal-rad elong))))
    (let loop ((dy (- r)))
      (if (< dy r)
          (let* ((hw (sqrt (exact->inexact (- (* r r) (* dy dy)))))
                 (x1 (if (<= elong 180) (+ cx (cal-int (* hw c))) (cal-int (- cx hw))))
                 (x2 (if (<= elong 180) (cal-int (+ cx hw)) (- cx (cal-int (* hw c))))))
            (if (> x2 x1) (gui-rect x1 (+ cy dy) (- x2 x1) 2 cal-moon-lit #t))
            (loop (+ dy 2))))))
  (gui-circle cx cy r theme-divider #f))

;; A dial of the sky: the horizon on the rim, the zenith in the middle, north up
(define (cal-dial cx cy r)
  (gui-circle cx cy r theme-divider #f)
  (gui-circle cx cy (quotient r 2) theme-divider #f)
  (gui-line (- cx r) cy (+ cx r) cy theme-divider)
  (gui-line cx (- cy r) cx (+ cy r) theme-divider)
  (txt-center cx (- cy r 20) "北" theme-text-muted)
  (txt-center cx (+ cy r 3) "南" theme-text-muted)
  (txt (+ cx r 4) (- cy 8) "东" theme-text-muted)
  (txt (- cx r 20) (- cy 8) "西" theme-text-muted))

;; A body on the dial: az degrees, alt tenths; below the horizon a ring on the rim
(define (cal-body cx cy r az alt10 color size)
  (let* ((up (>= alt10 0))
         (rr (if up (quotient (* r (- 900 alt10)) 900) r))
         (x (+ cx (cal-int (* rr (sin (cal-rad az))))))
         (y (- cy (cal-int (* rr (cos (cal-rad az)))))))
    (gui-circle x y size color up)))

(define (cal-alt-text alt10)
  (string-append (if (< alt10 0) "-" "") (int->str (quotient (abs alt10) 10)) "." (int->str (remainder (abs alt10) 10)) "°"))

(define (cal-body-text x y title color pos)
  (let ((az (it-int pos 1)) (alt (it-fixed pos 2 1)))
    (txt x y title color)
    (txt x (+ y 22) (string-append "方位 " (int->str az) "° " (cal-dir az)) theme-text-sub)
    (txt x (+ y 44) (string-append "高度 " (cal-alt-text alt)) (if (< alt 0) theme-text-muted theme-text-sub))
    (txt x (+ y 66) (string-append "出没 " (it-c pos) "-" (it-d pos)) theme-text-muted)))

(define (cal-render-sky items)
  (let ((moon (items-find items "moon")) (sun (items-find items "sun"))
        (mpos (items-find items "moonpos")) (loc (items-find items "loc"))
        (top (body-top)) (w (scr-w)))
    (if moon
        (let ((elong (it-int moon 4)) (next (str-split (it-e moon) #\,)))
          (cal-moon 70 (+ top 74) 54 elong)
          (txt 146 (+ top 8) (it-a moon) theme-accent)
          (txt 146 (+ top 32) (string-append "照亮 " (it-b moon) "%") theme-text-sub)
          (txt 146 (+ top 54) (string-append "月龄 " (it-c moon) " 天") theme-text-sub)
          (txt 146 (+ top 80) (string-append "满月 " (car next)) theme-text-muted)
          (txt 146 (+ top 102) (string-append "新月 " (if (pair? (cdr next)) (cadr next) "--")) theme-text-muted)))
    (gui-line 12 (+ top 146) (- w 12) (+ top 146) theme-divider)
    (let ((cx 90) (cy (+ top 268)) (r 60))
      (cal-dial cx cy r)
      (if sun (cal-body cx cy r (it-int sun 1) (it-fixed sun 2 1) theme-warning 7))
      (if mpos (cal-body cx cy r (it-int mpos 1) (it-fixed mpos 2 1) cal-moon-lit 6)))
    (if sun (cal-body-text 176 (+ top 158) "太阳" theme-warning sun))
    (if mpos (cal-body-text 176 (+ top 258) "月亮" cal-moon-lit mpos))
    (if loc (txt-fit 176 (+ top 356) (- w 188) (it-a loc) theme-text-muted))))

;; 5. The app -----------------------------------------------------------------------

(define cal-day-seen "")

;; Every second: the clock on page 1, the world clocks when the minute
;; changes; a new day fetches the page again
(set! app-tick-proc
      (lambda (tick)
        (if (and (= app-page-index 0) (not (info-active?)) (> cal-clock-y 0))
            (gui-invalidate 0 cal-clock-y (scr-w) 82))
        (if (and (= app-page-index 0) (not (info-active?)) (> cal-world-y 0) (not (string=? app-time cal-world-hm)))
            (gui-invalidate 0 cal-world-y (scr-w) cal-world-h))
        (if (and (> (string-length app-date) 0) (not (string=? app-date cal-day-seen)))
            (begin
              (if (> (string-length cal-day-seen) 0) (app-start-feed!))
              (set! cal-day-seen app-date)
              (app-invalidate-all)))))      ; the date (also when the clock first syncs)

(set! app-render-empty-pages '(0))      ; the clock needs no proxy

(set! app-subtitle-proc
      (lambda (items) (let ((l (items-find items "lunar"))) (if l (string-append "农历" (it-a l)) ""))))

(app-define! "万年历"
  (list (app-page "今日" cal-today-url 600000 cal-render-today)
        (app-page "月历" cal-month-url 3600000 cal-render-month)
        (app-page "月相" cal-sky-url 60000 cal-render-sky)))
