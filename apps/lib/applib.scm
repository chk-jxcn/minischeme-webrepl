;;; =========================================================================
;;; App framework shared by the proxy apps (weather, news, stocks, usage).
;;; Loaded after gui.scm and before the app (tools/build_apps.py).
;;;
;;; An app declares its pages and the framework does the rest:
;;;
;;;   (app-define! "天气预报"
;;;     (list (app-page "首页" url-proc interval-ms render-proc) ...))
;;;
;;;   url-proc     () -> the URL of the page's data, built once at the start;
;;;                pages with the same URL share one document
;;;   interval-ms  how often the board fetches it while the page is shown
;;;   render-proc  (items) -> draws the body between header and footer
;;;
;;; Data: the app proxy (minischeme-proxy) answers {"items":[{t a..e}]}.
;;; Each document is copied into vectors #(t a b c d e) and kept per URL, so a
;;; page switch shows the last data at once while its new fetch runs.
;;; Screen: header (title, page n/N except on the home page, clock), body,
;;; footer (update time, fetch state or the last error).
;;; Button: short press = next page; long press = the hardware pages (memory,
;;; storage, network, system), where a short press turns the page and a long
;;; press goes back; touch = next.
;;; Carousel (the app's ini): carousel = 1 turns the pages by themselves,
;;; carousel_seconds = 10 per page, or one value per page ("15,10,10", the
;;; last one repeats); a faint bar left of the page number counts down.
;;; =========================================================================

;; 1. Fonts, layout, text -------------------------------------------------------

(define F-TEXT 2)               ; CJK text: a 16 px face from the system font ROM
(define F-BIG FONT-CLOCK-32)    ; digits " %-./0123456789:AMP" only

;; Font slot 2: the default font chosen for the system text (font 0, set by
;; config.ini [fonts] font_override system_16:<name>) when it is 16 px like
;; the layouts, else msyh / simsun 16 from the font ROM. The built-in font 0
;; has too few CJK characters for headlines, so it is never used here.
(define (app-init-fonts!)
  (let ((sys (font-info 0)))   ; (name height glyphs source bytes), #f when built in
    (or (and (pair? sys) (= (cadr sys) 16) (use-font 2 (car sys)))
        (use-font 2 "msyh" 16 'system)
        (use-font 2 "simsun" 16 'system))))

;; The default font changed (WebREPL font manager): load slot 2 again
(define (app-refresh-fonts!)
  (font-unload 2)
  (app-init-fonts!)
  (gui-invalidate 0 0 (gui-width) (gui-height)))

(define HDR-H 32)
(define FTR-H 24)
(define LINE-H 20)
(define (body-top) (+ HDR-H 6))
(define (body-bottom) (- (gui-height) FTR-H 4))
(define (scr-w) (gui-width))

(define (txt x y s c) (gui-text-styled x y s c F-TEXT))
(define (txt-w s) (gui-text-width s F-TEXT))
(define (txt-right xr y s c) (txt (- xr (txt-w s)) y s c))
(define (txt-center cx y s c) (txt (- cx (quotient (txt-w s) 2)) y s c))
(define (txt-fit x y w s c) (gui-text-fit x y w s c F-TEXT))  ; one line; too long: marquee or "…" (config.ini [text])
(define (txt-wrap x y w h s c) (gui-text-area x y w h s c F-TEXT LINE-H))  ; too tall: wrap_marquee or "…"

(define (big x y s c) (gui-text-styled x y s c F-BIG))
(define (big-w s) (gui-text-width s F-BIG))
(define (big-right xr y s c) (big (- xr (big-w s)) y s c))

;; Big number followed by a small unit ("26" "°C")
(define (big-unit x y num unit c)
  (big x y num c)
  (txt (+ x (big-w num) 2) (+ y 2) unit c))

;; Section label with a thin rule after it
(define (section y label)
  (txt 10 y label theme-accent)
  (gui-line (+ 18 (txt-w label)) (+ y 9) (- (scr-w) 10) (+ y 9) theme-divider))

;; Section label, rule, and a note at the right end
(define (section-note y label note)
  (let ((nw (txt-w note)))
    (txt 10 y label theme-accent)
    (gui-line (+ 18 (txt-w label)) (+ y 9) (- (scr-w) 18 nw) (+ y 9) theme-divider)
    (txt-right (- (scr-w) 10) y note theme-text-muted)))

;; 2. Strings and numbers ---------------------------------------------------------

(define (str-split s ch)                 ; "a,b,,c" -> ("a" "b" "" "c")
  (let ((n (string-length s)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond ((= i n) (reverse (cons (substring s start n) acc)))
            ((char=? (string-ref s i) ch) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
            (else (loop (+ i 1) start acc))))))

(define (str-part s ch k)                ; k-th field, "" when missing
  (let ((parts (str-split s ch)))
    (if (< k (length parts)) (list-ref parts k) "")))

(define (str-empty? s) (or (not s) (= (string-length s) 0)))

(define (str-starts? s prefix)
  (and (>= (string-length s) (string-length prefix))
       (string=? (substring s 0 (string-length prefix)) prefix)))

(define (str-contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (if (> m n)
        #f
        (let loop ((i 0))
          (cond
            ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1))))))))

;; Percent-encodes a query value byte by byte (strings are UTF-8 bytes)
(define (url-encode s)
  (let ((hex "0123456789ABCDEF") (n (string-length s)))
    (let loop ((i 0) (acc '()))
      (if (= i n)
          (list->string (reverse acc))
          (let* ((c (string-ref s i)) (b (char->integer c)))
            (if (or (and (>= b 48) (<= b 57)) (and (>= b 65) (<= b 90)) (and (>= b 97) (<= b 122))
                    (memv b '(44 45 46 95 126)))
                (loop (+ i 1) (cons c acc))
                (loop (+ i 1) (cons (string-ref hex (remainder b 16))
                                    (cons (string-ref hex (quotient b 16)) (cons #\% acc))))))))))

(define (int->str n) (number->string n))

(define (pad2 n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

;; Fixed point to text: (fixed->str 1234 2) -> "12.34", (fixed->str -5 1) -> "-0.5"
(define (fixed->str v digits)
  (if (not v)
      "--"
      (let* ((neg (< v 0)) (a (abs v)) (scale (expt 10 digits))
             (frac (number->string (remainder a scale)))
             (frac (string-append (make-string-of #\0 (- digits (string-length frac))) frac)))
        (string-append (if neg "-" "") (number->string (quotient a scale))
                       (if (> digits 0) (string-append "." frac) "")))))

(define (make-string-of ch n)
  (let loop ((i 0) (acc '())) (if (>= i n) (list->string acc) (loop (+ i 1) (cons ch acc)))))

(define (clamp v lo hi) (if (< v lo) lo (if (> v hi) hi v)))

(define (list-min l) (fold-left min (car l) l))
(define (list-max l) (fold-left max (car l) l))
(define (list-sum l) (fold-left + 0 l))

(define (take l n) (if (or (null? l) (<= n 0)) '() (cons (car l) (take (cdr l) (- n 1)))))

;; Chinese market colors: red rises, green falls
(define (rise-color v)
  (cond ((not v) theme-text-muted) ((> v 0) theme-danger) ((< v 0) theme-success) (else theme-text-sub)))

;; 3. Proxy items ------------------------------------------------------------------

(define (it-t it) (vector-ref it 0))                    ; a symbol: 'now, 'day ...
(define (it-f it k) (or (vector-ref it k) ""))          ; k 1..5 = a..e
(define (it-a it) (it-f it 1))
(define (it-b it) (it-f it 2))
(define (it-c it) (it-f it 3))
(define (it-d it) (it-f it 4))
(define (it-e it) (it-f it 5))
(define (it-ints it k) (let ((v (vector-ref it k))) (if v (string->ints v) '())))
(define (it-fixed it k digits) (let ((v (vector-ref it k))) (if v (string->fixed v digits) #f)))
(define (it-int it k) (it-fixed it k 0))

;; A field the app named with app-keys! ("topic"), "" when the item lacks it
(define (it-key it name)
  (let loop ((ks APP-KEYS) (k 0))
    (cond ((null? ks) "")
          ((string=? (car ks) name) (if (< k (vector-length it)) (it-f it k) ""))
          (else (loop (cdr ks) (+ k 1))))))

;; type: the "t" text ("day"); items hold it as a symbol
(define (items-find items type)
  (if (not (pair? items))
      #f
      (let ((sym (string->symbol type)))
        (let loop ((xs items))
          (cond ((not (pair? xs)) #f)
                ((eq? (it-t (car xs)) sym) (car xs))
                (else (loop (cdr xs))))))))

(define (items-all items type)
  (if (not (pair? items))
      '()
      (let ((sym (string->symbol type)))
        (filter (lambda (it) (eq? (it-t it) sym)) items))))

(define (items-where items type k value)   ; first of a type whose field k is value
  (if (not (pair? items))
      #f
      (let ((sym (string->symbol type)))
        (let loop ((xs items))
          (cond ((not (pair? xs)) #f)
                ((and (eq? (it-t (car xs)) sym) (equal? (vector-ref (car xs) k) value)) (car xs))
                (else (loop (cdr xs))))))))

;; 4. Charts ---------------------------------------------------------------------------

;; Polyline of a list of integers in [lo, hi]
(define (line-chart x y w h vals lo hi color)
  (if (>= (length vals) 2)
      (gui-chart x y w h (list->vector vals) 0 (length vals) lo hi color)))

;; Vertical bars of a list of integers in [0, hi]; returns the bar pitch
(define (bar-chart x y w h vals hi color)
  (let* ((n (max 1 (length vals))) (pitch (quotient w n)) (bw (max 1 (- pitch 2))))
    (let loop ((v vals) (i 0))
      (if (pair? v)
          (let ((bh (if (> hi 0) (quotient (* (clamp (car v) 0 hi) h) hi) 0)))
            (if (> bh 0) (gui-rect (+ x (* i pitch) 1) (- (+ y h) bh) bw bh color #t))
            (loop (cdr v) (+ i 1)))))
    pitch))

;; Range of a series with a little head room; never empty
(define (series-range vals min-span)
  (if (null? vals)
      (cons 0 min-span)
      (let* ((lo (list-min vals)) (hi (list-max vals)) (span (max min-span (- hi lo)))
             (pad (max 1 (quotient span 8))))
        (cons (- lo pad) (+ lo span pad)))))

(define (progress-bar x y w h pct color)
  (gui-round-rect x y w h 3 theme-dark-gray #t)
  (let ((fw (quotient (* (clamp pct 0 100) w) 100)))
    (if (> fw 0) (gui-round-rect x y (max fw 6) h 3 color #t))))

;; 5. State -------------------------------------------------------------------------------

(define APP-BASE-KEYS '("t" "a" "b" "c" "d" "e"))
(define APP-KEYS APP-BASE-KEYS)              ; read per item: (app-keys! name ...) adds more
(define APP-SELECTORS '((0 prefix "")))      ; every object with a "t"
(define APP-POOL 0)                          ; value text per document: no limit (memory bounds it)
(define APP-VALUE-LEN 0)                     ; bytes per value: no limit
(define APP-CACHE-MAX 3)                     ; documents kept for quick page switches
(define CAROUSEL-BAR-H 4)                    ; countdown bar in the header
(define CAROUSEL-BAR-COLOR 46552)            ; #xB5D8 (#b2b9c2): 3/4 of the way from the header to the text

(define app-carousel #f)                     ; seconds per page (a list) while turning, else #f
(define app-carousel-left 0)                 ; seconds left on this page
(define app-carousel-paused #f)              ; (app-carousel-pause): the page stays until resumed

(define app-title "APP")
(define app-subtitle-proc #f)                ; (items) -> text after the title on page 1
(define app-header-proc #f)                  ; (items x w): draws page 1's title in [x, x + w) itself
(define app-page-title-only #f)              ; #t: pages after the first are titled by their name alone
(define app-tick-proc #f)                    ; (tick) -> called every second
(define app-render-empty-pages '())          ; pages drawn before their data comes (with no items)
(define app-data-proc #f)                    ; (items) -> called when a new document arrives
(define app-views '())                       ; (name . (lambda (items i) ...)): views a combined app can show
(define app-index-always #f)                 ; #t: the page number also on page 1 (a combined app)
(define app-footer-text "")                  ; the footer of a local page (no proxy data)
(define app-long-press #f)                   ; () -> the app's long press, if it has one
(define app-schedule #f)                     ; (at) -> a time of the app's schedule.ini came while it runs
(define app-hold-proc #f)                    ; () -> #t: the carousel waits on this page (the app's own cycle
                                             ; runs); once it says #f again the carousel goes on at once
(define app-show-proc #f)                    ; () -> a page of the app came on screen (app-goto!)
(define app-step-proc #f)                    ; () -> every main-loop pass; #t: it used the feed stream itself
                                             ; (a sync), the framework's step waits
(define app-pages (vector))
(define app-urls (vector))
(define app-page-index 0)
(define app-time "--:--")
(define app-sec "--")                        ; the device clock's seconds, weekday and date (月日)
(define app-week "")
(define app-date "")
(define app-utc-sec 0)                       ; second of the UTC day (the tick once the clock is synced)
(define app-lunar "")                       ; the device's lunar month and day (八月十九), "" unsynced
(define app-cache '())                       ; #(url items time second) per fetched URL
(define app-error #f)                        ; message of the last error object
(define app-error-url "")                    ; the page URL whose document carried it
(define app-last-seq 0)
(define app-feed-url "")
(define app-loading #f)                      ; fetch requested, no document yet

;; More fields per item beyond t, a..e, by name: (app-keys! "topic" "text") before
;; app-define!; read them with (it-key it "topic")
(define (app-keys! . names) (set! APP-KEYS (append APP-BASE-KEYS names)))

(define (app-page name url-proc interval render) (vector name url-proc interval render))
;; A view of the app's data a combined app (apps/lib/combo.scm) may show as
;; one of its pages: "news[0]" calls (proc items 0) on the page it belongs to
(define (app-view! name page proc) (set! app-views (cons (list name page proc) app-views)))
;; A page drawn from the app's own data (memos, messages): no fetch, render gets '()
(define (app-local-page name render) (vector name (lambda () "") 0 render))
(define (app-local? i) (string=? (vector-ref app-urls i) ""))
(define (app-npages) (vector-length app-pages))
(define (app-cur) (vector-ref app-pages app-page-index))

(define (app-config key default)
  (let ((v (config-get key)))
    (if (and (string? v) (> (string-length v) 0)) v default)))

;; config.ini [server] proxy_url / [app] proxy = http://<host>:8087 (minischeme-proxy); "" when unset
(define (app-proxy)
  (let* ((p (app-config "proxy_url" (app-config "proxy" ""))) (n (string-length p)))
    (if (and (> n 0) (char=? (string-ref p (- n 1)) #\/)) (substring p 0 (- n 1)) p)))

(define (app-url path) (string-append (app-proxy) path))

(define (app-cache-entry url)
  (let loop ((c app-cache))
    (cond ((null? c) #f)
          ((equal? (vector-ref (car c) 0) url) (car c))
          (else (loop (cdr c))))))

;; Keep all page documents in memory so page switches are instantaneous
(define (app-cache-max) (max APP-CACHE-MAX (app-npages)))

;; Newest first; past (app-cache-max) documents the oldest one goes, never the
;; home page's (the page shown most)
(define (app-cache-put! url items)
  (let ((c (cons (vector url items app-time app-utc-sec)
                 (filter (lambda (e) (not (equal? (vector-ref e 0) url))) app-cache))))
    (set! app-cache
          (if (<= (length c) (app-cache-max))
              c
              (let ((home (vector-ref app-urls 0)))
                (reverse (let drop ((r (reverse c)))
                           (cond ((null? r) r)
                                 ((equal? (vector-ref (car r) 0) home) (cons (car r) (drop (cdr r))))
                                 (else (cdr r))))))))))

;; Page i's data is younger than the page's interval: shown again without
;; fetching (a page turn or the carousel does not fetch it every time)
(define (app-fresh? i)
  (let ((e (app-cache-entry (vector-ref app-urls i))))
    (and e (< (* 1000 (modulo (- app-utc-sec (vector-ref e 3)) 86400))
              (vector-ref (vector-ref app-pages i) 2)))))

;; The one stream follows the page on screen once its data is due
(define (app-follow-page!)
  (if (and (not (equal? (vector-ref app-urls app-page-index) app-feed-url))
           (not (app-local? app-page-index))
           (not (app-fresh? app-page-index)))
      (app-start-feed!)))

(define (app-items)
  (let ((e (app-cache-entry (vector-ref app-urls app-page-index))))
    (if e (vector-ref e 1) #f)))

;; (json-feed-status) builds a new list on each call: a caller that needs
;; several fields reads it once and passes it as st
(define (app-status key . st)
  (let ((e (assq key (if (pair? st) (car st) (json-feed-status))))) (if e (cdr e) #f)))

;; 6. Feed --------------------------------------------------------------------------------

(define APP-NO-PROXY "未设置代理：在设置页或 config.ini [app] proxy 填写 http://电脑IP:8087")

(define (app-start-feed!)
  (set! app-feed-url (vector-ref app-urls app-page-index))
  (cond
    ((string=? app-feed-url "")     ; a local page: nothing to fetch
     (set! app-loading #f))
    ((string=? (app-proxy) "")
     (set! app-loading #f)          ; nothing to fetch from: say where to set it
     (set! app-error APP-NO-PROXY))
    (else
        (if (eq? app-error APP-NO-PROXY) (set! app-error #f))   ; set since (a snapshot made without one)
        (set! app-loading #t)
        (json-feed-start app-feed-url (vector-ref (app-cur) 2) APP-KEYS APP-SELECTORS
                         APP-POOL APP-VALUE-LEN 2))))

;; #(type a b c d e ...): the type as a symbol, a slot per key of APP-KEYS,
;; empty values as #f (heap is scarce)
(define (app-read-item i)
  (let* ((n (length APP-KEYS)) (v (make-vector n #f)))
    (let loop ((k 1))
      (if (< k n)
          (let ((s (json-feed-field i k)))
            (if (and s (> (string-length s) 0)) (vector-set! v k s))
            (loop (+ k 1)))))
    (let ((t (json-feed-field i 0)))
      (vector-set! v 0 (if t (string->symbol t) 'none)))
    v))

;; Pre-fetches the next uncached page in the background right after boot
(define (app-prefetch-next!)
  (let loop ((i 0))
    (if (< i (app-npages))
        (let ((url (vector-ref app-urls i)))
          (cond
            ((or (string=? url "") (app-cache-entry url))
             (loop (+ i 1)))
            (else
             (set! app-feed-url url)
             (set! app-loading #t)
             (json-feed-start url (vector-ref (vector-ref app-pages i) 2) APP-KEYS APP-SELECTORS
                              APP-POOL APP-VALUE-LEN 2)
             #t)))
        #f)))

;; A new document: copy it, or keep the old data when the proxy sent an error
(define (app-take-document!)
  (let ((items (let loop ((i (- (json-feed-count) 1)) (acc '()))
                 (if (< i 0) acc (loop (- i 1) (cons (app-read-item i) acc))))))
    (set! app-loading #f)
    (if (and (pair? items) (eq? (it-t (car items)) 'error))
        (begin (set! app-error (it-a (car items))) (set! app-error-url (json-feed-url)))
        (if (app-page-url? (json-feed-url))
            (begin
              (set! app-error #f)
              (app-cache-put! (json-feed-url) items)
              (if app-data-proc (app-data-proc items)))
            (app-watch-deliver! (json-feed-url) items)))
    (if (not (and (pair? items) (eq? (it-t (car items)) 'error)))
        (begin
          ;; every page cached: the firmware's one stream goes back to the
          ;; page on screen when its data is due (app-tick checks again)
          (if (not (app-prefetch-next!)) (app-follow-page!))))
    (if (app-page-url? (json-feed-url)) (app-invalidate-all))))   ; a watched feed's: its alert draws itself

;; 7. Drawing --------------------------------------------------------------------------------

(define (app-invalidate-all) (gui-invalidate 0 0 (scr-w) (gui-height)))
(define (app-invalidate-body) (gui-invalidate 0 HDR-H (scr-w) (- (gui-height) HDR-H)))

;; The text after the title: the home page's subtitle (a city), else the page
;; name. Drawn in another color, not after a separator: the system fonts
;; may lack "·".
(define (app-header-sub items)
  (if (= app-page-index 0)
      (if (and app-subtitle-proc items) (app-subtitle-proc items) #f)
      (vector-ref (app-cur) 0)))

(define (app-demo-data? items)
  (and (pair? items)
       (or (items-find items "demo")
           (let ((loc (items-find items "loc")))
             (and loc (or (string=? (it-b loc) "MiniScheme-Proxy")
                          (string=? (it-b loc) "和风天气(回退)")
                          (str-contains? (it-b loc) "演示")))))))

(define (app-header-title items)
  (let ((t-it (if (pair? items) (items-find items "title") #f)))
    (cond
      ((and t-it (not (str-empty? (it-a t-it))))
       (it-a t-it))
      ((app-demo-data? items)
       (if (str-contains? app-title "【演示数据】")
           app-title
           (string-append app-title "【演示数据】")))
      (else app-title))))

;; 2 px per second, 1 px for pages shown longer than 30 s (at most 90 px)
(define (carousel-px secs) (if (> secs 30) 1 2))
(define (carousel-bar-w secs) (min 90 (* secs (carousel-px secs))))

;; The countdown, right-aligned at xr: a faint track and what is left of it
(define (app-render-countdown xr)
  (let* ((secs (app-page-seconds app-page-index))
         (full (carousel-bar-w secs))
         (left (min full (* (max 0 app-carousel-left) (carousel-px secs))))
         (y (quotient (- HDR-H CAROUSEL-BAR-H) 2)))
    (gui-rect (- xr full) y full CAROUSEL-BAR-H (if app-carousel-paused theme-divider theme-dark-gray) #t)
    (if (and (> left 0) (not app-carousel-paused))  ; paused: one even bar, no countdown
        (gui-rect (- xr left) y left CAROUSEL-BAR-H CAROUSEL-BAR-COLOR #t))))

(define (app-render-header items)
  (let* ((w (scr-w))
         (tw (txt-w app-time))
         (ind (if (or app-index-always (> app-page-index 0))
                  (string-append (int->str (+ app-page-index 1)) "/" (int->str (app-npages)))
                  #f))
         (iw (if ind (+ (txt-w ind) 12) 0))
         (badge (- w 8 tw 8 iw))
         ;; the carousel's countdown sits left of the page number (of the clock on page 1)
         (bar-r (- badge (if ind 6 0)))
         (right (if (pair? app-carousel) (- bar-r (carousel-bar-w (app-page-seconds app-page-index)) 6) badge)))
    (gui-rect 0 0 w HDR-H theme-card-hdr #t)
    (if (pair? app-carousel) (app-render-countdown bar-r))
    (txt-right (- w 8) 8 app-time theme-text-main)
    (if ind
        (begin
          (gui-round-rect badge 5 iw 22 6 theme-accent-dark #t)
          (txt (+ badge 6) 8 ind theme-accent)))
    (if (and app-header-proc (= app-page-index 0))
        (app-header-proc items 8 (- right 14))
        (let* ((named (and app-page-title-only (> app-page-index 0)))
               (title (if named (vector-ref (app-cur) 0) (app-header-title items)))
               (sub (if named #f (app-header-sub items)))
               (title-w (txt-w title)))
          (txt-fit 8 8 (- right 14) title theme-text-main)
          (if (and (not (str-empty? sub)) (< (+ 8 title-w 10) (- right 20)))
              (txt-fit (+ 8 title-w 10) 8 (- right 14 title-w 10) sub theme-accent))))))

(define (app-render-local-footer)
  (let ((y (- (gui-height) FTR-H)))
    (gui-rect 0 y (scr-w) FTR-H theme-card-hdr #t)
    (txt-fit 8 (+ y 3) (- (scr-w) 16) app-footer-text theme-text-muted)))

(define (app-render-footer)
  (if (app-local? app-page-index) (app-render-local-footer) (app-render-feed-footer)))

;; What the footer shows now, as one string: app-tick redraws the footer only
;; when it changed (a redraw also makes the screen be recorded again, which
;; every scrolling title would pay for)
(define app-footer-shown #f)
(define (app-footer-key)
  (cond
    ((app-alert-current) (string-append "alert|" (app-al-id (app-alert-current))))
    ((app-local? app-page-index)
     app-footer-text)
    (else
      (let ((parts (app-feed-footer-parts)))
        (string-append (vector-ref parts 0) "|" (vector-ref parts 1) (if (vector-ref parts 2) "!" ""))))))

;; "http://host:port" shown as "host:port"
(define (app-server-name s)
  (cond ((not (string? s)) "服务器")
        ((str-starts? s "http://") (substring s 7 (string-length s)))
        ((str-starts? s "tcp://") (substring s 6 (string-length s)))
        (else s)))

(define (app-render-feed-footer)
  (let* ((y (- (gui-height) FTR-H))
         (w (scr-w))
         (parts (app-feed-footer-parts))
         (text (vector-ref parts 0))
         (right (vector-ref parts 1)))
    (gui-rect 0 y w FTR-H theme-card-hdr #t)
    (txt-right (- w 8) (+ y 3) right theme-text-muted)
    (txt-fit 8 (+ y 3) (- w 24 (txt-w right)) text (if (vector-ref parts 2) theme-warning theme-text-muted))))

;; #(text right failed?) of the shown page's feed footer
(define (app-feed-footer-parts)
  (let* ((url (vector-ref app-urls app-page-index))
         (entry (app-cache-entry url))
         (upd (and entry (items-find (vector-ref entry 1) "upd")))  ; the server's data time
         ;; the time the server gives for its data ({"t": "upd"}), else when
         ;; this device fetched it (unknown before the clock was set)
         (last (cond ((and upd (it-a upd)) (string-append "更新于 " (it-a upd)))
                     ((not entry) #f)
                     ((string=? (vector-ref entry 2) "--:--") "已更新")
                     (else (string-append "更新于 " (vector-ref entry 2)))))
         ;; this page's fetch only: a prefetch of another page failing says nothing about it
         (mine (equal? (json-feed-url) url))
         (fs (json-feed-status))
         (state (if mine (app-status 'state fs) 'ok))
         (page-error (and app-error (or (eq? app-error APP-NO-PROXY) (equal? app-error-url url)) app-error))
         ;; what the fetch waits for now (firmware 1.0.57+): it replaces an old error
         (step (app-status 'step fs))
         (busy (memq step '(clock register wifi)))
         (failed (and (not busy) (or page-error (eq? state 'error))))
         (text (cond ((eq? step 'register)
                      (string-append "正在向 " (app-server-name (app-status 'step-server fs)) " 注册加密通道..."))
                     ((eq? step 'clock) "等待网络对时...")
                     ((eq? step 'wifi) "等待 WiFi 连接...")      ; firmware 1.0.61+
                     (page-error (string-append "代理: " page-error))
                     ((eq? state 'error) (string-append "连接失败: " (app-status 'error fs)))
                     ((and app-loading mine) (if last (string-append last "，刷新中...") "加载中..."))
                     (last last)
                     (else "等待数据")))
         (ms (app-status 'fetch-ms fs))
         (right (if (and mine (eq? state 'ok) (number? ms) (> ms 0))
                    (string-append (fixed->str (quotient (+ (app-status 'bytes fs) 51) 102) 1) "KB "
                                   (int->str ms) "ms")
                    "")))
    (vector text right failed)))

(define (app-render-waiting)
  (let ((cx (quotient (scr-w) 2)) (y (- (quotient (gui-height) 2) 60)))
    (txt-center cx y "正在获取数据..." theme-text-sub)
    ;; the address without its query: a token there would show on the screen and mirror
    (gui-text-wrap 16 (+ y 34) (- (scr-w) 32) 60 (car (str-split app-feed-url #\?)) theme-text-muted F-TEXT LINE-H)
    (if (or app-error (eq? (app-status 'state) 'error))
        (txt-wrap 16 (+ y 100) (- (scr-w) 32) 80
                  "请在设备网页的常用设置里填写应用代理地址（minischeme-proxy 或公网服务器），并确认能连上"
                  theme-warning))))

(define (app-render)
  (gui-clear theme-bg)
  (app-render-page)
  (gui-flush))

(define (app-render-page)
  (let ((a (app-alert-current)))
    (if a (app-alert-render a) (app-render-pages))))

(define (app-render-pages)
  (let ((items (if (app-local? app-page-index) '() (app-items))))   ; a local page: no document
    (if (gui-visible? 0 HDR-H) (app-render-header items))
    (if (gui-visible? HDR-H (- (gui-height) HDR-H FTR-H))
        (cond ((app-local? app-page-index) ((vector-ref (app-cur) 3) '()))
              (items ((vector-ref (app-cur) 3) items))
            ((memv app-page-index app-render-empty-pages) ((vector-ref (app-cur) 3) '()))
            (else (app-render-waiting)))))
  (if (gui-visible? (- (gui-height) FTR-H) FTR-H) (app-render-footer)))

;; 8. Firmware hooks ---------------------------------------------------------------------------

(define gui-render-proc app-render)

;; carousel = 1 in the app's ini (or config.ini [app]): seconds per page
(define (app-carousel-config)
  (if (member (app-config "carousel" "1") '("1" "on" "yes" "true"))
      (let ((secs (map (lambda (n) (clamp n 3 3600)) (string->ints (app-config "carousel_seconds" "10")))))
        (if (null? secs) '(10) secs))
      #f))

(define (app-page-seconds i)
  (cond
    ((or (not (pair? app-carousel)) (null? app-carousel)) 10)
    ((< i (length app-carousel)) (list-ref app-carousel i))
    (else (list-ref app-carousel (- (length app-carousel) 1)))))

(define (app-carousel-reset!)
  (if (pair? app-carousel) (set! app-carousel-left (app-page-seconds app-page-index))))

(define (app-define! title pages)
  (set! app-title title)
  (set! app-pages (list->vector pages))
  (set! app-urls (list->vector (map (lambda (p) ((vector-ref p 1))) pages)))
  (set! app-page-index 0)
  (set! app-carousel (if (> (length pages) 1) (app-carousel-config) #f))
  (app-carousel-reset!)
  (app-init-fonts!)
  (app-start-feed!)
  (app-alert-wrap-buttons!)
  (app-invalidate-all))

(define (app-goto! i)
  (set! app-page-index i)
  (set! app-carousel-held #f)
  (app-carousel-reset!)
  (if app-show-proc (app-show-proc))
  (app-follow-page!)                 ; its data still fresh: shown from the cache
  (app-invalidate-all))

(define (app-next-page!) (app-goto! (remainder (+ app-page-index 1) (app-npages))))

;; Page i fetches from url from now on (the URL procedures run once, at
;; app-define!); the page shown fetches it at once
(define (app-set-url! i url)
  (if (not (equal? (vector-ref app-urls i) url))
      (begin
        (vector-set! app-urls i url)
        (if (= i app-page-index) (app-start-feed!)))))

;; From the REPL (WebREPL quick commands "暂停翻页" / "恢复翻页"): the carousel
;; stops on this page, or counts it from the start again. Short presses still
;; turn pages. => paused, running, or off (no carousel = 1 in the app's ini).
(define (app-carousel-state) (cond ((not app-carousel) 'off) (app-carousel-paused 'paused) (else 'running)))

(define (app-carousel-pause)
  (set! app-carousel-paused #t)
  (app-carousel-reset!)
  (gui-invalidate 0 0 (scr-w) HDR-H)
  (app-carousel-state))

(define (app-carousel-resume)
  (set! app-carousel-paused #f)
  (app-carousel-reset!)
  (gui-invalidate 0 0 (scr-w) HDR-H)
  (app-carousel-state))

;; One second of the carousel: the next page when this one's time is up. A page whose app
;; cycles through its own screens (app-hold-proc) keeps it waiting, and is left as soon as
;; its cycle went round.
(define app-carousel-held #f)
(define (app-carousel-tick!)
  (cond ((and app-hold-proc (app-hold-proc))
         (if (not app-carousel-held) (gui-invalidate 0 0 (scr-w) HDR-H))
         (set! app-carousel-held #t)
         (app-carousel-reset!))
        (app-carousel-held
         (set! app-carousel-held #f)
         (app-next-page!))
        (else
         (set! app-carousel-left (- app-carousel-left 1))
         (if (<= app-carousel-left 0)
             (app-next-page!)
             (gui-invalidate 0 0 (scr-w) HDR-H)))))

(define (app-step)
  (if (not (and app-step-proc (app-step-proc)))
      (let ((seq (json-feed-seq)))
        (if (and (> seq 0) (not (= seq app-last-seq)))
            (begin
              (set! app-last-seq seq)
              (app-take-document!))))))

(define (app-tick hm sec week date lux bl . rest)
  (let ((tick (if (pair? rest) (car rest) 0)))
    (set! app-sec sec)
    (set! app-utc-sec tick)
    (set! app-week week)
    (set! app-date date)
    (if (and (pair? rest) (pair? (cdr rest))) (set! app-lunar (cadr rest)))
    (if (not (equal? hm app-time))
        (begin
          (set! app-time hm)
          (gui-invalidate 0 0 (scr-w) HDR-H)))
    (if (= (remainder tick 2) 0)   ; the fetch's state, shown only when it changed
        (let ((key (app-footer-key)))
          (if (not (equal? key app-footer-shown))
              (begin
                (set! app-footer-shown key)
                (gui-invalidate 0 (- (gui-height) FTR-H) (scr-w) FTR-H)))))
    (app-alert-tick!)
    ;; also stops on the hardware pages and while an alert shows
    (if (and app-carousel (not (info-active?)) (not app-carousel-paused) (not (app-alert-current)))
        (app-carousel-tick!))
    (if (> (app-npages) 0) (app-follow-page!))   ; the shown page's cached data became due
    (app-watch-step!)                            ; else a watched feed that is due
    (if (theme-tick! tick) (app-invalidate-all))   ; the day / night scheme or a theme.css changed
    (if app-tick-proc (app-tick-proc tick))))

;; Short press: next page (the home page after the last; a carousel's
;; countdown starts again there). A long press opens the hardware pages
;; (apps/lib/infopages.scm, shared by every app); the carousel's countdown
;; starts again when they open and close.
(define (app-button) (app-next-page!))

(set! info-on-change (lambda (open?) (app-carousel-reset!)))

(define (app-touch x y) (app-button))

(define (app-resume)
  (app-init-fonts!)
  (app-start-feed!)
  (app-invalidate-all))

;; 9. Alerts (强提醒) ---------------------------------------------------------------------------
;; Something that needs the user now (a dose due, a new message) takes the screen over the
;; pages: (app-alert! key title render [opts]). The alert with the highest priority shows
;; (1..9, 9 the highest; equal ones in the order they came); a higher one raised meanwhile
;; goes in front, and the one it covered comes back after it with the seconds it had left.
;; While one shows the carousel stops, a short press confirms it (its ack runs, then it
;; closes) and a long press puts it off for a few minutes. How it ends: button (a short
;; press), time (after its seconds), both, or app (only the app's own (app-alert-done! key),
;; e.g. once every dose is taken; a short press still runs its ack). The user's settings
;; come first: a combined app's alerts setting for the member (combo.scm), then the app's
;; own alert (0: none of its alerts), alert_priority, alert_exit (button, time, both),
;; alert_seconds, alert_snooze (minutes); then the options the app passes; then 5 / both /
;; 30 s / 5 min. opts: an alist of (ack . thunk), (priority . n), (exit . symbol),
;; (seconds . n), (snooze . minutes), (full . #t) (render draws the whole screen, its own
;; title bar and hints: the medicine reminder). key: a string the app picks (one per message, per
;; dose time); raising it again updates the alert; an alert that ended is not raised again
;; under the same key until the app restarts.
;; (app-watch! url-proc interval-ms proc): a feed fetched in the background at its
;; interval while the page on screen does not need the stream (a combined app's member
;; that is not on screen still sees its new messages); proc gets its documents.

(define APP-ALERT-PRIORITY 5)
(define APP-ALERT-EXIT 'both)
(define APP-ALERT-SECONDS 30)
(define APP-ALERT-SNOOZE 5)
(define APP-ALERT-DONE-MAX 40)

;; #(id owner app title render ack priority exit seconds snooze seq left wake full)
(define app-alerts '())                      ; in queue order: priority, then arrival
(define app-alert-seq 0)
(define app-alert-clock 0)                   ; seconds since the start (snoozes wake on it)
(define app-alert-done-ids '())              ; alerts that ended: raising one again does nothing
(define app-alert-user-button #f)            ; the app's own presses (app-define! wraps them)
(define app-alert-user-long #f)

(define (app-al-id a) (vector-ref a 0))
(define (app-al-owner a) (vector-ref a 1))
(define (app-al-app a) (vector-ref a 2))
(define (app-al-title a) (vector-ref a 3))
(define (app-al-render a) (vector-ref a 4))
(define (app-al-ack a) (vector-ref a 5))
(define (app-al-priority a) (vector-ref a 6))
(define (app-al-exit a) (vector-ref a 7))
(define (app-al-seconds a) (vector-ref a 8))
(define (app-al-snooze a) (vector-ref a 9))
(define (app-al-seq a) (vector-ref a 10))
(define (app-al-left a) (vector-ref a 11))
(define (app-al-wake a) (vector-ref a 12))
(define (app-al-full a) (vector-ref a 13))

;; A combined app's hooks (combo.scm): which member raises an alert, running code as that
;; member, its name and its settings. Alone, the app itself.
(define (app-alert-owner) #f)
(define (app-alert-owner-id owner) "")
(define (app-alert-run owner thunk) (thunk))
(define (app-alert-app-name owner) app-title)
(define (app-alert-setting owner name) (app-config name #f))   ; runs inside app-alert-run

;; A callback the firmware calls later (fs-download's on-done): it runs as the code that made it
;; (in a combined app, as that member: its folder, its settings)
(define (app-callback proc)
  (let ((owner (app-alert-owner)))
    (lambda args (app-alert-run owner (lambda () (apply proc args))))))

(define (app-alert-opt opts key) (let ((p (assq key opts))) (and p (cdr p))))

;; One setting: the user's (as text), else the app's option, else the default
(define (app-alert-value owner opts key name default)
  (let* ((s (app-alert-run owner (lambda () (app-alert-setting owner name))))
         (v (and (string? s) (> (string-length s) 0) s))
         (given (app-alert-opt opts key)))
    (cond ((and v (eq? key 'exit) (not (eq? given 'app)))      ; app: the app ends it, always
           (let ((sym (string->symbol v))) (if (memq sym '(button time both)) sym (or given default))))
          ((and v (not (eq? key 'exit)) (string->number v)) (string->number v))
          (else (or given default)))))

(define (app-alert-find id)
  (let loop ((l app-alerts))
    (cond ((null? l) #f) ((string=? (app-al-id (car l)) id) (car l)) (else (loop (cdr l))))))

;; The queue with a in its place: a higher priority first, then the one that came first
(define (app-alert-insert a l)
  (cond ((null? l) (list a))
        ((> (app-al-priority a) (app-al-priority (car l))) (cons a l))
        (else (cons (car l) (app-alert-insert a (cdr l))))))

;; The alert on screen: the first one not put off, or #f
(define (app-alert-current)
  (let loop ((l app-alerts))
    (cond ((null? l) #f) ((app-al-wake (car l)) (loop (cdr l))) (else (car l)))))

(define (app-alert-waiting) (length (filter (lambda (a) (not (app-al-wake a))) app-alerts)))

(define (app-alert-changed!)
  (if (not (app-alert-current)) (app-carousel-reset!))   ; the pages again: a full count
  (app-invalidate-all))

(define (app-alert-key-id owner key) (string-append (app-alert-owner-id owner) "/" key))

(define (app-alert! key title render . rest)
  (let* ((opts (if (pair? rest) (car rest) '()))
         (owner (app-alert-owner))
         (id (app-alert-key-id owner key))
         (old (app-alert-find id)))
    (cond
      ((member id app-alert-done-ids) #f)
      ((equal? (app-alert-run owner (lambda () (app-alert-setting owner "alert"))) "0") #f)
      (old (vector-set! old 3 title)
           (vector-set! old 4 render)
           (vector-set! old 5 (app-alert-opt opts 'ack))
           (if (eq? old (app-alert-current)) (app-invalidate-all))
           #t)
      (else
        (let* ((secs (clamp (app-alert-value owner opts 'seconds "alert_seconds" APP-ALERT-SECONDS) 3 3600))
               (a (vector id owner (app-alert-app-name owner) title render (app-alert-opt opts 'ack)
                          (clamp (app-alert-value owner opts 'priority "alert_priority" APP-ALERT-PRIORITY) 1 9)
                          (app-alert-value owner opts 'exit "alert_exit" APP-ALERT-EXIT)
                          secs
                          (clamp (app-alert-value owner opts 'snooze "alert_snooze" APP-ALERT-SNOOZE) 1 120)
                          app-alert-seq secs #f (and (app-alert-opt opts 'full) #t))))
          (set! app-alert-seq (+ app-alert-seq 1))
          (set! app-alerts (app-alert-insert a app-alerts))
          (app-alert-changed!)
          #t)))))

;; The alert leaves the queue for good (its ack first when confirmed)
(define (app-alert-end! a)
  (set! app-alerts (filter (lambda (x) (not (eq? x a))) app-alerts))
  (set! app-alert-done-ids (cons (app-al-id a) app-alert-done-ids))
  (if (> (length app-alert-done-ids) APP-ALERT-DONE-MAX)
      (set! app-alert-done-ids (take app-alert-done-ids APP-ALERT-DONE-MAX)))
  (app-alert-changed!))

;; The app ends its alert (every dose taken, the message read elsewhere)
(define (app-alert-done! key)
  (let ((a (app-alert-find (app-alert-key-id (app-alert-owner) key))))
    (if a (app-alert-end! a))
    (and a #t)))

(define (app-alert-active? key) (and (app-alert-find (app-alert-key-id (app-alert-owner) key)) #t))

;; Short press on an alert: its ack; it closes unless only time ends it, or the app does
(define (app-alert-press! a)
  (let ((ack (app-al-ack a)) (exit (app-al-exit a)))
    (if (not (eq? exit 'time))
        (begin
          (if ack (app-alert-run (app-al-owner a) ack))
          (if (and (not (eq? exit 'app)) (app-alert-find (app-al-id a))) (app-alert-end! a))
          (app-invalidate-all)))))

;; Long press: put off for its snooze minutes; it comes back with its full seconds
(define (app-alert-snooze! a)
  (vector-set! a 12 (+ app-alert-clock (* 60 (app-al-snooze a))))
  (app-alert-changed!))

;; Every second: alerts put off come back; the one on screen counts down when time ends it
(define (app-alert-tick!)
  (set! app-alert-clock (+ app-alert-clock 1))
  (for-each (lambda (a)
              (if (and (app-al-wake a) (>= app-alert-clock (app-al-wake a)))
                  (begin (vector-set! a 12 #f) (vector-set! a 11 (app-al-seconds a)) (app-alert-changed!))))
            app-alerts)
  (let ((a (app-alert-current)))
    (if (and a (memq (app-al-exit a) '(time both)))
        (begin
          (vector-set! a 11 (- (app-al-left a) 1))
          (if (<= (app-al-left a) 0)
              (app-alert-end! a)
              (begin (gui-invalidate 0 0 (scr-w) HDR-H)
                     (gui-invalidate 0 (- (gui-height) FTR-H) (scr-w) FTR-H)))))))

;; The presses go to the alert on screen, else to the app (app-define! wraps them once)
(define (app-alert-wrap-buttons!)
  (if (not app-alert-user-button)
      (begin
        (set! app-alert-user-button app-button)
        (set! app-alert-user-long app-long-press)
        (set! app-button
              (lambda () (let ((a (app-alert-current))) (if a (app-alert-press! a) (app-alert-user-button)))))
        (set! app-long-press
              (lambda ()
                (let ((a (app-alert-current)))
                  (cond (a (app-alert-snooze! a))
                        (app-alert-user-long (app-alert-user-long)))))))))

;; Screen: a title bar in the priority's color with the app's name and the alert's title,
;; the alerts waiting and the countdown; the alert's own body; a footer saying what the
;; presses do
(define (app-alert-color a)
  (let ((p (app-al-priority a))) (cond ((>= p 8) theme-danger) ((>= p 5) theme-warning) (else theme-accent))))

(define (app-alert-render-header a)
  (let* ((w (scr-w)) (tw (txt-w app-time))
         (n (app-alert-waiting))
         (ind (if (> n 1) (string-append "提醒 1/" (int->str n)) #f))
         (iw (if ind (+ (txt-w ind) 12) 0))
         (badge (- w 8 tw 8 iw))
         (timed (memq (app-al-exit a) '(time both)))
         (secs (app-al-seconds a))
         (bar-r (- badge (if ind 6 0)))
         (right (if timed (- bar-r (carousel-bar-w secs) 6) badge))
         (name (app-al-app a)) (nw (txt-w name)))
    (gui-rect 0 0 w HDR-H (app-alert-color a) #t)
    (if timed
        (let* ((full (carousel-bar-w secs)) (left (min full (* (max 0 (app-al-left a)) (carousel-px secs))))
               (y (quotient (- HDR-H CAROUSEL-BAR-H) 2)))
          (gui-rect (- bar-r full) y full CAROUSEL-BAR-H theme-card-hdr #t)
          (if (> left 0) (gui-rect (- bar-r left) y left CAROUSEL-BAR-H theme-bg #t))))
    (txt-right (- w 8) 8 app-time theme-bg)
    (if ind
        (begin (gui-round-rect badge 5 iw 22 6 theme-bg #t)
               (txt (+ badge 6) 8 ind (app-alert-color a))))
    (txt-fit 8 8 (- right 14) name theme-bg)
    (if (< (+ 8 nw 10) (- right 20))
        (txt-fit (+ 8 nw 10) 8 (- right 14 nw 10) (app-al-title a) theme-bg))))

(define (app-alert-hint a)
  (let ((exit (app-al-exit a)) (secs (int->str (max 0 (app-al-left a)))))
    (cond ((eq? exit 'time) (string-append secs " 秒后关闭  长按稍后提醒"))
          ((eq? exit 'both) (string-append "短按确认  " secs " 秒后关闭  长按稍后"))
          (else (string-append "短按确认  长按 " (int->str (app-al-snooze a)) " 分钟后再提醒")))))

(define (app-alert-render-footer a)
  (let ((y (- (gui-height) FTR-H)))
    (gui-rect 0 y (scr-w) FTR-H theme-card-hdr #t)
    (txt-fit 8 (+ y 3) (- (scr-w) 16) (app-alert-hint a) theme-text-sub)))

(define (app-alert-render a)
  (if (app-al-full a)
      (app-alert-run (app-al-owner a) (lambda () ((app-al-render a))))
      (app-alert-render-framed a)))

(define (app-alert-render-framed a)
  (if (gui-visible? 0 HDR-H) (app-alert-render-header a))
  (if (gui-visible? HDR-H (- (gui-height) HDR-H FTR-H))
      (app-alert-run (app-al-owner a) (lambda () ((app-al-render a)))))
  (if (gui-visible? (- (gui-height) FTR-H) FTR-H) (app-alert-render-footer a)))

;; Watched feeds: #(url-proc interval owner proc due), due on app-alert-clock
(define app-watches '())

(define (app-watch! url-proc interval proc)
  (set! app-watches (append app-watches (list (vector url-proc interval (app-alert-owner) proc 0)))))

(define (app-watch-url w) (app-alert-run (vector-ref w 2) (vector-ref w 0)))

(define (app-page-url? url)
  (let loop ((i 0))
    (cond ((>= i (vector-length app-urls)) #f)
          ((equal? (vector-ref app-urls i) url) #t)
          (else (loop (+ i 1))))))

;; A document of a watched feed no page shows: to its proc, as its app's code
(define (app-watch-deliver! url items)
  (for-each (lambda (w)
              (if (equal? (app-watch-url w) url)
                  (begin
                    (vector-set! w 4 (+ app-alert-clock (quotient (vector-ref w 1) 1000)))
                    (app-alert-run (vector-ref w 2) (lambda () ((vector-ref w 3) items))))))
            app-watches))

;; Every second: a due watched feed takes the stream while no fetch is in flight; the page on
;; screen takes it back right after when its data is due (app-take-document!, app-follow-page!),
;; also when its fetch keeps failing
(define (app-watch-step!)
  (if (and (pair? app-watches) (not app-loading) (> (app-npages) 0) (not (string=? (app-proxy) "")))
      (let loop ((l app-watches))
        (if (pair? l)
            (let* ((w (car l)) (url (app-watch-url w)))
              (if (and (>= app-alert-clock (vector-ref w 4)) (not (string=? url ""))
                       (not (equal? url (vector-ref app-urls app-page-index))))
                  (begin
                    (vector-set! w 4 (+ app-alert-clock (quotient (vector-ref w 1) 1000)))
                    (set! app-feed-url url)
                    (set! app-loading #t)
                    (json-feed-start url (vector-ref w 1) APP-KEYS APP-SELECTORS APP-POOL APP-VALUE-LEN 2))
                  (loop (cdr l))))))))
