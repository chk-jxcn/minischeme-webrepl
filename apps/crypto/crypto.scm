;;; =========================================================================
;;; Crypto (加密货币), 320x480 portrait, on the app framework (applib.scm).
;;; Data: the app proxy's /app/crypto (OKX, Huobi as a fallback), prices in
;;; USDT or CNY as text, 24 h changes as signed text ("+0.21"), the 24 h line
;;; (hourly closes) in basis points against the price 24 h ago, 7-day closes
;;; in per-mille against the first day. Red rises, green falls.
;;;   1 prices   2 one coin's 24 h line   3 7-day trends
;;; =========================================================================

(define CRYPTO-INTERVAL 20000)           ; the proxy caches 15 s
(define CRYPTO-KLINE-INTERVAL 600000)

(define (crypto-symbols) (app-config "symbols" "BTC,ETH,SOL,BNB,XRP,DOGE,ADA"))
(define (crypto-chart) (app-config "chart" "BTC"))
(define (crypto-fiat) (app-config "fiat" "usd"))

(define (crypto-url view)
  (lambda ()
    (app-url (string-append "/app/crypto?view=" view "&symbols=" (url-encode (crypto-symbols))
                            "&chart=" (url-encode (crypto-chart)) "&fiat=" (url-encode (crypto-fiat))))))

(define (crypto-pct it) (it-fixed it 3 2))       ; "+0.21" -> 21

(define (crypto-pct-box xr y text p)
  (let ((w (max 64 (+ (txt-w text) 12))))
    (gui-round-rect (- xr w) y w 22 4 (rise-color p) #t)
    (txt-center (- xr (quotient w 2)) (+ y 3) text theme-bg)))

;; "USDT" or "人民币" from the meta item
(define (crypto-unit items)
  (let ((m (items-find items "meta"))) (if m (it-a m) "USDT")))

;; 1. Prices --------------------------------------------------------------------------------

(define (crypto-render-list items)
  (let ((cs (items-all items "c")))
    (if (null? cs)
        (txt 14 70 "没有行情：在应用设置 symbols 中填写币种，如 BTC,ETH" theme-text-muted)
        (let loop ((xs cs) (y (+ (body-top) 4)) (i 0))
          (if (and (pair? xs) (< i 9))
              (let* ((it (car xs)) (p (crypto-pct it)))
                (txt 10 y (it-a it) theme-text-main)
                (txt-right 220 y (it-b it) (rise-color p))
                (crypto-pct-box 310 (- y 1) (string-append (it-c it) "%") p)
                (txt 10 (+ y 20) (string-append "额 " (it-e it)) theme-text-muted)
                (txt-right 310 (+ y 20) (string-append "高" (str-part (it-d it) #\, 0) " 低" (str-part (it-d it) #\, 1))
                           theme-text-muted)
                (gui-line 10 (+ y 41) 310 (+ y 41) theme-divider)
                (loop (cdr xs) (+ y 45) (+ i 1))))))))

;; 2. 24 h line ------------------------------------------------------------------------------

(define (crypto-render-trend items)
  (let ((tr (items-find items "trend")))
    (if (not tr)
        (txt 14 70 "没有这个币种的走势：检查应用设置 chart" theme-text-muted)
        (let* ((y (body-top)) (p (it-fixed tr 4 2)) (c (rise-color p))
               (pts (it-ints tr 1))
               (m (max 50 (list-max (map abs (if (pair? pts) pts '(0))))))
               (cy (+ y 104)) (h 270))
          (txt 10 (+ y 4) (string-append (it-b tr) " / " (crypto-unit items)) theme-accent)
          (crypto-pct-box 310 (+ y 2) (string-append (it-d tr) "%") p)
          (big 10 (+ y 30) (it-c tr) c)
          (txt 10 (+ y 74) (string-append "24小时 高 " (str-part (it-e tr) #\, 0) "  低 " (str-part (it-e tr) #\, 1))
               theme-text-sub)
          (txt-right 310 (+ y 74) (string-append "额 " (str-part (it-e tr) #\, 2)) theme-text-sub)
          (gui-rect 10 cy 300 h theme-card-hdr #t)
          (gui-line 10 (+ cy (quotient h 2)) 309 (+ cy (quotient h 2)) theme-divider)   ; the price 24 h ago
          (line-chart 10 cy 300 h pts (- 0 m) m c)
          (txt 12 cy (string-append "+" (fixed->str m 2) "%") theme-text-muted)
          (txt 12 (+ cy h -18) (string-append "-" (fixed->str m 2) "%") theme-text-muted)
          (txt-right 308 (+ cy h -18) "24 小时" theme-text-muted)))))

;; 3. 7-day trends ----------------------------------------------------------------------------

(define (crypto-kline-card x y it)
  (let* ((pts (it-ints it 2)) (pct (it-fixed it 4 1)) (r (series-range pts 20)))
    (gui-round-rect x y 146 132 6 theme-card-border #f)
    (txt (+ x 8) (+ y 5) (it-a it) theme-text-main)
    (txt (+ x 8) (+ y 26) (it-c it) theme-text-sub)
    (txt-right (+ x 138) (+ y 26) (string-append (it-d it) "%") (rise-color pct))
    (line-chart (+ x 6) (+ y 50) 134 76 pts (car r) (cdr r) (rise-color pct))))

(define (crypto-render-kline items)
  (let ((ks (items-all items "k")))
    (if (null? ks)
        (txt 14 70 "暂无走势数据" theme-text-muted)
        (let loop ((xs ks) (i 0))
          (if (and (pair? xs) (< i 6))
              (begin
                (crypto-kline-card (+ 10 (* (remainder i 2) 154)) (+ (body-top) (* (quotient i 2) 138)) (car xs))
                (loop (cdr xs) (+ i 1))))))))

;; Pages ---------------------------------------------------------------------------------------

(set! app-subtitle-proc (lambda (items) (crypto-unit items)))

(app-define! "加密货币"
  (list (app-page "行情" (crypto-url "list") CRYPTO-INTERVAL crypto-render-list)
        (app-page "24小时" (crypto-url "trend") CRYPTO-INTERVAL crypto-render-trend)
        (app-page "7日走势" (crypto-url "kline") CRYPTO-KLINE-INTERVAL crypto-render-kline)))
