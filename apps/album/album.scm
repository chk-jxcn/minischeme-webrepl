;;; =========================================================================
;;; Photo album, 320x480 portrait, on the app framework (applib.scm).
;;; The photos and animations are uploaded on the board's web page (the
;;; app's tab, apps/album/web.html), which converts every picture in the
;;; browser: JPG, PNG, WebP, BMP into a screen-sized baseline JPEG, an
;;; animated GIF into a MANI file of JPEG frames (minischeme_image.h). They
;;; live in photos/ of the app's folder; the board draws them full screen,
;;; one after another (gui-image decodes only the rows each band needs).
;;;   short press: the next photo        long press: pause / resume
;;; Settings (the app's config.ini, also set from its web page): interval,
;;; slideshow, order, gif_play, gif_speed, show_info.
;;; =========================================================================

(define ALBUM-DIR "photos")
(define ALBUM-KEYS '("interval" "slideshow" "order" "gif_play" "gif_speed" "show_info"))

(define album-files '())                ; (("name" . bytes) ...), sorted by name (upload time)
(define album-index 0)                  ; the photo shown
(define album-left 0)                   ; seconds to the next one
(define album-paused #f)                ; a long press stops the slideshow
(define album-info #f)                  ; (w h frames ms) of the photo shown, #f: not an image
(define album-info-name "")
(define album-seed 12345)               ; the random order's generator

;; 1. Photos ---------------------------------------------------------------------------------

(define (album-ends? s suffix)
  (let ((n (string-length s)) (k (string-length suffix)))
    (and (>= n k) (string=? (substring s (- n k) n) suffix))))

(define (album-image? name) (or (album-ends? name ".jpg") (album-ends? name ".mani")))

;; Insertion sort by name (a few dozen photos)
(define (album-sort files)
  (define (insert f sorted)
    (cond ((null? sorted) (list f))
          ((string<? (car f) (car (car sorted))) (cons f sorted))
          (else (cons (car sorted) (insert f (cdr sorted))))))
  (let loop ((fs files) (acc '()))
    (if (null? fs) acc (loop (cdr fs) (insert (car fs) acc)))))

(define (album-scan!)
  (let ((files (fs-list ALBUM-DIR)))
    (set! album-files (album-sort (filter (lambda (f) (album-image? (car f))) (if (list? files) files '()))))
    (if (>= album-index (length album-files)) (set! album-index 0))
    (set! album-info-name "")))

(define (album-count) (length album-files))
(define (album-name i) (car (list-ref album-files i)))
(define (album-path name) (string-append ALBUM-DIR "/" name))

;; The shown photo's (w h frames ms), asked once per photo
(define (album-current-info)
  (let ((name (album-name album-index)))
    (if (not (string=? name album-info-name))
        (begin
          (set! album-info-name name)
          (set! album-info (image-info (album-path name)))))
    album-info))

;; 2. Settings -------------------------------------------------------------------------------

(define (album-on? key default) (if (member (app-config key default) '("1" "on" "yes" "true")) #t #f))
(define (album-number key default lo hi)
  (let ((n (string->number (app-config key default))))
    (clamp (if (integer? n) n (string->number default)) lo hi)))
(define (album-interval) (album-number "interval" "10" 3 3600))
(define (album-speed) (album-number "gif_speed" "100" 10 1000))
(define (album-random?) (string=? (app-config "order" "seq") "random"))

(define (album-random n)
  (set! album-seed (remainder (+ (* album-seed 1103) 12345 (remainder app-utc-sec 1000)) 1000003))
  (remainder album-seed n))

;; The next photo (step 1) or the one before (-1); random order picks another one
(define (album-next! step)
  (let ((n (album-count)))
    (if (> n 1)
        (set! album-index
              (if (album-random?)
                  (let pick ((k (album-random n))) (if (= k album-index) (pick (album-random n)) k))
                  (modulo (+ album-index step) n))))
    (set! album-left (album-interval))
    (app-invalidate-all)))

;; 3. Screen ---------------------------------------------------------------------------------

;; The photos' surround: black at night, the day scheme's background by day
;; (a theme.css may set photo_bg for either)
(theme-defaults! "night" '(("photo_bg" . "#000000")))
(theme-defaults! "day" '(("photo_bg" . "bg")))

(define (album-render-empty)
  (let ((cx (quotient (scr-w) 2)))
    (txt-center cx 190 "还没有照片" theme-text-main)
    (txt-center cx 222 "在设备网页的应用标签里上传" theme-text-muted)
    (txt-center cx 246 "JPG、PNG、GIF 动图都可以" theme-text-muted)
    (let ((ip (wifi-ip)))
      (if (and (string? ip) (not (string=? ip "0.0.0.0")))
          (txt-center cx 282 (string-append "http://" ip "/") theme-accent)))))

;; The position and the state in a strip at the bottom
(define (album-render-info)
  (let ((y (- (gui-height) 22)) (w (scr-w)))
    (gui-rect 0 y w 22 (theme-color "photo_bg") #t)
    (txt 8 (+ y 3) (string-append (number->string (+ album-index 1)) " / " (number->string (album-count))
                                  (if album-paused "   已暂停" ""))
         theme-text-sub)
    (txt-right (- w 8) (+ y 3) app-time theme-text-sub)))

(define (album-render)
  (gui-clear (theme-color "photo_bg"))
  (if (= (album-count) 0)
      (album-render-empty)
      (let ((info (album-current-info)) (cx (quotient (scr-w) 2)))
        (if info
            (gui-image (quotient (- (scr-w) (car info)) 2) (quotient (- (gui-height) (cadr info)) 2)
                       (album-path album-info-name) (album-on? "gif_play" "1") (album-speed))
            (begin
              (txt-center cx 210 "无法显示这张图片" theme-warning)
              (txt-center cx 236 album-info-name theme-text-muted)))
        (cond ((album-on? "show_info" "0") (album-render-info))
              (album-paused (txt 8 (- (gui-height) 22) "已暂停" theme-text-sub)))))
  (gui-flush))

;; 4. Buttons and time -----------------------------------------------------------------------

(define (app-button) (album-next! 1))

(define (app-long-press)
  (set! album-paused (not album-paused))
  (set! album-left (album-interval))
  (app-invalidate-all))

(define (app-touch x y) (album-next! (if (< x (quotient (scr-w) 2)) -1 1)))

(set! app-tick-proc
      (lambda (tick)
        (if (and (album-on? "slideshow" "1") (not album-paused) (not (info-active?)) (> (album-count) 1))
            (begin
              (set! album-left (- album-left 1))
              (if (<= album-left 0) (album-next! 1))))))

;; 5. The web page's calls (app-web name body) ---------------------------------------------

(define (album-settings)
  (map (lambda (k)
         (cons (string->symbol k)
               (app-config k (cond ((string=? k "interval") "10") ((string=? k "order") "seq")
                                   ((string=? k "gif_speed") "100") ((string=? k "show_info") "0") (else "1")))))
       ALBUM-KEYS))

(define (album-photo-json f)
  (let ((info (image-info (album-path (car f)))))
    (list (cons 'name (car f)) (cons 'size (cdr f))
          (cons 'w (if info (car info) 0)) (cons 'h (if info (cadr info) 0))
          (cons 'frames (if info (caddr info) 0)) (cons 'ms (if info (cadddr info) 0)))))

(define (album-answer)
  (let ((photos (map album-photo-json album-files)))
    (set! album-info-name "")             ; image-info opened every photo: ask again for the shown one
    (web-ok (cons 'photos photos) (cons 'index album-index) (cons 'paused album-paused)
            (cons 'settings (album-settings)))))

;; Checked values only: numbers in range, the known choices
(define (album-valid? key v)
  (cond ((string=? key "interval") (let ((n (string->number v))) (and (integer? n) (>= n 3) (<= n 3600))))
        ((string=? key "gif_speed") (let ((n (string->number v))) (and (integer? n) (>= n 10) (<= n 1000))))
        ((string=? key "order") (member v '("seq" "random")))
        (else (member v '("0" "1")))))

;; Saves the fields body has; #t, or the first key with a bad value
(define (album-save-settings! body)
  (let loop ((ks ALBUM-KEYS))
    (if (null? ks)
        #t
        (let ((v (web-field body (car ks))))
          (cond ((not v) (loop (cdr ks)))
                ((album-valid? (car ks) v) (app-config-set! (car ks) v) (loop (cdr ks)))
                (else (car ks)))))))

(define (album-find name)
  (let loop ((fs album-files) (i 0))
    (cond ((null? fs) #f) ((string=? (car (car fs)) name) i) (else (loop (cdr fs) (+ i 1))))))

(define (app-web name body)
  (cond
    ((string=? name "list") (album-scan!) (album-answer))
    ((string=? name "show")
     (album-scan!)
     (let ((i (album-find (or (web-field body "name") ""))))
       (if (not i)
           (web-error "no such photo")
           (begin (set! album-index i) (set! album-left (album-interval)) (app-invalidate-all) (album-answer)))))
    ((string=? name "settings")
     (let ((bad (album-save-settings! body)))
       (if (string? bad)
           (web-error (string-append "bad value for " bad))
           (begin (set! album-left (album-interval)) (app-invalidate-all) (album-answer)))))
    ((string=? name "pause")
     (set! album-paused (equal? (web-field body "on") "1"))
     (set! album-left (album-interval))
     (app-invalidate-all)
     (album-answer))
    (else (web-error (string-append "unknown call: " name)))))

;; 6. Start ----------------------------------------------------------------------------------

(album-scan!)
(set! album-left (album-interval))
(app-define! "电子相册" (list (app-local-page "相册" (lambda (items) #t))))
(set! gui-render-proc album-render)       ; full screen: no header or footer
(app-invalidate-all)
