;;; =========================================================================
;;; MiniScheme Embedded GUI & CSS-like Layout Engine
;;; Tailored for ESP32 ILI9488 480x320 Screen & WASM WebREPL Simulator
;;; =========================================================================

;;; -------------------------------------------------------------------------
;;; 1. Standard RGB565 Palette & Modern Dark Theme Constants
;;; -------------------------------------------------------------------------

(define col-black         0)     ; #x0000
(define col-white         65535) ; #xFFFF
(define col-red           63488) ; #xF800
(define col-green         2016)  ; #x07E0
(define col-blue          31)    ; #x001F
(define col-cyan          2047)  ; #x07FF
(define col-magenta       63519) ; #xF81F
(define col-yellow        65504) ; #xFFE0
(define col-orange        64800) ; #xFD20
(define col-gray          33808) ; #x8410
(define col-dark-gray     12710) ; #x31A6
(define col-light-gray    50712) ; #xC618

;; IPS theme: dark slate canvas, outline-only surfaces, bright but not pure
;; white text, luminous accents; plus flat green segment colors for the
;; clock (plain instrument-panel LCD, no glow)
(define theme-bg           2179  ) ; #x0883: Canvas (#0b1118)
(define theme-card-bg      2179  ) ; #x0883: Surfaces are outlined, not filled (#0b1118)
(define theme-card-border  23442 ) ; #x5B92: Slate Outline (#5b7090)
(define theme-card-hdr     4358  ) ; #x1106: Header Strip (#152030)
(define theme-text-main    59262 ) ; #xE77E: Soft White (#e6ecf3)
(define theme-text-sub     48698 ) ; #xBE3A: Light Slate (#bac7d6)
(define theme-text-muted   42392 ) ; #xA598: Label Gray-Blue (#a2b2c6)
(define theme-accent       26270 ) ; #x669E: Sky Cyan (#62d0f0)
(define theme-accent-dark  4586  ) ; #x11EA: Deep Teal (#173f52)
(define theme-success      30386 ) ; #x76B2: Mint Green (#72d696)
(define theme-warning      62954 ) ; #xF5EA: Amber (#f0bc55)
(define theme-danger       60399 ) ; #xEBEF: Coral (#ee7c7c)
(define theme-purple       50462 ) ; #xC51E: Lavender (#c0a2f2)
(define theme-dark-gray    12809 ) ; #x3209: Inactive Element (#34414f)
(define theme-divider      27667 ) ; #x6C13: Divider lines (#688098): darker ones vanish on the panel
(define theme-seg-on       28271 ) ; #x6E6F: Flat LCD segment green (#6fcf7f)
(define theme-seg-off      4419  ) ; #x1143: Unlit segment ghost (#142a1c)

