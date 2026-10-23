;;; =========================================================================
;;; Weather (天气预报), 320x480 portrait, on the app framework (applib.scm).
;;; Data: the app proxy's /app/weather: QWeather (和风天气) with a key and the
;;; account's API host, else Open-Meteo; the location is the public IP's city
;;; unless the app's ini sets one. One document serves every page.
;;;   1 home: now, 3 days, rain in the next 5 hours
;;;   2 7 days   3 24 hours   4 rain by the minute + air quality   5 indices
;;; =========================================================================

;; 1. Settings (apps/weather.ini, defaults in apps/weather/meta.ini) -----------

(define (weather-url)
  (let ((token (let ((t (app-config "qweather_token" "")))
                 (if (string=? t "") (app-config "qweather_key" "") t))))
    (app-url (string-append "/app/weather?loc=" (url-encode (app-config "location" "auto"))
                            "&token=" (url-encode token)
                            "&host=" (url-encode (app-config "qweather_host" ""))))))

(define (weather-update-interval-ms)
  (let* ((raw (app-config "update_interval" "120"))
         (num (if (number? raw) raw (string->number (if (string? raw) raw "120"))))
         (mins (max 30 (if (and num (> num 0)) num 120))))
    (* mins 60 1000)))

(define WEATHER-INTERVAL (weather-update-interval-ms))

