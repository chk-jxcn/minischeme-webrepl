;;; =========================================================================
;;; Stocks (股票行情), 320x480 portrait, on the app framework (applib.scm).
;;; Data: the app proxy's /app/stocks (Tencent quotes). Prices arrive as
;;; text ("1263.00"), changes as signed text ("+0.57"), the intraday trend in
;;; basis points against the previous close, 30-day closes in per-mille
;;; against the first day. Red rises, green falls.
;;;   1 home: indices, the index's intraday chart, the first watch list stocks
;;;   2 watch list   3 intraday charts of three indices   4 30-day trends
;;; =========================================================================

(define STOCKS-INTERVAL 20000)           ; the proxy caches 15 s while trading
(define STOCKS-KLINE-INTERVAL 600000)

(define (stocks-codes) (app-config "codes" "sh600519,sz300750,sz000858"))
(define (stocks-index) (app-config "index" "sh000001"))

(define (stocks-all-url)
  (app-url (string-append "/app/stocks?view=all&codes=" (url-encode (stocks-codes))
                          "&index=" (url-encode (stocks-index)))))

(define (stocks-url view)
  (lambda ()
    (app-url (string-append "/app/stocks?view=" view "&codes=" (url-encode (stocks-codes))
                            "&index=" (url-encode (stocks-index))))))

;; "+0.57" -> 57 (hundredths), for colors and bars
(define (pct-of it) (it-fixed it 3 2))

(define (pct-text it) (string-append (it-c it) "%"))

