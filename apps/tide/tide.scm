;;; =========================================================================
;;; Tide (潮汐), 320x480 portrait, on the app framework (applib.scm).
;;;
;;; Two data paths, one screen:
;;;   * the app proxy (default): /app/tide?loc= from the system proxy, or
;;;     the app's own proxy_url. The proxy locates the device from its
;;;     public IP (or the location setting: a city, or lon,lat) and returns
;;;     Open-Meteo's global tide model, 15 min apart, for that point.
;;;   * built-in table (fallback, no network): the National Marine Data and
;;;     Information Service monthly table for Haikou (Xiuying), stored by
;;;     lunar day (1..30) with a half-cosine between the extrema. The firmware
;;;     gives a lunar date but no year (time-epoch is a reserved API), so the
;;;     table keeps the app useful on a board without a server.
;;;
;;; Pages 1 and 2 show whichever path has data; page 1's section line names
;;; the height datum (the table uses its chart datum, the model reports
;;; heights above mean sea level).
;;;   1 now   2 today's extrema   3 about
;;; =========================================================================

(define TIDE-PI 3.14159265358979)
(define TIDE-STATION "海口（秀英）")
(define TIDE-INTERVAL 300000)          ; the model updates hourly: 5 min is plenty

;; (minute-of-day . height-cm) per lunar day, from the official table
(define TIDE-DAYS
  '(
    (1  (187 . 103) (547 . 173) (840 . 122) (1265 . 231))
    (2  (198 . 126) (526 . 184) (891 . 91) (1326 . 226))
    (3  (208 . 150) (515 . 203) (941 . 68) (1386 . 216))
    (4  (215 . 168) (518 . 224) (991 . 57))
    (5  (13 . 202) (220 . 180) (537 . 241) (1038 . 56))
    (6  (568 . 251) (1077 . 62))
    (7  (606 . 254) (1107 . 71))
    (8  (642 . 251) (1133 . 80))
    (9  (660 . 244) (1171 . 90) (1310 . 95))
    (10 (2 . 91) (595 . 239))
    (11 (56 . 89) (604 . 232))
    (12 (83 . 89) (602 . 221))
    (13 (96 . 90) (582 . 208) (769 . 201) (939 . 205))
    (14 (113 . 95) (564 . 194) (776 . 177) (1094 . 204))
    (15 (135 . 105) (537 . 183) (811 . 146) (1199 . 213))
    (16 (157 . 124) (501 . 180) (853 . 112) (1268 . 221))
    (17 (172 . 149) (471 . 192) (897 . 79) (1338 . 225))
    (18 (181 . 175) (466 . 215) (943 . 52) (1426 . 222))
    (19 (190 . 199) (481 . 240) (991 . 35))
    (20 (508 . 260) (1041 . 29))
    (21 (539 . 271) (1094 . 35))
    (22 (520 . 274) (1169 . 49))
    (23 (614 . 260) (1139 . 48))
    (24 (622 . 265) (1199 . 60))
    (25 (611 . 264))
    (26 (40 . 59) (627 . 258))
    (27 (107 . 54) (656 . 244))
    (28 (146 . 56) (982 . 230))
    (29 (167 . 66) (1097 . 227))
    (30 (177 . 82) (583 . 176) (790 . 158) (1194 . 230))
    ))

;; 1. The built-in day curve ------------------------------------------------------

(define (tide-wrap L) (cond ((< L 1) 30) ((> L 30) 1) (else L)))

