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