;; Quote "e": "change,high,low,previous close"
(define (q-change it) (str-part (it-e it) #\, 0))
(define (q-high it) (str-part (it-e it) #\, 1))
(define (q-low it) (str-part (it-e it) #\, 2))

;; "1282.00" -> "1282": four digits are precise enough for a day's range
(define (short-price s)
  (let ((parts (str-split s #\.)))
    (if (>= (string-length (car parts)) 4) (car parts) s)))

;; Change % in a filled box, right-aligned at xr
(define (pct-box xr y it)
  (let* ((t (pct-text it)) (w (max 64 (+ (txt-w t) 12))) (p (pct-of it)))
    (gui-round-rect (- xr w) y w 22 4 (rise-color p) #t)
    (txt-center (- xr (quotient w 2)) (+ y 3) t theme-bg)))

(define (market-badge items)
  (let ((m (items-find items "meta")))
    (if m
        (let* ((t (it-a m)) (open? (equal? t "交易中")) (w (+ (txt-w t) 12)))
          (gui-round-rect (- 310 w) (body-top) w 22 6 (if open? theme-success theme-text-muted) #f)
          (txt (+ (- 310 w) 6) (+ (body-top) 3) t (if open? theme-success theme-text-muted))))))

;; Intraday chart: basis points around the previous close (the zero line);
;; the x axis is the whole trading day (241 minutes), so a morning chart
;; covers only its part of the width
(define (trend-chart x y w h tr)
  (let* ((pts (it-ints tr 1)) (minutes (or (it-int tr 4) 241))
         (m (max 50 (list-max (map abs (if (pair? pts) pts '(0))))))
         (lo (- 0 m)) (hi m)
         (cw (max 8 (quotient (* w (clamp minutes 2 241)) 241)))
         (last (if (pair? pts) (list-ref pts (- (length pts) 1)) 0)))
    (gui-rect x y w h theme-card-hdr #t)
    (gui-line x (+ y (quotient h 2)) (+ x w -1) (+ y (quotient h 2)) theme-divider)  ; previous close
    (gui-line (+ x (quotient w 2)) y (+ x (quotient w 2)) (+ y h -1) theme-divider)  ; 11:30 / 13:00
    (line-chart x y cw h pts lo hi (rise-color last))
    (txt (+ x 2) y (string-append "+" (fixed->str m 2) "%") theme-text-muted)
    (txt (+ x 2) (+ y h -18) (string-append "-" (fixed->str m 2) "%") theme-text-muted)))

;; 1. Home ---------------------------------------------------------------------------

(define (index-tile x y it)
  (gui-round-rect x y 146 54 6 theme-card-border #f)
  (txt (+ x 8) (+ y 5) (it-a it) theme-text-muted)
  (txt-right (+ x 138) (+ y 5) (pct-text it) (rise-color (pct-of it)))
  (txt (+ x 8) (+ y 29) (it-b it) (rise-color (pct-of it)))
  (txt-right (+ x 138) (+ y 29) (q-change it) (rise-color (pct-of it))))

(define (quote-row y it)
  (txt 10 (+ y 2) (it-a it) theme-text-main)
  (txt 10 (+ y 22) (it-d it) theme-text-muted)
  (txt-right 220 (+ y 10) (it-b it) (rise-color (pct-of it)))
  (pct-box 310 (+ y 8) it)
  (gui-line 10 (+ y 43) 310 (+ y 43) theme-divider))

(define (stocks-render-home items)
  (let ((idx (items-all items "idx")) (tr (items-find items "trend")) (qs (items-all items "q")))
    (let loop ((xs idx) (i 0))
      (if (and (pair? xs) (< i 4))
          (begin
            (index-tile (+ 10 (* (remainder i 2) 154)) (+ 38 (* (quotient i 2) 60)) (car xs))
            (loop (cdr xs) (+ i 1)))))
    (if tr
        (let* ((code (it-c tr)) (iq (items-where items "idx" 4 code))
               (e (it-e tr)))
          (txt 10 162 (string-append (if iq (it-a iq) code) " 分时") theme-accent)
          (txt-right 310 162 (string-append "高 " (str-part e #\, 0) "  低 " (str-part e #\, 1)) theme-text-muted)
          (trend-chart 10 184 300 120 tr)))
    (let loop ((xs qs) (y 312) (i 0))
      (if (and (pair? xs) (< i 3))
          (begin (quote-row y (car xs)) (loop (cdr xs) (+ y 46) (+ i 1)))))))

;; 2. Watch list -------------------------------------------------------------------------

(define (stocks-render-list items)
  (market-badge items)
  (let ((qs (items-all items "q")))
    (if (null? qs)
        (txt 14 70 "自选股为空：在应用设置 codes 中填写股票代码" theme-text-muted)
        (let loop ((xs qs) (y (+ (body-top) 28)) (i 0))
          (if (and (pair? xs) (< i 9))
              (let ((it (car xs)))
                (txt 10 y (it-a it) theme-text-main)
                (txt-right 220 y (it-b it) (rise-color (pct-of it)))
                (pct-box 310 (- y 1) it)
                (txt 10 (+ y 20) (string-append (it-d it) " " (q-change it)) theme-text-muted)
                (txt-right 310 (+ y 20) (string-append "高" (short-price (q-high it)) " 低" (short-price (q-low it)))
                           theme-text-muted)
                (gui-line 10 (+ y 41) 310 (+ y 41) theme-divider)
                (loop (cdr xs) (+ y 44) (+ i 1))))))))

;; 3. Index intraday charts ------------------------------------------------------------

(define (stocks-render-trends items)
  (let loop ((trs (items-all items "trend")) (y (body-top)) (i 0))
    (if (and (pair? trs) (< i 3))
        (let* ((tr (car trs)) (iq (items-where items "idx" 4 (it-c tr))))
          (txt 10 y (if iq (it-a iq) (it-c tr)) theme-accent)
          (if iq
              (begin
                (txt-right 236 y (it-b iq) (rise-color (pct-of iq)))
                (txt-right 310 y (pct-text iq) (rise-color (pct-of iq)))))
          (trend-chart 10 (+ y 22) 300 108 tr)
          (loop (cdr trs) (+ y 138) (+ i 1))))))

;; 4. 30-day trends -----------------------------------------------------------------------

(define (kline-card x y it)
  (let* ((pts (it-ints it 2)) (pct (it-fixed it 4 1)) (r (series-range pts 20)))
    (gui-round-rect x y 146 132 6 theme-card-border #f)
    (txt-fit (+ x 8) (+ y 5) 130 (it-a it) theme-text-main)
    (txt (+ x 8) (+ y 26) (it-c it) theme-text-sub)
    (txt-right (+ x 138) (+ y 26) (string-append (it-d it) "%") (rise-color pct))
    (line-chart (+ x 6) (+ y 50) 134 76 pts (car r) (cdr r) (rise-color pct))))

(define (stocks-render-kline items)
  (let ((ks (items-all items "k")))
    (if (null? ks)
        (txt 14 70 "暂无走势数据" theme-text-muted)
        (let loop ((xs ks) (i 0))
          (if (and (pair? xs) (< i 6))
              (begin
                (kline-card (+ 10 (* (remainder i 2) 154)) (+ (body-top) (* (quotient i 2) 138)) (car xs))
                (loop (cdr xs) (+ i 1))))))))

;; Pages -----------------------------------------------------------------------------------------

(app-define! "股票行情"
  (list (app-page "首页" (stocks-url "home") STOCKS-INTERVAL stocks-render-home)
        (app-page "自选股" (stocks-url "list") STOCKS-INTERVAL stocks-render-list)
        (app-page "指数分时" (stocks-url "trend") STOCKS-INTERVAL stocks-render-trends)
        (app-page "30日走势" (stocks-url "kline") STOCKS-KLINE-INTERVAL stocks-render-kline)))

(set! app-subtitle-proc
      (lambda (items) (let ((m (items-find items "meta"))) (if m (it-a m) #f))))