(define (tide-day L)
  (let ((e (assv (tide-wrap L) TIDE-DAYS))) (if e (cdr e) '())))

(define (tide-last l) (if (null? (cdr l)) (car l) (tide-last (cdr l))))

;; The day's extrema plus one on each side, so 0..1440 is always bracketed
(define (tide-points L)
  (let* ((prev (tide-day (- L 1)))
         (cur (tide-day L))
         (next (tide-day (+ L 1)))
         (a (if (pair? prev)
                (list (cons (- (car (tide-last prev)) 1440) (cdr (tide-last prev))))
                '()))
         (b (if (pair? next)
                (list (cons (+ (car (car next)) 1440) (cdr (car next))))
                '())))
    (append a cur b)))

;; Height (cm) at minute m: half a cosine between the two bracketing extrema
(define (tide-at pts m)
  (let loop ((p pts))
    (cond ((null? p) #f)
          ((null? (cdr p)) (cdr (car p)))
          ((<= m (car (cadr p)))
           (let* ((p0 (car p)) (p1 (cadr p))
                  (t0 (car p0)) (h0 (cdr p0)) (t1 (car p1)) (h1 (cdr p1))
                  (f (/ (- m t0) (max 1 (- t1 t0)))))
             (+ h0 (* (- h1 h0) (/ (- 1 (cos (* TIDE-PI f))) 2)))))
          (else (loop (cdr p))))))

;; 'high / 'low of an extremum, from its neighbours; -1/+1 cm steps included
(define (tide-kind prev cur next)
  (let ((h (cdr cur)))
    (cond ((and prev next) (if (and (>= h (cdr prev)) (>= h (cdr next))) 'high 'low))
          (prev (if (>= h (cdr prev)) 'high 'low))
          (next (if (>= h (cdr next)) 'high 'low))
          (else 'high))))

;; (minute cm kind) of every extremum in the given points
(define (tide-extrema pts)
  (let loop ((prev #f) (rest pts) (acc '()))
    (if (null? rest)
        (reverse acc)
        (let ((cur (car rest)) (next (if (null? (cdr rest)) #f (cadr rest))))
          (loop cur (cdr rest)
                (cons (list (car cur) (cdr cur) (tide-kind prev cur next)) acc))))))

(define (tide-in-day es)
  (filter (lambda (e) (and (>= (car e) 0) (< (car e) 1440))) es))

;; (max . min) of a sample vector: the day's highest and lowest water
(define (tide-samples-range v)
  (let loop ((i 1) (hi (vector-ref v 0)) (lo (vector-ref v 0)))
    (if (< i (vector-length v))
        (loop (+ i 1) (max hi (vector-ref v i)) (min lo (vector-ref v i)))
        (cons hi lo))))

;; 97 samples, every 15 minutes
(define (tide-samples pts)
  (let ((v (make-vector 97 0)))
    (let loop ((i 0))
      (if (< i 97)
          (begin (vector-set! v i (tide-int (tide-at pts (* i 15)))) (loop (+ i 1)))
          v))))

;; 2. Text and time --------------------------------------------------------------

(define (tide-int x) (if (inexact? x) (inexact->exact (round x)) x))
(define (tide-m cm) (fixed->str (tide-int cm) 2))        ; 152 -> "1.52"

(define (tide-hm m)
  (let ((m (min 1439 (max 0 m))))
    (string-append (pad2 (quotient m 60)) ":" (pad2 (remainder m 60)))))

(define (tide-hm->min s)
  (if (or (not (string? s)) (< (string-length s) 5) (string=? s "--:--"))
      #f
      (+ (* 60 (string->number (substring s 0 2))) (string->number (substring s 3 5)))))

(define (tide-cn-num s)
  (cond ((string=? s "一") 1) ((string=? s "二") 2) ((string=? s "三") 3)
        ((string=? s "四") 4) ((string=? s "五") 5) ((string=? s "六") 6)
        ((string=? s "七") 7) ((string=? s "八") 8) ((string=? s "九") 9)
        ((string=? s "十") 10) (else #f)))

;; "农历九月十三" -> 13 ("农历闰二月初一" -> 1); #f while the clock is unsynced
(define (tide-lunar-day)
  (let* ((s app-lunar) (n (string-length s)))
    (if (< n 6)
        #f
        (let* ((d (substring s (- n 6) n)) (a (substring d 0 3)) (b (substring d 3 6)))
          (cond ((string=? a "初") (tide-cn-num b))
                ((string=? a "廿") (let ((k (tide-cn-num b))) (and k (+ 20 k))))
                ((and (string=? a "二") (string=? b "十")) 20)
                ((and (string=? a "三") (string=? b "十")) 30)
                ((string=? a "十") (let ((k (tide-cn-num b))) (and k (+ 10 k))))
                (else #f))))))

(define (tide-cn-day n)
  (let ((d (list-ref '("" "一" "二" "三" "四" "五" "六" "七" "八" "九") (remainder n 10)))
        (t (quotient n 10)))
    (cond ((= n 10) "初十") ((= n 20) "二十") ((= n 30) "三十")
          ((< n 10) (string-append "初" d))
          ((< n 20) (string-append "十" d))
          (else (string-append "廿" d)))))

(define (tide-range-kind r)
  (cond ((< r 80) "小潮") ((< r 150) "中潮") (else "大潮")))

;; 3. The two data paths, one view ------------------------------------------------
;; view: #(datum station samples lo hi es now-min now-cm rate source top bot labels)
;;   es      ((minute cm kind) ...), minutes from today 00:00 (1440+ = tomorrow)
;;   labels  ("今日 农历十三" "明日 农历十四" "后日 农历十五")

(define (tide-view-frame datum station samples es now-min now-cm rate source top bot labels)
  (vector datum station samples
          (- (* 20 (quotient bot 20)) 20)                 ; axis: 20 cm steps + pad
          (+ (* 20 (+ 1 (quotient top 20))) 20)
          es now-min now-cm rate source top bot labels))

(define (tide-v-datum v) (vector-ref v 0))
(define (tide-v-station v) (vector-ref v 1))
(define (tide-v-samples v) (vector-ref v 2))
(define (tide-v-lo v) (vector-ref v 3))
(define (tide-v-hi v) (vector-ref v 4))
(define (tide-v-es v) (vector-ref v 5))
(define (tide-v-now v) (vector-ref v 6))
(define (tide-v-cur v) (vector-ref v 7))
(define (tide-v-rate v) (vector-ref v 8))
(define (tide-v-source v) (vector-ref v 9))
(define (tide-v-top v) (vector-ref v 10))
(define (tide-v-bot v) (vector-ref v 11))
(define (tide-v-labels v) (vector-ref v 12))

;; Everything one lunar day needs, built once: the board redraws the chart
;; every minute and must not allocate a new vector and lists each time.
(define tide-cache-L #f)
(define tide-pts '())
(define tide-es '())
(define tide-nx '())
(define tide-nv '())
(define tide-samples-v (vector))
(define tide-lo 0)
(define tide-hi 300)
(define tide-top 300)
(define tide-bot 0)

(define (tide-prepare! L)
  (if (not (eqv? L tide-cache-L))
      (let* ((pts (tide-points L))
             (es (tide-in-day (tide-extrema pts)))
             (samples (tide-samples pts))
             (st (tide-samples-range samples))
             (top (car st))
             (bot (cdr st)))
        (set! tide-cache-L L)
        (set! tide-pts pts)
        (set! tide-es es)
        (set! tide-top top)
        (set! tide-bot bot)
        (set! tide-lo (- (* 20 (quotient bot 20)) 20))
        (set! tide-hi (+ (* 20 (+ 1 (quotient top 20))) 20))
        (set! tide-samples-v samples)
        (set! tide-nx (tide-in-day (tide-extrema (tide-points (+ L 1)))))
        (set! tide-nv (tide-in-day (tide-extrema (tide-points (+ L 2))))))))

;; a day's extrema shifted to minutes from today
(define (tide-shift es off)
  (map (lambda (e) (list (+ off (car e)) (cadr e) (caddr e))) es))

(define (tide-view-local)
  (let ((L (tide-lunar-day)))
    (if (not L)
        #f
        (begin
          (tide-prepare! L)
          (let* ((nm (tide-hm->min app-time))
                 (es (append tide-es (tide-shift tide-nx 1440) (tide-shift tide-nv 2880))))
            (tide-view-frame
             "潮高基准面" TIDE-STATION tide-samples-v es nm
             (if nm (tide-at tide-pts nm) (tide-at tide-pts 720))
             (if nm (* 3 (- (tide-at tide-pts (+ nm 10)) (tide-at tide-pts (- nm 10)))) 0)
             "本地月报表" tide-top tide-bot
             (list (string-append "农历" (tide-cn-day L))
                   (string-append "农历" (tide-cn-day (tide-wrap (+ L 1))))
                   (string-append "农历" (tide-cn-day (tide-wrap (+ L 2)))))))))))

;; /app/tide document: meta | now | curve (97 cm values) | ext (a hh:mm, b cm,
;; c high|low, d day offset) | upd
(define tide-view-of #f)                 ; the document the cached view was made from
(define tide-view-cached #f)

;; The network view, parsed once per document (render runs per band)
(define (tide-view-items items)
  (if (not (eq? items tide-view-of))
      (begin (set! tide-view-cached (tide-view-items-parse items))
             (set! tide-view-of items)))
  tide-view-cached)

(define (tide-view-items-parse items)
  (let ((cu (items-find items "curve")))
    (if (and cu (pair? (string->ints (it-a cu))))
        (let* ((vals (string->ints (it-a cu)))
               (v (list->vector vals))
               (mt (items-find items "meta"))
               (nw (items-find items "now"))
               (es (map (lambda (it)
                          (let* ((t (tide-hm->min (it-a it)))
                                 (off (if (equal? (it-f it 4) "1") 1440 0))
                                 (kind (if (equal? (it-c it) "high") 'high 'low)))
                            (list (+ off (if t t 0))
                                  (tide-int (or (string->number (it-b it)) 0))
                                  kind)))
                        (items-all items "ext")))
               (top-bot (tide-samples-range v)))
          (tide-view-frame
           "平均海面"
           (if mt (it-a mt) "模型点")
           v es
           (if nw (tide-hm->min (it-a nw)) (tide-hm->min app-time))
           (if nw (tide-int (or (string->number (it-b nw)) 0)) 0)
           (if nw (tide-int (or (string->number (it-c nw)) 0)) 0)
           "联网模型" (car top-bot) (cdr top-bot) '("" "" "")))
        #f)))

;; 4. Page 1: now ------------------------------------------------------------------

(define CH-X 10)
(define CH-Y 168)
(define CH-W 300)
(define CH-H 156)

(define (tide-y h lo hi)
  (- (+ CH-Y CH-H) (quotient (* CH-H (- h lo)) (max 1 (- hi lo)))))

(define (tide-dot x y c)
  (gui-rect (- x 2) (- y 2) 5 5 c #t))

(define (tide-render-chart samples lo hi nm es top bot)
  (gui-rect CH-X CH-Y CH-W CH-H theme-card-hdr #t)
  (let loop ((i 1))
    (if (< i 4)
        (begin (gui-line CH-X (+ CH-Y (quotient (* CH-H i) 4))
                         (+ CH-X CH-W) (+ CH-Y (quotient (* CH-H i) 4)) theme-dark-gray)
               (loop (+ i 1)))))
  (gui-chart CH-X CH-Y CH-W CH-H samples 0 (vector-length samples) lo hi theme-accent)
  ;; every extremum gets a dot; the text only on the day's dominant high and
  ;; low (in dead water the 2nd high differs from the 1st by a few cm)
  (let loop ((es es))
    (if (pair? es)
        (let* ((e (car es)) (t (car e)) (h (cadr e)) (k (caddr e))
               (mark (if (eq? k 'high) (<= (- top h) 15) (<= (- h bot) 15))))
          (if (and (>= t 0) (< t 1440))
              (let ((x (+ CH-X (quotient (* CH-W t) 1440)))
                    (y (tide-y h lo hi)))
                (tide-dot x y (if (eq? k 'high) theme-accent theme-text-sub))
                (if mark
                    (if (eq? k 'high)
                        (txt (- x 8) (max (+ CH-Y 2) (- y 22)) "高" theme-accent)
                        (txt (- x 8) (min (- (+ CH-Y CH-H) 20) (+ y 4)) "低" theme-text-sub)))))
          (loop (cdr es)))))
  (if nm
      (let ((x (+ CH-X (quotient (* CH-W nm) 1440))))
        (gui-line x CH-Y x (+ CH-Y CH-H) theme-warning))))

(define (tide-render-waiting why)
  (txt 14 70 why theme-text-muted)
  (txt-wrap 14 98 (- (scr-w) 28) 60 "联网时由应用代理按设备的公网 IP（或设置里的位置）取潮汐模型；没有数据时用本机海口月报表。"
            theme-text-sub))

(define (tide-render-now items)
  (let ((v (if (pair? items) (tide-view-items items) (tide-view-local))))
    (if (not v)
        (tide-render-waiting "等待网络对时")
        (let* ((nm (tide-v-now v))
               (cur (tide-v-cur v))
               (rate (tide-v-rate v))
               (es (tide-v-es v))
               (next (let loop ((l es))
                       (cond ((null? l) #f)
                             ((and nm (> (car (car l)) nm)) (car l))
                             (else (loop (cdr l))))))
               (hi-cm (tide-v-top v))
               (lo-cm (tide-v-bot v))
               (up (> rate 0)))
          ;; now
          (txt 10 42 "现在潮高" theme-text-muted)
          (big 10 56 (tide-m cur) theme-text-main)
          (txt (+ 14 (big-w (tide-m cur))) 72 "米" theme-text-sub)
          (gui-round-rect 206 58 100 24 6 (if up theme-accent-dark theme-card-hdr) #t)
          (txt-center 256 61 (if up "涨潮" "落潮") (if up theme-accent theme-warning))
          (txt-right 306 88 (string-append (if up "+" "-") (tide-m (abs rate)) " 米/时")
                     theme-text-muted)
          ;; the next extremum
          (if next
              (begin
                (txt 10 106
                     (string-append "下次" (if (eq? (caddr next) 'high) "高潮" "低潮") " "
                                    (if (>= (car next) 1440) "明天 " "")
                                    (tide-hm (remainder (car next) 1440)) "  " (tide-m (cadr next)) " 米")
                     theme-text-sub)
                (if nm
                    (let* ((left (- (car next) nm)) (hr (quotient left 60)) (mi (remainder left 60)))
                      (txt 10 128
                           (string-append "还有 "
                                          (if (> hr 0)
                                              (string-append (number->string hr) " 小时 "
                                                             (number->string mi) " 分")
                                              (string-append (number->string mi) " 分")))
                           theme-accent))))
              (txt 10 106 "今天没有更多高低潮" theme-text-muted))
          ;; the curve
          (section-note 148 "今日潮位" (tide-v-datum v))
          (tide-render-chart (tide-v-samples v) (tide-v-lo v) (tide-v-hi v) nm es hi-cm lo-cm)
          (txt 10 (+ CH-Y CH-H 4) "00" theme-text-muted)
          (txt-center (+ CH-X (quotient CH-W 4)) (+ CH-Y CH-H 4) "06" theme-text-muted)
          (txt-center (+ CH-X (quotient CH-W 2)) (+ CH-Y CH-H 4) "12" theme-text-muted)
          (txt-center (+ CH-X (quotient (* 3 CH-W) 4)) (+ CH-Y CH-H 4) "18" theme-text-muted)
          (txt-right (+ CH-X CH-W) (+ CH-Y CH-H 4) "24" theme-text-muted)
          ;; summary
          (txt 10 366 (string-append "最高 " (tide-m hi-cm) " 米") theme-text-main)
          (txt 164 366 (string-append "最低 " (tide-m lo-cm) " 米") theme-text-main)
          (txt 10 390 (string-append "潮差 " (tide-m (- hi-cm lo-cm)) " 米") theme-text-sub)
          (txt-right 306 390 (tide-range-kind (- hi-cm lo-cm)) theme-accent)
          (txt 10 414 (string-append (tide-v-station v) " · " (tide-v-source v))
               theme-text-muted)))))

;; 5. Page 2: the extrema table ---------------------------------------------------

(define (tide-kind-text k) (if (eq? k 'high) "高潮" "低潮"))

(define (tide-row y e)
  (let ((t (car e)) (h (cadr e)) (k (caddr e)))
    (txt 12 y (tide-hm (remainder t 1440)) theme-text-main)
    (txt 96 y (tide-kind-text k) (if (eq? k 'high) theme-accent theme-text-sub))
    (txt-right 306 y (string-append (tide-m h) " 米") theme-text-main)
    (gui-line 12 (+ y 24) 306 (+ y 24) theme-divider)))

(define (tide-render-rows es y n)
  (if (or (null? es) (<= n 0))
      y
      (begin (tide-row y (car es)) (tide-render-rows (cdr es) (+ y 30) (- n 1)))))

(define (tide-day-rows es d)
  (filter (lambda (e) (and (>= (car e) (* 1440 d)) (< (car e) (* 1440 (+ d 1))))) es))

(define (tide-render-table items)
  (let ((v (if (pair? items) (tide-view-items items) (tide-view-local))))
    (if (not v)
        (tide-render-waiting "等待网络对时")
        (let* ((es (tide-v-es v))
               (labels (tide-v-labels v))
               (today (tide-day-rows es 0))
               (y0 (tide-render-rows today (+ (body-top) 24) 4)))
          (section-note (body-top) "今日" (if (pair? labels) (car labels) ""))
          (if (null? today)
              (txt 12 (+ (body-top) 26) "今天没有明显的高低潮" theme-text-muted))
          (section-note y0 "明日" (if (pair? (cdr labels)) (cadr labels) ""))
          (let ((y1 (tide-render-rows (tide-day-rows es 1) (+ y0 22) 4)))
            (if (and (< y1 400) (pair? (tide-day-rows es 2)))
                (begin
                  (section-note y1 "后日" (if (and (pair? (cdr labels)) (pair? (cddr labels)))
                                              (caddr labels) ""))
                  (tide-render-rows (tide-day-rows es 2) (+ y1 22) 2))))))))

;; 6. Page 3: about ----------------------------------------------------------------

(define (tide-about-meta items field)
  (let ((mt (items-find items "meta")))
    (if mt (it-f mt field) "")))

(define (tide-render-about items)
  (let* ((net? (pair? items))
         (mt (and net? (items-find items "meta")))
         (name (if mt (it-a mt) TIDE-STATION))
         (place (if mt (it-d mt) ""))
         (coords (if net?
                     (string-append "N" (tide-about-meta items 2) " E" (tide-about-meta items 3))
                     "N20.02 E110.27"))
         ;; the server names a point it cannot place as "N.. E..": show the place
         (shown (if (and mt (str-starts? name "N") (str-contains? name " E")) place name))
         (line2 (if (or (str-empty? place) (string=? place shown))
                    coords
                    (string-append coords " · " place))))
    (section (body-top) "站点")
    (txt-fit 12 (+ (body-top) 18) (- (scr-w) 24) shown theme-text-main)
    (txt-fit 12 (+ (body-top) 38) (- (scr-w) 24) line2 theme-text-sub)
    (section 96 "数据")
    (txt-wrap 12 114 (- (scr-w) 24) 76
              (if net?
                  "联网：应用代理按设备位置取 Open-Meteo 全球潮汐模型（15 分钟一个点），是模型值，不是港口官方表。"
                  "本地：国家海洋信息中心 2026 年 10 月海口（秀英）高低潮表，按农历日 1-30 存储，极值之间半余弦插值。")
              theme-text-sub)
    (section 200 "潮高基准")
    (txt-wrap 12 218 (- (scr-w) 24) 56
              (if net?
                  "模型相对平均海面，官方表相对潮高基准面（平均海面下 1.5 米）。"
                  "潮高相对潮高基准面（平均海面下 150 厘米），与官方月报口径一致。")
              theme-text-sub)
    (section 284 "精度")
    (txt-wrap 12 302 (- (scr-w) 24) 80
              "天文潮，不含风暴增水与径流。模型点在近岸浅水与海峡处相位可差数十分钟、振幅可差数十厘米；仅供出行参考，不可用于航海与赶海安全判断。"
              theme-warning)
    (txt 12 400 (string-append "数据路径：" (if net? "联网模型" "本地月报表")) theme-text-muted)))

;; 7. Start --------------------------------------------------------------------------

(define (tide-now-url) (app-url (string-append "/app/tide?loc=" (url-encode (app-config "location" "auto")))))

(define (tide-footer!)
  (let ((L (tide-lunar-day)))
    (set! app-footer-text
          (if L
              (string-append TIDE-STATION " · 农历" (tide-cn-day L) " · 天文潮")
              (string-append TIDE-STATION " · 等待对时")))))

(define tide-footer-lunar "")

(tide-footer!)

(set! app-subtitle-proc
      (lambda (items)
        (if (> (string-length app-lunar) 6) (substring app-lunar 6 (string-length app-lunar)) "")))

(set! app-tick-proc
      (lambda (tick)
        (if (not (string=? app-lunar tide-footer-lunar))
            (begin (set! tide-footer-lunar app-lunar) (tide-footer!)))
        (if (= (remainder tick 60) 0)
            (gui-invalidate 0 HDR-H (scr-w) (- (gui-height) HDR-H FTR-H)))))

(app-define! "潮汐"
  (list (app-page "潮位" tide-now-url TIDE-INTERVAL tide-render-now)
        (app-page "潮时" tide-now-url TIDE-INTERVAL tide-render-table)
        (app-page "关于" tide-now-url TIDE-INTERVAL tide-render-about)))

;; every page draws from the built-in table until (or unless) the server answers
(set! app-render-empty-pages '(0 1 2))