(define (weather-normalize-time s)
  (let* ((trimmed (let loop ((i 0) (j (string-length s)))
                    (cond
                      ((>= i j) "")
                      ((char=? (string-ref s i) #\space) (loop (+ i 1) j))
                      ((char=? (string-ref s (- j 1)) #\space) (loop i (- j 1)))
                      (else (substring s i j)))))
         (parts (str-split trimmed #\:)))
    (if (= (length parts) 2)
        (let ((h (string->number (car parts)))
              (m (string->number (cadr parts))))
          (if (and h m (>= h 0) (<= h 23) (>= m 0) (<= m 59))
              (string-append (pad2 h) ":" (pad2 m))
              #f))
        #f)))

(define (weather-parse-refresh-times)
  (let* ((raw (app-config "refresh_times" ""))
         (raw-list (if (string? raw) (str-split raw #\,) '())))
    (let loop ((rest raw-list) (acc '()) (count 0))
      (if (or (null? rest) (>= count 4))
          (reverse acc)
          (let ((norm (weather-normalize-time (car rest))))
            (if norm
                (loop (cdr rest) (cons norm acc) (+ count 1))
                (loop (cdr rest) acc count)))))))

(define weather-last-refresh-hm "")
(define weather-refresh-times (weather-parse-refresh-times))

;; 2. Icons ------------------------------------------------------------------------

(define (fr r k) (quotient (* r k) 10))  ; k tenths of r

(define sun-rays '((10 0) (7 7) (0 10) (-7 7) (-10 0) (-7 -7) (0 -10) (7 -7)))
;; The icons' own colors (a theme.css may set them): the day scheme's
;; warning color is a dark amber for text, too dull for a sun
(theme-defaults! "night" '(("sun_icon_fg" . "warning_fg") ("thunder_icon_fg" . "warning_fg") ("snow_icon_fg" . "#ffffff")))
(theme-defaults! "day" '(("sun_icon_fg" . "#f29a12") ("thunder_icon_fg" . "#e08a00") ("snow_icon_fg" . "#6f9fc4")))

;; A sun with eight rays. Big: eight short lines (nine display-list
;; commands, the home page's one icon). Small (the 3-day and 7-day pages):
;; four lines through the centre, a background disc that parts them from the
;; sun, then the sun: six commands, so a week of suns fits the list.
;; rays? #f (the small sun behind a cloud): a disc in a ring, two commands.
(define (icon-sun cx cy r . rays?)
  (cond
    ((>= r 24)
     (gui-circle cx cy (fr r 6) (theme-color "sun_icon_fg") #t)
     (for-each (lambda (d)
                 (gui-line (+ cx (fr (fr r 8) (car d))) (+ cy (fr (fr r 8) (cadr d)))
                           (+ cx (fr (fr r 10) (car d))) (+ cy (fr (fr r 10) (cadr d))) (theme-color "sun_icon_fg")))
               sun-rays))
    ((and (pair? rays?) (not (car rays?)))
     (gui-circle cx cy (fr r 6) (theme-color "sun_icon_fg") #t)
     (gui-circle cx cy (fr r 9) (theme-color "sun_icon_fg") #f))
    (else
     (let ((o (fr r 10)) (d (fr r 7)))
       (gui-line (- cx o) cy (+ cx o) cy (theme-color "sun_icon_fg"))
       (gui-line cx (- cy o) cx (+ cy o) (theme-color "sun_icon_fg"))
       (gui-line (- cx d) (- cy d) (+ cx d) (+ cy d) (theme-color "sun_icon_fg"))
       (gui-line (- cx d) (+ cy d) (+ cx d) (- cy d) (theme-color "sun_icon_fg"))
       (gui-circle cx cy (fr r 8) theme-bg #t)
       (gui-circle cx cy (fr r 6) (theme-color "sun_icon_fg") #t)))))

(define (icon-cloud cx cy r color)
  (gui-circle (- cx (fr r 5)) (+ cy (fr r 1)) (fr r 5) color #t)
  (gui-circle (+ cx (fr r 1)) (- cy (fr r 2)) (fr r 6) color #t)
  (gui-circle (+ cx (fr r 6)) (+ cy (fr r 2)) (fr r 4) color #t)
  (gui-round-rect (- cx (fr r 9)) (+ cy (fr r 1)) (fr r 19) (fr r 5) (fr r 2) color #t))

(define (icon-drops cx cy r color n)
  (let loop ((i 0))
    (if (< i n)
        (let ((x (+ (- cx (fr r 5)) (* i (fr r 5)))))
          (gui-line x (+ cy (fr r 7)) (- x (fr r 2)) (+ cy (fr r 11)) color)
          (if (>= r 20) (gui-line (+ x 1) (+ cy (fr r 7)) (- (+ x 1) (fr r 2)) (+ cy (fr r 11)) color))
          (loop (+ i 1))))))

(define (icon-flakes cx cy r n)
  (let loop ((i 0))
    (if (< i n)
        (begin
          (gui-circle (+ (- cx (fr r 5)) (* i (fr r 5))) (+ cy (fr r 9)) (max 1 (fr r 1)) (theme-color "snow_icon_fg") #t)
          (loop (+ i 1))))))

(define (weather-icon kind cx cy r)
  (cond
    ((equal? kind "sun") (icon-sun cx cy r))
    ((equal? kind "partly")
     (icon-sun (- cx (fr r 4)) (- cy (fr r 4)) (fr r 7) #f)
     (icon-cloud (+ cx (fr r 2)) (+ cy (fr r 2)) (fr r 8) theme-text-sub))
    ((equal? kind "overcast")
     (icon-cloud (+ cx (fr r 2)) (- cy (fr r 2)) (fr r 8) theme-card-border)
     (icon-cloud (- cx (fr r 1)) (+ cy (fr r 1)) (fr r 9) theme-text-muted))
    ((equal? kind "rain")
     (icon-cloud cx (- cy (fr r 3)) r theme-text-muted)
     (icon-drops cx (- cy (fr r 3)) r theme-accent 3))
    ((equal? kind "storm")
     (icon-cloud cx (- cy (fr r 3)) r theme-card-border)
     (gui-line (+ cx (fr r 1)) (+ cy (fr r 3)) (- cx (fr r 2)) (+ cy (fr r 7)) (theme-color "thunder_icon_fg"))
     (gui-line (- cx (fr r 2)) (+ cy (fr r 7)) (+ cx (fr r 2)) (+ cy (fr r 7)) (theme-color "thunder_icon_fg"))
     (gui-line (+ cx (fr r 2)) (+ cy (fr r 7)) (- cx (fr r 1)) (+ cy (fr r 11)) (theme-color "thunder_icon_fg"))
     (if (>= r 20) (icon-drops (+ cx (fr r 5)) (- cy (fr r 3)) (fr r 7) theme-accent 1)))
    ((equal? kind "snow")
     (icon-cloud cx (- cy (fr r 3)) r theme-text-sub)
     (icon-flakes cx (- cy (fr r 3)) r 3))
    ((equal? kind "sleet")
     (icon-cloud cx (- cy (fr r 3)) r theme-text-sub)
     (icon-drops (- cx (fr r 2)) (- cy (fr r 3)) r theme-accent 1)
     (icon-flakes (+ cx (fr r 3)) (- cy (fr r 3)) r 2))
    ((equal? kind "fog")
     (let loop ((i 0))
       (if (< i 4)
           (begin
             (gui-round-rect (- cx (fr r (if (odd-i? i) 7 9))) (+ (- cy (fr r 6)) (* i (fr r 4)))
                             (fr r (if (odd-i? i) 14 18)) (max 2 (fr r 2)) 2 theme-text-muted #t)
             (loop (+ i 1))))))
    (else (icon-cloud cx cy (fr r 9) theme-text-sub))))

(define (odd-i? i) (= (remainder i 2) 1))

;; 3. Helpers --------------------------------------------------------------------

(define (aqi-color aqi)
  (cond ((not aqi) theme-text-muted)
        ((<= aqi 50) theme-success)
        ((<= aqi 100) theme-warning)
        ((<= aqi 150) col-orange)
        (else theme-danger)))

(define (deg s) (string-append s "°"))

;; "10/11 明天" -> ("10/11" "明天")
(define (day-date it) (str-part (it-a it) #\space 0))
(define (day-name it) (str-part (it-a it) #\space 1))
(define (day-max it) (str-part (it-d it) #\, 0))
(define (day-min it) (str-part (it-d it) #\, 1))
;; Day "e": "rain probability %,rain in 0.1 mm,humidity %" (QWeather has no
;; probability by day, Open-Meteo no humidity)
(define (day-rain-text it)
  (let ((pop (str-part (it-e it) #\, 0)) (hum (str-part (it-e it) #\, 2)))
    (cond ((not (str-empty? pop)) (string-append "降水 " pop "%"))
          ((not (str-empty? hum)) (string-append "湿度 " hum "%"))
          (else ""))))

(define (hour-label h) (string-append (int->str (remainder h 24)) "时"))

(define (weather-start-hour items)
  (let ((h (items-find items "hours"))) (if h (or (it-int h 4) 0) 0)))

(define (no-data y text) (txt 14 y text theme-text-muted))

;; 4. Page 1: home -------------------------------------------------------------------

(define (weather-render-now items)
  (let ((now (items-find items "now")) (now2 (items-find items "now2")) (air (items-find items "air")))
    (if now
        (begin
          (weather-icon (it-c now) 56 86 36)
          (big-unit 106 46 (it-a now) "°C" theme-text-main)
          (txt 108 88 (it-b now) theme-text-main)
          (if now2 (txt 108 110 (string-append (it-a now2) " " (it-b now2)) theme-text-sub))
          (txt 220 48 (string-append "体感 " (deg (it-d now))) theme-text-sub)
          (txt 220 70 (string-append "湿度 " (it-e now) "%") theme-text-sub)))
    (if air
        (let* ((aqi (it-int air 1)) (label (string-append "AQI " (it-a air) " " (it-b air)))
               (w (+ (txt-w label) 12)))
          (gui-round-rect 218 92 w 24 6 (aqi-color aqi) #f)
          (txt 224 96 label (aqi-color aqi))))
    (let ((warn (items-find items "warn")))
      (if warn
          (begin
            (gui-round-rect 10 128 300 24 6 theme-danger #f)
            (txt-fit 18 132 284 (it-a warn) theme-danger))))))

(define (weather-render-3days items y)
  (section y "三日预报")
  (let loop ((days (take (items-all items "day") 3)) (i 0))
    (if (pair? days)
        (let* ((d (car days)) (x (+ 10 (* i 102))) (cx (+ x 49)) (top (+ y 24)))
          (gui-round-rect x top 96 124 6 theme-card-border #f)
          (txt-center cx (+ top 6) (day-name d) (if (= i 0) theme-accent theme-text-main))
          (weather-icon (it-c d) cx (+ top 46) 17)
          (txt-center cx (+ top 70) (it-b d) theme-text-sub)
          (txt-center cx (+ top 92) (string-append (deg (day-max d)) " / " (deg (day-min d))) theme-text-main)
          (loop (cdr days) (+ i 1))))))

(define (weather-render-rain5 items y)
  (let ((r (items-find items "rain5h")) (h0 (weather-start-hour items)))
    (section y "未来5小时降水")
    (if (not r)
        (no-data (+ y 30) "暂无数据")
        (let* ((mm (it-ints r 1)) (pop (it-ints r 2)) (top (+ y 26)) (ch 70))
          (let loop ((i 0) (m mm) (p pop))
            (if (and (< i 5) (pair? m))
                (let* ((x (+ 10 (* i 61))) (pv (if (pair? p) (car p) 0))
                       (bh (quotient (* (clamp pv 0 100) ch) 100)))
                  (gui-rect (+ x 8) top 44 ch theme-dark-gray #t)
                  (if (> bh 0) (gui-rect (+ x 8) (- (+ top ch) bh) 44 bh theme-accent-dark #t))
                  (txt-center (+ x 30) (+ top 6) (string-append (int->str pv) "%") theme-text-main)
                  (txt-center (+ x 30) (+ top 40) (if (> (car m) 0) (fixed->str (car m) 1) "0")
                              (if (> (car m) 0) theme-accent theme-text-muted))
                  (txt-center (+ x 30) (+ top ch 4) (hour-label (+ h0 i)) theme-text-sub)
                  (loop (+ i 1) (cdr m) (if (pair? p) (cdr p) '())))))
          (txt 10 (+ top ch 28) (it-c r) (if (> (list-sum mm) 0) theme-accent theme-success))
          (txt-right 310 (+ top ch 28) "概率% / 毫米" theme-text-muted)))))

(define (weather-render-home items)
  (weather-render-now items)
  (weather-render-3days items 158)
  (weather-render-rain5 items 314))

;; 5. Page 2: 7 days ---------------------------------------------------------------------

(define (weather-render-week items)
  (let* ((days (items-all items "day"))
         (maxs (map (lambda (d) (or (string->fixed (day-max d) 0) 0)) days))
         (mins (map (lambda (d) (or (string->fixed (day-min d) 0) 0)) days))
         (lo (if (pair? mins) (list-min mins) 0))
         (hi (if (pair? maxs) (list-max maxs) 1))
         (span (max 1 (- hi lo))))
    (let loop ((ds days) (i 0) (mx maxs) (mn mins))
      (if (and (pair? ds) (< i 7))
          (let* ((d (car ds)) (y (+ 40 (* i 59))) (bx 214) (bw 56)
                 (x0 (+ bx (quotient (* (- (car mn) lo) bw) span)))
                 (x1 (+ bx (quotient (* (- (car mx) lo) bw) span))))
            (txt 10 (+ y 8) (day-name d) (if (= i 0) theme-accent theme-text-main))
            (txt 10 (+ y 30) (day-date d) theme-text-muted)
            (weather-icon (it-c d) 76 (+ y 26) 15)
            (txt-fit 100 (+ y 8) 76 (it-b d) theme-text-main)
            (txt 100 (+ y 30) (day-rain-text d) theme-text-muted)
            (txt-right 208 (+ y 18) (deg (day-min d)) theme-text-sub)
            (gui-round-rect bx (+ y 24) bw 6 3 theme-dark-gray #t)
            (gui-round-rect x0 (+ y 24) (max 6 (- x1 x0)) 6 3 theme-warning #t)
            (txt (+ bx bw 6) (+ y 18) (deg (day-max d)) theme-text-main)
            (loop (cdr ds) (+ i 1) (cdr mx) (cdr mn)))))))

;; 6. Page 3: 24 hours --------------------------------------------------------------------

(define (weather-render-hours items)
  (let ((h (items-find items "hours")))
    (if (not h)
        (no-data 60 "暂无逐小时数据")
        (let* ((temps (it-ints h 1)) (pops (it-ints h 2)) (h0 (or (it-int h 4) 0))
               (n (length temps)) (cx 34) (cw 270) (cy 70) (chh 96)
               (lo (- (list-min temps) 1)) (hi (+ (list-max temps) 1)))
          (section 40 "气温")
          (gui-rect cx cy cw chh theme-card-hdr #t)
          (line-chart cx cy cw chh temps lo hi theme-warning)
          (txt-right (- cx 4) (- cy 2) (deg (int->str (list-max temps))) theme-text-sub)
          (txt-right (- cx 4) (+ cy chh -16) (deg (int->str (list-min temps))) theme-text-sub)
          ;; a value every 4 hours on the curve
          (let loop ((i 0) (t temps))
            (if (pair? t)
                (begin
                  (if (= (remainder i 4) 0)
                      (let ((x (+ cx (quotient (* i (- cw 1)) (max 1 (- n 1)))))
                            (y (+ cy (- chh 1) (- (quotient (* (- (car t) lo) (- chh 1)) (- hi lo))))))
                        (gui-circle x y 2 theme-warning #t)
                        (txt-center (clamp x 44 296) (+ cy chh 4) (hour-label (+ h0 i)) theme-text-muted)))
                  (loop (+ i 1) (cdr t)))))
          (section 196 "降水概率 %")
          (gui-rect cx 222 cw 70 theme-card-hdr #t)
          (bar-chart cx 222 cw 70 pops 100 theme-accent)
          (txt-right (- cx 4) 220 "100" theme-text-muted)
          (txt-right (- cx 4) 276 "0" theme-text-muted)
          ;; table: every 3 hours
          (section 304 "逐3小时")
          (let loop ((i 0))
            (if (< i 8)
                (let* ((k (* i 3)) (x (+ 10 (* (remainder i 4) 76))) (y (+ 330 (* (quotient i 4) 62))))
                  (if (< k n)
                      (begin
                        (gui-round-rect x y 70 56 6 theme-card-border #f)
                        (txt-center (+ x 35) (+ y 4) (hour-label (+ h0 k)) theme-text-muted)
                        (txt-center (+ x 35) (+ y 20) (deg (int->str (list-ref temps k))) theme-text-main)
                        (txt-center (+ x 35) (+ y 37)
                                    (string-append (int->str (if (< k (length pops)) (list-ref pops k) 0)) "%")
                                    theme-accent)))
                  (loop (+ i 1)))))))))

;; 7. Page 4: rain by the minute, air, conditions ------------------------------------------

(define (weather-render-rain items)
  (let ((r (items-find items "rain")) (air (items-find items "air"))
        (now2 (items-find items "now2")) (now (items-find items "now")))
    (section 40 "未来2小时降水")
    (if (not r)
        (no-data 66 "暂无分钟级降水数据")
        (let* ((vals (it-ints r 1)) (step (or (it-int r 3) 15)) (hi (max 10 (list-max (cons 0 vals)))))
          (gui-rect 10 66 300 70 theme-card-hdr #t)
          (bar-chart 10 66 300 70 vals hi theme-accent)
          (txt 10 140 (it-d r) theme-text-muted)
          (txt-right 310 140 (string-append "+" (int->str (* step (length vals))) "分钟") theme-text-muted)
          (txt-fit 10 162 300 (if (str-empty? (it-b r)) "-" (it-b r))
                   (if (> (list-sum vals) 0) theme-accent theme-success))))
    (section 194 "空气质量")
    (if (not air)
        (no-data 220 "暂无空气质量数据")
        (let ((aqi (it-int air 1)))
          (big 14 222 (it-a air) (aqi-color aqi))
          (txt (+ 20 (big-w (it-a air))) 226 (it-b air) (aqi-color aqi))
          (txt (+ 20 (big-w (it-a air))) 246 (it-e air) theme-text-muted)
          (progress-bar 14 266 292 8 (quotient (* (clamp (or aqi 0) 0 300) 100) 300) (aqi-color aqi))
          (txt 14 280 (string-append "PM2.5  " (it-c air)) theme-text-sub)
          (txt 160 280 (string-append "PM10  " (it-d air)) theme-text-sub)))
    (section 312 "实况")
    (let ((tiles (list (list "风" (if now2 (string-append (it-a now2) " " (it-b now2)) "--"))
                       (list "气压" (if now2 (string-append (it-c now2) " hPa") "--"))
                       (list "能见度" (if (and now2 (not (str-empty? (it-d now2)))) (string-append (it-d now2) " km") "--"))
                       (list "湿度 / 紫外线" (string-append (if now (it-e now) "--") "% / "
                                                       (if (and now2 (not (str-empty? (it-e now2)))) (it-e now2) "-"))))))
      (let loop ((t tiles) (i 0))
        (if (pair? t)
            (let ((x (+ 10 (* (remainder i 2) 154))) (y (+ 338 (* (quotient i 2) 56))))
              (gui-round-rect x y 146 50 6 theme-card-border #f)
              (txt (+ x 8) (+ y 5) (car (car t)) theme-text-muted)
              (txt-fit (+ x 8) (+ y 26) 132 (cadr (car t)) theme-text-main)
              (loop (cdr t) (+ i 1))))))))

;; 8. Page 5: indices and warnings ------------------------------------------------------------

(define (weather-render-index items)
  (let ((y (let loop ((ws (items-all items "warn")) (y 40))
             (if (pair? ws)
                 (begin
                   (gui-round-rect 10 y 300 26 6 theme-danger #f)
                   (txt-fit 18 (+ y 4) 284 (it-a (car ws)) theme-danger)
                   (loop (cdr ws) (+ y 32)))
                 y))))
    (let loop ((xs (items-all items "idx")) (y y))
      (if (and (pair? xs) (< (+ y 52) 420))
          (let ((it (car xs)))
            (gui-round-rect 10 y 300 52 6 theme-card-border #f)
            (txt 20 (+ y 6) (it-a it) theme-accent)
            (txt-right 300 (+ y 6) (it-b it) theme-text-main)
            (txt-fit 20 (+ y 28) 280 (if (str-empty? (it-c it)) "-" (it-c it)) theme-text-sub)
            (loop (cdr xs) (+ y 58)))))
    (let ((loc (items-find items "loc")))
      (if loc (txt-fit 10 (- (body-bottom) 18) 300 (string-append "数据源: " (it-b loc)) theme-text-muted)))))

;; 9. Pages & Scheduled Refresh -----------------------------------------------------------------

(set! app-subtitle-proc
      (lambda (items) (let ((loc (items-find items "loc"))) (if loc (it-a loc) #f))))

(set! app-tick-proc
      (lambda (tick)
        (if (and (pair? weather-refresh-times)
                 (string? app-time)
                 (not (string=? app-time ""))
                 (not (string=? app-time weather-last-refresh-hm)))
            (let ((cur-hm (if (> (string-length app-time) 5)
                              (substring app-time 0 5)
                              app-time)))
              (if (member cur-hm weather-refresh-times)
                  (begin
                    (set! weather-last-refresh-hm app-time)
                    ;; refetch now; the cached forecast stays on screen until the
                    ;; new one arrives (and when the request fails)
                    (app-start-feed!)
                    (app-invalidate-all)))))))

(app-define! "天气"
  (list (app-page "首页" weather-url WEATHER-INTERVAL weather-render-home)
        (app-page "七日预报" weather-url WEATHER-INTERVAL weather-render-week)
        (app-page "24小时" weather-url WEATHER-INTERVAL weather-render-hours)
        (app-page "降水与空气" weather-url WEATHER-INTERVAL weather-render-rain)
        (app-page "生活指数" weather-url WEATHER-INTERVAL weather-render-index)))