;;; -------------------------------------------------------------------------
;;; 1b. Color schemes: color aliases, a day and a night scheme
;;; -------------------------------------------------------------------------
;; Colors are named by alias: titlebar_bg, text_fg, card_border, bar_fg ...
;; The value of an alias, the first found wins:
;;   1. a color given to the call itself (a number, "#rrggbb", rgb(r, g, b))
;;   2. the app's theme.css (in its folder), the block of the scheme in use
;;   3. the system's /spiffs/theme.css (theme-css, API 1.8), the same block
;;   4. the app's own defaults (theme-defaults!)
;;   5. the built-in day or night scheme (THEME-DAY, THEME-NIGHT)
;; When none of them names the alias, the same steps for its category, the
;; part after the last "_" (titlebar_bg -> bg, text_sub_fg -> fg,
;; card_border -> border). A value is #rgb, #rrggbb, rgb(r, g, b) or
;; another alias, so names of your own work too:
;;   day   { my_orange: #f08c32; warning_fg: my_orange; }
;;   night { titlebar_bg: #152030; }
;;   *     { seg_on_fg: #6fcf7f; }        (every scheme)
;;   sakura { bg: #fff4f6; }              (a scheme of your own)
;; The mode (config.ini [theme], an app's own config.ini may override):
;;   theme        auto (default), day or night
;;   theme_switch light (default: light-lux at or over theme_light_day is
;;                day, at or under theme_light_night night), time
;;                (theme_day_start .. theme_night_start) or sun (sunrise to
;;                sunset at theme_lat / theme_lon; the time when unknown)
;;   theme_day / theme_night  the scheme each mode uses: day / night, or a
;;                block of theme.css of your own
;; The theme-* colors above are set from the aliases at the start and again
;; whenever the mode or a theme.css changes (theme-tick!, from the app loop).

(define THEME-NIGHT
  '(("bg" . "#0b1118") ("fg" . "#e6ecf3") ("border" . "#5b7090")
    ("card_bg" . "bg") ("card_border" . "#5b7090") ("titlebar_bg" . "#152030")
    ("text_fg" . "#e6ecf3") ("text_sub_fg" . "#bac7d6") ("text_muted_fg" . "#a2b2c6")
    ("accent_fg" . "#62d0f0") ("accent_bg" . "#173f52")
    ("success_fg" . "#72d696") ("warning_fg" . "#f0bc55") ("danger_fg" . "#ee7c7c") ("purple_fg" . "#c0a2f2")
    ("inactive_fg" . "#34414f") ("divider_border" . "#688098")
    ("seg_on_fg" . "#6fcf7f") ("seg_off_fg" . "#142a1c")
    ("bar_fg" . "accent_fg") ("bar_bg" . "titlebar_bg") ("icon_fg" . "accent_fg")))

(define THEME-DAY
  '(("bg" . "#ffffff") ("fg" . "#17202b") ("border" . "#8d9cae")
    ("card_bg" . "bg") ("card_border" . "#8d9cae") ("titlebar_bg" . "#d7e1ec")
    ("text_fg" . "#17202b") ("text_sub_fg" . "#33404f") ("text_muted_fg" . "#556377")
    ("accent_fg" . "#0a6f9c") ("accent_bg" . "#c2e0ee")
    ("success_fg" . "#1d7f45") ("warning_fg" . "#b8700a") ("danger_fg" . "#bf3434") ("purple_fg" . "#6c49b0")
    ("inactive_fg" . "#c4cdd8") ("divider_border" . "#a3b0bf")
    ("seg_on_fg" . "#000000") ("seg_off_fg" . "bg")      ; unlit segments not shown by day
    ("bar_fg" . "accent_fg") ("bar_bg" . "titlebar_bg") ("icon_fg" . "accent_fg")))

(define theme-mode "night")        ; "day" or "night"
(define theme-scheme "night")      ; the block of theme.css in use
(define theme-sys-text #f)         ; the files as last read, to notice a change
(define theme-app-text #f)
(define theme-sys-css '())         ; parsed: ((block (alias . value) ...) ...)
(define theme-app-css '())
(define theme-app-defaults '())    ; ((block (alias . value) ...) ...), theme-defaults!
(define theme-cache '())           ; (alias . rgb565) of the scheme in use
(define theme-ticks 0)
(define theme-utc-offset #f)       ; seconds east of UTC, learnt from the app loop

;; -- small text helpers (gui.scm comes before applib.scm) --

(define (theme-space? c) (let ((b (char->integer c))) (or (= b 32) (= b 9) (= b 10) (= b 13))))

(define (theme-trim s)
  (let* ((n (string-length s))
         (a (let loop ((i 0)) (if (and (< i n) (theme-space? (string-ref s i))) (loop (+ i 1)) i)))
         (b (let loop ((j n)) (if (and (> j a) (theme-space? (string-ref s (- j 1)))) (loop (- j 1)) j))))
    (substring s a b)))

(define (theme-split s ch)
  (let ((n (string-length s)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond ((= i n) (reverse (cons (substring s start n) acc)))
            ((char=? (string-ref s i) ch) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
            (else (loop (+ i 1) start acc))))))

(define (theme-index s ch)
  (let ((n (string-length s)))
    (let loop ((i 0)) (cond ((= i n) #f) ((char=? (string-ref s i) ch) i) (else (loop (+ i 1)))))))

(define (theme-last-index s ch)
  (let loop ((i (- (string-length s) 1))) (cond ((< i 0) #f) ((char=? (string-ref s i) ch) i) (else (loop (- i 1))))))

;; s without /* comments */
(define (theme-uncomment s)
  (let ((n (string-length s)))
    (let loop ((i 0) (acc '()) (in #f))
      (cond ((>= i n) (list->string (reverse acc)))
            ((and (not in) (< (+ i 1) n) (char=? (string-ref s i) #\/) (char=? (string-ref s (+ i 1)) #\*))
             (loop (+ i 2) acc #t))
            ((and in (< (+ i 1) n) (char=? (string-ref s i) #\*) (char=? (string-ref s (+ i 1)) #\/))
             (loop (+ i 2) acc #f))
            (in (loop (+ i 1) acc #t))
            (else (loop (+ i 1) (cons (string-ref s i) acc) #f))))))

;; "name, name { alias: value; ... }" blocks -> ((name (alias . value) ...) ...)
(define (theme-parse text)
  (if (not (string? text))
      '()
      (let loop ((chunks (theme-split (theme-uncomment text) #\})) (acc '()))
        (if (null? chunks)
            (reverse acc)
            (let* ((c (car chunks)) (open (theme-index c #\{)))
              (loop (cdr chunks)
                    (if (not open)
                        acc
                        (let ((pairs (theme-pairs (substring c (+ open 1) (string-length c)))))
                          (let add ((names (theme-split (substring c 0 open) #\,)) (acc acc))
                            (if (null? names)
                                acc
                                (let ((nm (theme-trim (car names))))
                                  (add (cdr names) (if (> (string-length nm) 0) (cons (cons nm pairs) acc) acc)))))))))))))

(define (theme-pairs body)
  (let loop ((parts (theme-split body #\;)) (acc '()))
    (if (null? parts)
        (reverse acc)
        (let ((colon (theme-index (car parts) #\:)))
          (loop (cdr parts)
                (if colon
                    (let ((k (theme-trim (substring (car parts) 0 colon)))
                          (v (theme-trim (substring (car parts) (+ colon 1) (string-length (car parts))))))
                      (if (and (> (string-length k) 0) (> (string-length v) 0)) (cons (cons k v) acc) acc))
                    acc))))))

;; The value of alias in the blocks named scheme (else "*"), the last one wins
(define (theme-block-get css scheme alias)
  (let loop ((l css) (own #f) (any #f))
    (if (null? l)
        (or own any)
        (let* ((b (car l)) (hit (and (or (string=? (car b) scheme) (string=? (car b) "*")) (assoc alias (cdr b)))))
          (cond ((not hit) (loop (cdr l) own any))
                ((string=? (car b) scheme) (loop (cdr l) (cdr hit) any))
                (else (loop (cdr l) own (cdr hit))))))))

;; -- values --

(define (theme-hex s i n) (string->number (substring s i (+ i n)) 16))

;; "#rgb", "#rrggbb", "rgb(r, g, b)" -> rgb565, else #f
(define (theme-literal v)
  (let ((n (string-length v)))
    (cond ((and (= n 7) (char=? (string-ref v 0) #\#))
           (let ((r (theme-hex v 1 2)) (g (theme-hex v 3 2)) (b (theme-hex v 5 2)))
             (and r g b (gui-rgb r g b))))
          ((and (= n 4) (char=? (string-ref v 0) #\#))
           (let ((r (theme-hex v 1 1)) (g (theme-hex v 2 1)) (b (theme-hex v 3 1)))
             (and r g b (gui-rgb (* r 17) (* g 17) (* b 17)))))
          ((and (> n 5) (string=? (substring v 0 4) "rgb(") (char=? (string-ref v (- n 1)) #\)))
           (let ((p (map (lambda (x) (string->number (theme-trim x))) (theme-split (substring v 4 (- n 1)) #\,))))
             (and (= (length p) 3) (integer? (car p)) (integer? (cadr p)) (integer? (caddr p))
                  (gui-rgb (max 0 (min 255 (car p))) (max 0 (min 255 (cadr p))) (max 0 (min 255 (caddr p)))))))
          (else #f))))

;; Steps 2-5 for exactly this alias: its value as written, or #f
(define (theme-lookup alias)
  (or (theme-block-get theme-app-css theme-scheme alias)
      (theme-block-get theme-sys-css theme-scheme alias)
      (theme-block-get theme-app-defaults theme-scheme alias)
      (theme-block-get theme-app-defaults theme-mode alias)
      (let ((d (assoc alias (if (string=? theme-mode "day") THEME-DAY THEME-NIGHT)))) (and d (cdr d)))))

(define (theme-resolve name depth)
  (or (theme-literal name)
      (and (< depth 8)
           (let ((v (theme-lookup name)))
             (or (and v (theme-resolve v (+ depth 1)))
                 (let ((u (theme-last-index name #\_)))   ; the category: titlebar_bg -> bg
                   (and u (theme-resolve (substring name (+ u 1) (string-length name)) (+ depth 1)))))))))

;; A color for drawing: a number as it is, else an alias or a literal resolved
;; through the scheme in use (the foreground for a name nothing resolves)
(define (theme-color c)
  (cond ((number? c) c)
        ((symbol? c) (theme-color (symbol->string c)))
        ((not (string? c)) 0)
        (else
         (let ((hit (assoc c theme-cache)))
           (if hit
               (cdr hit)
               (let ((v (or (theme-resolve c 0) (theme-resolve "fg" 0) 65535)))
                 (set! theme-cache (cons (cons c v) theme-cache))
                 v))))))

;; The app's own defaults: (theme-defaults! "day" '(("titlebar_bg" . "#ffe9a8")))
;; for the day scheme ("night", a scheme of theme.css or "*" for every one)
(define (theme-defaults! scheme alist)
  (set! theme-app-defaults (append theme-app-defaults (list (cons scheme alist))))
  (theme-apply!))

;; -- the mode --

(define (theme-setting key default)
  (let ((v (config-get key))) (if (and (string? v) (> (string-length (theme-trim v)) 0)) (theme-trim v) default)))

(define (theme-number key default)
  (let ((n (string->number (theme-setting key "")))) (if n n default)))

;; "07:30" -> minutes, else default
(define (theme-hm key default)
  (let ((p (theme-split (theme-setting key "") #\:)))
    (if (= (length p) 2)
        (let ((h (string->number (car p))) (m (string->number (cadr p))))
          (if (and (integer? h) (integer? m)) (+ (* h 60) m) default))
        default)))

(define (theme-now-minutes)
  (let ((t (time-local))) (and t (+ (* 60 (list-ref t 3)) (list-ref t 4)))))

(define (theme-in-day? now from to)
  (if (<= from to) (and (>= now from) (< now to)) (or (>= now from) (< now to))))

(define (theme-by-time)
  (let ((now (theme-now-minutes)))
    (if (not now)
        theme-mode
        (if (theme-in-day? now (theme-hm "theme_day_start" 420) (theme-hm "theme_night_start" 1140)) "day" "night"))))

(define (theme-by-light)
  (let ((lux (light-lux))
        (on (theme-number "theme_light_day" 120))
        (off (theme-number "theme_light_night" 50)))
    (cond ((>= lux on) "day")
          ((<= lux off) "night")
          ((= theme-ticks 0) (if (>= lux (quotient (+ on off) 2)) "day" "night"))   ; at the start: the nearer
          (else theme-mode))))                                                  ; between: as it was

;; Sunrise and sunset (minutes of the local day) at lat / lon, #f without
;; the place or the local time's offset (NOAA's approximation, about a minute)
(define (theme-sun-times)
  (let ((lat (theme-number "theme_lat" #f)) (lon (theme-number "theme_lon" #f)) (t (time-local)))
    (and lat lon t theme-utc-offset
         (let* ((pi 3.141592653589793) (rad (/ pi 180.0))
                (doy (theme-day-of-year (car t) (cadr t) (caddr t)))
                (g (* (/ (* 2.0 pi) 365.0) (- doy 1)))
                (eq (* 229.18 (+ 0.000075 (* 0.001868 (cos g)) (* -0.032077 (sin g))
                                 (* -0.014615 (cos (* 2 g))) (* -0.040849 (sin (* 2 g))))))
                (decl (+ 0.006918 (* -0.399912 (cos g)) (* 0.070257 (sin g)) (* -0.006758 (cos (* 2 g)))
                         (* 0.000907 (sin (* 2 g))) (* -0.002697 (cos (* 3 g))) (* 0.00148 (sin (* 3 g)))))
                (la (* lat rad))
                (x (- (/ (cos (* 90.833 rad)) (* (cos la) (cos decl))) (* (/ (sin la) (cos la)) (/ (sin decl) (cos decl)))))
                (ha (/ (acos (max -1.0 (min 1.0 x))) rad))
                (tz (/ theme-utc-offset 60.0))
                (rise (+ (- 720.0 (* 4.0 (+ lon ha)) eq) tz))
                (down (+ (- 720.0 (* 4.0 (- lon ha)) eq) tz)))
           (cons (modulo (inexact->exact (round rise)) 1440) (modulo (inexact->exact (round down)) 1440))))))

(define (theme-day-of-year y m d)
  (let loop ((i 1) (n d))
    (if (>= i m)
        n
        (loop (+ i 1) (+ n (list-ref (list 31 (if (and (= (modulo y 4) 0) (or (not (= (modulo y 100) 0)) (= (modulo y 400) 0))) 29 28)
                                            31 30 31 30 31 31 30 31 30 31)
                                      (- i 1)))))))

(define (theme-by-sun)
  (let ((s (theme-sun-times)) (now (theme-now-minutes)))
    (if (and s now) (if (theme-in-day? now (car s) (cdr s)) "day" "night") (theme-by-time))))

(define (theme-pick-mode)
  (let ((m (theme-setting "theme" "auto")))
    (cond ((string=? m "day") "day")
          ((string=? m "night") "night")
          (else (let ((how (theme-setting "theme_switch" "light")))
                  (cond ((string=? how "time") (theme-by-time))
                        ((string=? how "sun") (theme-by-sun))
                        (else (theme-by-light))))))))

;; The theme-* colors from the aliases of the scheme in use
(define (theme-apply!)
  (set! theme-scheme (theme-setting (if (string=? theme-mode "day") "theme_day" "theme_night") theme-mode))
  (set! theme-cache '())
  (set! theme-bg          (theme-color "bg"))
  (set! theme-card-bg     (theme-color "card_bg"))
  (set! theme-card-border (theme-color "card_border"))
  (set! theme-card-hdr    (theme-color "titlebar_bg"))
  (set! theme-text-main   (theme-color "text_fg"))
  (set! theme-text-sub    (theme-color "text_sub_fg"))
  (set! theme-text-muted  (theme-color "text_muted_fg"))
  (set! theme-accent      (theme-color "accent_fg"))
  (set! theme-accent-dark (theme-color "accent_bg"))
  (set! theme-success     (theme-color "success_fg"))
  (set! theme-warning     (theme-color "warning_fg"))
  (set! theme-danger      (theme-color "danger_fg"))
  (set! theme-purple      (theme-color "purple_fg"))
  (set! theme-dark-gray   (theme-color "inactive_fg"))
  (set! theme-divider     (theme-color "divider_border"))
  (set! theme-seg-on      (theme-color "seg_on_fg"))
  (set! theme-seg-off     (theme-color "seg_off_fg")))

;; Reads the files again; #t when one changed
(define (theme-read!)
  (let ((sys (if (defined? 'theme-css) (theme-css) #f))
        (app (fs-read "theme.css")))
    (let ((changed (not (and (equal? sys theme-sys-text) (equal? app theme-app-text)))))
      (if changed
          (begin (set! theme-sys-text sys)
                 (set! theme-app-text app)
                 (set! theme-sys-css (theme-parse sys))
                 (set! theme-app-css (if (equal? app sys) '() (theme-parse app)))))   ; the settings read the system's
      changed)))

(define (theme-load!)
  (theme-read!)
  (set! theme-mode (theme-pick-mode))
  (theme-apply!))

;; From the app loop once a second (utc: the second of the UTC day, the
;; app-tick's tick once the clock is set: with the local time it gives the
;; time zone, for the sunset); every 10 s the mode and the files are
;; checked. #t when the colors changed: the screen is to be drawn again.
(define (theme-tick! . utc)
  (if (and (pair? utc) (integer? (car utc)) (>= (car utc) 0) (< (car utc) 86400))
      (let ((t (time-local)))
        (if t (set! theme-utc-offset
                    (let ((d (- (+ (* 3600 (list-ref t 3)) (* 60 (list-ref t 4)) (list-ref t 5)) (car utc))))
                      (* 900 (round->exact (/ (cond ((> d 50400) (- d 86400)) ((< d -50400) (+ d 86400)) (else d)) 900))))))))
  (set! theme-ticks (+ theme-ticks 1))
  (if (= (remainder theme-ticks 10) 0)
      (let* ((files (theme-read!)) (mode (theme-pick-mode)) (changed (or files (not (string=? mode theme-mode)))))
        (if changed (begin (set! theme-mode mode) (theme-apply!)))
        changed)
      #f))

(define (round->exact x) (let ((r (round x))) (if (exact? r) r (inexact->exact r))))

(theme-load!)

;; Fonts
(define FONT-SYS-16   0) ; 16px Crisp System UI & CJK Font
(define FONT-CLOCK-32 1) ; 32px Hero Digital Number Font

;; Color constructor
(define (rgb r g b)
  (gui-rgb r g b))

;;; -------------------------------------------------------------------------
;;; 2. CSS-like Box Model & Alignment Primitives
;;; -------------------------------------------------------------------------

;; Render a styled card/box with seamless background and optional border
(define (gui-box x y w h bg border radius)
  (gui-card x y w h radius (if bg bg 0) (if border border 0)))

;; Scoped Clipping helper: executes thunk with clipping region, then restores previous clip
(define (gui-with-clip x y w h thunk)
  (gui-push-clip x y w h)
  (thunk)
  (gui-pop-clip))

;; Scoped Offscreen Sub-Buffer helper: executes thunk on offscreen buffer, then restores main target
(define (gui-with-buffer buf thunk)
  (gui-set-target buf)
  (thunk)
  (gui-reset-target))

;; Content box padding helper: returns (list inner-x inner-y inner-w inner-h)
(define (gui-content-box x y w h pad-x pad-y)
  (list (+ x pad-x)
        (+ y pad-y)
        (max 0 (- w (* 2 pad-x)))
        (max 0 (- h (* 2 pad-y)))))

;; Align text inside a container: halign: 0=left, 1=center, 2=right; valign: 0=top, 1=middle, 2=bottom
(define (gui-text-align x y w h str color font-id halign valign)
  (gui-text-box x y w h str color font-id halign valign))

;; Pill Badge with auto-measured width and centered text
(define (gui-badge x y str bg-col text-col)
  (let* ((tw (gui-text-width str FONT-SYS-16))
         (w (+ tw 14))
         (h 22))
    (gui-round-rect x y w h 11 bg-col #t)
    (gui-text-box x y w h str text-col FONT-SYS-16 1 1)
    w))

;; Sleek Progress Bar
(define (gui-progress-bar x y w h percent fg-col bg-col)
  (let* ((p (max 0 (min 100 percent)))
         (track-bg (if bg-col bg-col theme-card-hdr))
         (fill-fg  (if fg-col fg-col theme-accent))
         (fill-w   (quotient (* (- w 4) p) 100)))
    (gui-round-rect x y w h 4 theme-card-border #f)
    (gui-round-rect (+ x 1) (+ y 1) (- w 2) (- h 2) 3 track-bg #t)
    (if (> fill-w 0)
        (gui-round-rect (+ x 2) (+ y 2) fill-w (- h 4) 2 fill-fg #t))))

;; Interactive Button with centered label and solid seamless background
(define (gui-button x y w h label pressed? bg-col text-col)
  (let* ((bg (if bg-col bg-col (if pressed? theme-accent-dark theme-card-bg)))
         (tc (if text-col text-col theme-text-main))
         (border (if pressed? theme-accent theme-card-border)))
    (gui-card x y w h 6 bg border)
    (gui-text-box x y w h label tc FONT-SYS-16 1 1)))

;;; -------------------------------------------------------------------------
;;; 3. CSS Grid & Flex Layout Calculations
;;; -------------------------------------------------------------------------

;; Compute bounding box for a cell in an N-column, M-row grid
(define (gui-grid-cell origin-x origin-y total-w total-h cols rows col-idx row-idx gap-x gap-y)
  (let* ((usable-w (- total-w (* gap-x (- cols 1))))
         (cell-w   (quotient usable-w cols))
         (usable-h (- total-h (* gap-y (- rows 1))))
         (cell-h   (quotient usable-h rows))
         (x        (+ origin-x (* col-idx (+ cell-w gap-x))))
         (y        (+ origin-y (* row-idx (+ cell-h gap-y)))))
    (list x y cell-w cell-h)))

;; Stat Tile: Display icon/title, hero 32px digital number, and unit with padding & clipping
(define (gui-stat-tile x y w h title val-str unit-str val-col)
  ;; Outline only: no fill behind the numbers
  (gui-round-rect x y w h 8 theme-card-border #f)
  ;; Title with 10px padding
  (gui-text-box (+ x 10) (+ y 6) (- w 20) 18 title theme-text-muted FONT-SYS-16 0 1)
  ;; Big value centred in the space under the title, clipped to the tile
  ;; push/pop instead of gui-with-clip: no closure, no heap environment
  (let ((vy (+ y 24 (max 0 (quotient (- h 24 40) 2)))))
    (gui-push-clip (+ x 10) vy (- w 18) 44)
    (gui-text-styled (+ x 10) vy val-str val-col FONT-CLOCK-32)
    (if (> (string-length unit-str) 0)
        (let ((val-w (gui-text-width val-str FONT-CLOCK-32)))
          (gui-text-styled (+ x 12 val-w) (+ vy 12) unit-str theme-text-sub FONT-SYS-16)))
    (gui-pop-clip)))

;;; -------------------------------------------------------------------------
;;; 4. WiFi Signal & System Indicators
;;; -------------------------------------------------------------------------

(define (gui-draw-wifi-icon x y connected? rssi)
  (let loop ((i 0))
    (if (< i 4)
        (let* ((bx (+ x (* i 5)))
               (bh (+ 4 (* i 3)))
               (by (+ y 14 (- bh)))
               (active? (and connected? (>= rssi (- -90 (* i 15)))))
               (col (if active? theme-success theme-dark-gray)))
          (gui-rect bx by 3 bh col #t)
          (loop (+ i 1))))))

;;; -------------------------------------------------------------------------
;;; 5. Declarative Widget Representation & Touch Dispatch
;;; -------------------------------------------------------------------------

(define (make-widget type id x y w h props on-click)
  (list type id x y w h props on-click))

(define (widget-type w)     (car w))
(define (widget-id w)       (cadr w))
(define (widget-x w)        (caddr w))
(define (widget-y w)        (cadddr w))
(define (widget-w w)        (car (cddddr w)))
(define (widget-h w)        (cadr (cddddr w)))
(define (widget-props w)    (caddr (cddddr w)))
(define (widget-handler w)  (cadddr (cddddr w)))

(define (gui-hit-test widgets tx ty)
  (let loop ((ws widgets))
    (if (null? ws)
        #f
        (let ((w (car ws)))
          (let ((x (widget-x w))
                (y (widget-y w))
                (width (widget-w w))
                (height (widget-h w)))
            (if (and (>= tx x) (< tx (+ x width))
                     (>= ty y) (< ty (+ y height)))
                w
                (loop (cdr ws))))))))

(define (gui-dispatch-touch widgets)
  (let ((touch (gui-touch-poll)))
    (if touch
        (let ((hit (gui-hit-test widgets (car touch) (cdr touch))))
          (if (and hit (procedure? (widget-handler hit)))
              ((widget-handler hit) hit touch)))
        #f)))

;;; -------------------------------------------------------------------------
;;; 6. Framebuffer, Color Depth & Palette Configuration Helpers
;;; -------------------------------------------------------------------------

(define (gui-fb? . args)
  (if (null? args)
      (gui-framebuffer-enabled?)
      (gui-framebuffer-enable (car args))))

(define (gui-bpp . args)
  (if (null? args)
      (gui-color-depth)
      (gui-color-depth (car args))))

(define (gui-vfb-ram)
  (gui-framebuffer-ram))

;;; -------------------------------------------------------------------------
;;; 7. Multi-Dirty Rects & Scanline Banding Helpers
;;; -------------------------------------------------------------------------

(define (gui-dirty-count)
  (gui-dirty-rect-count))

(define (gui-get-dirty-list)
  (gui-dirty-rects))

(define (gui-flush-partial)
  (gui-flush-dirty))

(define (gui-with-bands band-height thunk)
  (gui-render-bands band-height thunk))


