;;; =========================================================================
;;; Futures (期货行情), 320x480 portrait, on the app framework (applib.scm).
;;; Data: the app proxy's /app/futures (Sina). Prices arrive as text, changes
;;; as signed text against the previous settlement ("+0.55"), the minute
;;; line in basis points against it, 30-day closes in per-mille against the
;;; first day. Red rises, green falls.
;;;   1 watch list   2 one contract's minute line   3 30-day trends
;;; Codes: main contracts are the product and 0 (RB0 螺纹钢, AU0 黄金, SC0
;;; 原油, IF0 沪深300), a month is the product and YYMM (RB2601).
;;; =========================================================================

(define FUT-INTERVAL 15000)               ; the proxy caches 10 s while trading
(define FUT-KLINE-INTERVAL 600000)

(define (fut-codes) (app-config "codes" "RB0,AU0,AG0,SC0,CU0,M0,IF0"))
(define (fut-chart) (app-config "chart" "AU0"))

(define (fut-url view)
  (lambda ()
    (app-url (string-append "/app/futures?view=" view "&codes=" (url-encode (fut-codes))
                            "&chart=" (url-encode (fut-chart))))))

;; "+0.55" -> 55 (hundredths), for colors
(define (fut-pct it) (it-fixed it 3 2))
(define (fut-pct-text it) (string-append (it-c it) "%"))

;; Quote "e": "change,high,low,previous settlement"
(define (fut-e it k) (str-part (it-e it) #\, k))

;; Change % in a filled box, right-aligned at xr
(define (fut-pct-box xr y it)
  (let* ((t (fut-pct-text it)) (w (max 64 (+ (txt-w t) 12))) (p (fut-pct it)))
    (gui-round-rect (- xr w) y w 22 4 (rise-color p) #t)
    (txt-center (- xr (quotient w 2)) (+ y 3) t theme-bg)))

;; 1. Watch list --------------------------------------------------------------------------

(define (fut-render-list items)
  (let ((qs (items-all items "q")))
    (if (null? qs)
        (txt 14 70 "没有行情：在应用设置 codes 中填写合约，如 RB0,AU0" theme-text-muted)
        (let loop ((xs qs) (y (+ (body-top) 4)) (i 0))
          (if (and (pair? xs) (< i 9))
              (let ((it (car xs)))
                (txt 10 y (it-a it) theme-text-main)
                (txt-right 220 y (it-b it) (rise-color (fut-pct it)))
                (fut-pct-box 310 (- y 1) it)
                (txt 10 (+ y 20) (string-append (it-d it) "  " (fut-e it 0)) theme-text-muted)
                (txt-right 310 (+ y 20) (string-append "高" (fut-e it 1) " 低" (fut-e it 2)) theme-text-muted)
                (gui-line 10 (+ y 41) 310 (+ y 41) theme-divider)
                (loop (cdr xs) (+ y 45) (+ i 1))))))))

;; 2. Minute line ----------------------------------------------------------------------------

(define (fut-render-trend items)
  (let ((q (items-find items "q")) (tr (items-find items "trend")) (cx (quotient (scr-w) 2)))
    (if (not q)
        (txt 14 70 "没有这个合约的行情：检查应用设置 chart" theme-text-muted)
        (let ((y (body-top)) (c (rise-color (fut-pct q))))
          (txt 10 (+ y 4) (string-append (it-a q) "  " (it-d q)) theme-accent)
          (fut-pct-box 310 (+ y 2) q)
          (big 10 (+ y 30) (it-b q) c)
          (txt-right 310 (+ y 38) (fut-e q 0) c)
          (txt 10 (+ y 74) (string-append "高 " (fut-e q 1) "   低 " (fut-e q 2)) theme-text-sub)
          (txt-right 310 (+ y 74) (string-append "昨结 " (fut-e q 3)) theme-text-sub)
          (if tr
              (let* ((pts (it-ints tr 1))
                     (m (max 30 (list-max (map abs (if (pair? pts) pts '(0))))))
                     (cy (+ y 104)) (h 270)
                     (last (if (pair? pts) (list-ref pts (- (length pts) 1)) 0)))
                (gui-rect 10 cy 300 h theme-card-hdr #t)
                (gui-line 10 (+ cy (quotient h 2)) 309 (+ cy (quotient h 2)) theme-divider)   ; previous settlement
                (line-chart 10 cy 300 h pts (- 0 m) m (rise-color last))
                (txt 12 cy (string-append "+" (fixed->str m 2) "%") theme-text-muted)
                (txt 12 (+ cy h -18) (string-append "-" (fixed->str m 2) "%") theme-text-muted)
                (txt-right 308 (+ cy h -18) (string-append (it-d tr) " 分钟") theme-text-muted))
              (txt 14 (+ y 120) "暂无分时数据（休市时显示上一交易日）" theme-text-muted))))))

;; 3. 30-day trends ---------------------------------------------------------------------------

(define (fut-kline-card x y it)
  (let* ((pts (it-ints it 2)) (pct (it-fixed it 4 1)) (r (series-range pts 20)))
    (gui-round-rect x y 146 132 6 theme-card-border #f)
    (txt-fit (+ x 8) (+ y 5) 130 (it-a it) theme-text-main)
    (txt (+ x 8) (+ y 26) (it-c it) theme-text-sub)
    (txt-right (+ x 138) (+ y 26) (string-append (it-d it) "%") (rise-color pct))
    (line-chart (+ x 6) (+ y 50) 134 76 pts (car r) (cdr r) (rise-color pct))))

(define (fut-render-kline items)
  (let ((ks (items-all items "k")))
    (if (null? ks)
        (txt 14 70 "暂无走势数据" theme-text-muted)
        (let loop ((xs ks) (i 0))
          (if (and (pair? xs) (< i 6))
              (begin
                (fut-kline-card (+ 10 (* (remainder i 2) 154)) (+ (body-top) (* (quotient i 2) 138)) (car xs))
                (loop (cdr xs) (+ i 1))))))))

;; Pages ---------------------------------------------------------------------------------------

(set! app-subtitle-proc
      (lambda (items) (let ((m (items-find items "meta"))) (if m (it-a m) #f))))

(app-define! "期货行情"
  (list (app-page "行情" (fut-url "list") FUT-INTERVAL fut-render-list)
        (app-page "分时" (fut-url "trend") FUT-INTERVAL fut-render-trend)
        (app-page "30日走势" (fut-url "kline") FUT-KLINE-INTERVAL fut-render-kline)))
