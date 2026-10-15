;;; =========================================================================
;;; Token usage (Token 用量), 320x480 portrait, on the app framework.
;;; Data: the app proxy's /app/usage, read from the local logs of Claude Code,
;;; Gemini CLI and Codex CLI on the PC running the proxy: tokens in the last
;;; 5 hours and 7 days, time left in the 5-hour window, hourly and daily
;;; series (thousands of tokens), models; % of the limits set in the app's ini
;;; (Codex reports its own rate-limit percentages).
;;;   1 overview   2 Claude   3 Gemini   4 models
;;; =========================================================================

(define USAGE-INTERVAL 30000)            ; the proxy caches 30 s

(define (usage-url)
  (let loop ((keys '("claude_5h" "claude_week" "gemini_5h" "gemini_week")) (q ""))
    (if (null? keys)
        (app-url (string-append "/app/usage" (if (str-empty? q) "" (string-append "?" (substring q 1 (string-length q))))))
        (let ((v (app-config (car keys) "")))
          (loop (cdr keys) (if (str-empty? v) q (string-append q "&" (car keys) "=" (url-encode v))))))))

;; Agent "b": "5h,7d" token texts, "c": "messages 5h,7d", "e": "%5h,%week"
(define (agent-5h it) (str-part (it-b it) #\, 0))
(define (agent-7d it) (str-part (it-b it) #\, 1))
(define (agent-n5 it) (str-part (it-c it) #\, 0))
(define (agent-n7 it) (str-part (it-c it) #\, 1))
(define (agent-p5 it) (string->fixed (str-part (it-e it) #\, 0) 0))
(define (agent-pw it) (string->fixed (str-part (it-e it) #\, 1) 0))

(define (agent-color name)
  (cond ((equal? name "Claude") col-orange)
        ((equal? name "Gemini") theme-accent)
        (else theme-success)))

;; Thousands of tokens -> "760.0M" / "1.2B" / "530K"
(define (fmt-k n)
  (cond ((>= n 1000000) (string-append (fixed->str (quotient n 100000) 1) "B"))
        ((>= n 1000) (string-append (fixed->str (quotient n 100) 1) "M"))
        (else (string-append (int->str n) "K"))))

(define (fmt-minutes m)                  ; 191 -> "3h11m"
  (string-append (int->str (quotient m 60)) "h" (pad2 (remainder m 60)) "m"))

;; "102.5M": the number in the big font, the unit letter after it
(define (tokens-big x y s color)
  (let ((n (string-length s)))
    (if (= n 0)
        (big x y "0" color)
        (let ((last (string-ref s (- n 1))))
          (if (char-alphabetic-ascii? last)
              (big-unit x y (substring s 0 (- n 1)) (list->string (list last)) color)
              (big x y s color))))))

(define (char-alphabetic-ascii? c)
  (let ((b (char->integer c))) (or (and (>= b 65) (<= b 90)) (and (>= b 97) (<= b 122)))))

(define (pct-color p)
  (cond ((not p) theme-text-muted) ((>= p 90) theme-danger) ((>= p 70) theme-warning) (else theme-success)))

(define (limit-bar x y w label p)
  (txt x y label theme-text-muted)
  (txt-right (+ x w) y (if p (string-append (int->str p) "%") "未设额度") (pct-color p))
  (if p (progress-bar x (+ y 21) w 7 p (pct-color p))))

;; 1. Overview -----------------------------------------------------------------------------

(define (agent-card y h it)
  (let* ((name (it-a it)) (c (agent-color name)) (reset (it-int it 4))
         (codex? (str-empty? (it-b it))))
    (gui-round-rect 10 y 300 h 6 theme-card-border #f)
    (gui-rect 10 (+ y 8) 3 18 c #t)
    (txt 20 (+ y 7) name c)
    (txt-right 300 (+ y 7) (if reset (string-append "窗口剩余 " (fmt-minutes reset)) "5小时窗口未开始")
               theme-text-muted)
    (if codex?
        (begin
          (limit-bar 20 (+ y 40) 280 "5小时额度" (agent-p5 it))
          (limit-bar 20 (+ y 80) 280 "本周额度" (agent-pw it)))
        (begin
          (txt 20 (+ y 32) "5小时" theme-text-muted)
          (tokens-big 20 (+ y 50) (agent-5h it) theme-text-main)
          (txt 166 (+ y 32) "7天" theme-text-muted)
          (tokens-big 166 (+ y 50) (agent-7d it) theme-text-sub)
          (let ((p5 (agent-p5 it)) (pw (agent-pw it)))
            (if (or p5 pw)
                (begin
                  (if p5 (progress-bar 20 (+ y 88) 130 6 p5 (pct-color p5)))
                  (if pw (progress-bar 166 (+ y 88) 130 6 pw (pct-color pw)))
                  (txt 20 (+ y 98) (if p5 (string-append (int->str p5) "%") "") (pct-color p5))
                  (txt 166 (+ y 98) (if pw (string-append (int->str pw) "%") "") (pct-color pw)))
                (txt 20 (+ y 94) (string-append "消息 " (agent-n5 it) " / 7天 " (agent-n7 it))
                     theme-text-muted)))))))

(define (usage-render-overview items)
  (let* ((agents (items-all items "agent")) (n (max 1 (length agents)))
         (h (min 128 (- (quotient (- (body-bottom) (body-top)) n) 6))))
    (if (null? agents)
        (txt 14 70 "没有找到 agent 日志" theme-text-muted)
        (let loop ((as agents) (y (body-top)))
          (if (pair? as)
              (begin (agent-card y h (car as)) (loop (cdr as) (+ y h 6))))))))

;; 2-3. One agent ---------------------------------------------------------------------------

(define (usage-render-agent name)
  (lambda (items)
    (let ((ag (items-where items "agent" 1 name)) (hs (items-where items "hours" 1 name))
          (models (filter (lambda (m) (equal? (it-a m) name)) (items-all items "model")))
          (c (agent-color name)))
      (if (not ag)
          (txt 14 70 (string-append "没有 " name " 的使用记录") theme-text-muted)
          (begin
            (let loop ((tiles (list (list "5小时" (agent-5h ag) (agent-n5 ag))
                                    (list "7天" (agent-7d ag) (agent-n7 ag))))
                       (x 10))
              (if (pair? tiles)
                  (let ((t (car tiles)))
                    (gui-round-rect x (body-top) 146 66 6 theme-card-border #f)
                    (txt (+ x 8) (+ (body-top) 5) (car t) theme-text-muted)
                    (txt-right (+ x 138) (+ (body-top) 5) (string-append (caddr t) "条") theme-text-muted)
                    (tokens-big (+ x 8) (+ (body-top) 28) (cadr t) c)
                    (loop (cdr tiles) (+ x 154)))))
            (if hs
                (let* ((hours (it-ints hs 2)) (days (it-ints hs 3))
                       (hmax (max 1 (list-max (cons 0 hours)))) (dmax (max 1 (list-max (cons 0 days)))))
                  (section-note 112 "最近24小时" (string-append "峰值 " (fmt-k (list-max (cons 0 hours)))))
                  (gui-rect 10 136 300 80 theme-card-hdr #t)
                  (bar-chart 10 136 300 80 hours hmax c)
                  (txt 10 218 "-24h" theme-text-muted)
                  (txt-center 160 218 "-12h" theme-text-muted)
                  (txt-right 310 218 "现在" theme-text-muted)
                  (section-note 244 "最近7天" (string-append "合计 " (fmt-k (list-sum days))))
                  (gui-rect 10 268 300 60 theme-card-hdr #t)
                  (let ((pitch (bar-chart 10 268 300 60 days dmax c)))
                    (let loop ((i 0))
                      (if (< i (length days))
                          (begin
                            (txt-center (+ 10 (* i pitch) (quotient pitch 2)) 330
                                        (if (= i (- (length days) 1)) "今天"
                                            (string-append "-" (int->str (- (length days) 1 i)) "天"))
                                        theme-text-muted)
                            (loop (+ i 1))))))))
            (section 356 "模型")
            (let loop ((ms models) (y 380) (i 0))
              (if (and (pair? ms) (< i 3))
                  (let* ((m (car ms)) (share (or (it-int m 4) 0)))
                    (txt-fit 10 y 180 (it-b m) theme-text-sub)
                    (txt-right 310 y (string-append (it-c m) "  " (int->str share) "%") theme-text-main)
                    (progress-bar 10 (+ y 19) 300 3 share c)
                    (loop (cdr ms) (+ y 24) (+ i 1))))))))))

;; 4. Models of every agent, then every agent's quota ------------------------------------

(define (usage-render-models items)
  (let* ((models (items-all items "model"))
         (y (if (null? models)
                (begin (txt 14 (body-top) "暂无模型记录" theme-text-muted) (+ (body-top) 30))
                (let loop ((ms models) (y (body-top)) (i 0))
                  (if (and (pair? ms) (< i 5))
                      (let* ((m (car ms)) (share (or (it-int m 4) 0)) (c (agent-color (it-a m))))
                        (txt 10 y (it-a m) c)
                        (txt-fit 76 y 150 (it-b m) theme-text-main)
                        (txt-right 310 y (it-c m) theme-text-main)
                        (progress-bar 76 (+ y 22) 196 6 share c)
                        (txt-right 310 (+ y 18) (string-append (int->str share) "%") theme-text-muted)
                        (loop (cdr ms) (+ y 46) (+ i 1)))
                      y)))))
    (section (+ y 4) "额度")
    (let loop ((as (items-all items "agent")) (y (+ y 30)))
      (if (and (pair? as) (< (+ y 44) (body-bottom)))
          (let ((ag (car as)))
            (txt 10 y (it-a ag) (agent-color (it-a ag)))
            (limit-bar 76 y 108 "5小时" (agent-p5 ag))
            (limit-bar 202 y 108 "本周" (agent-pw ag))
            (loop (cdr as) (+ y 44)))))))

;; Pages -----------------------------------------------------------------------------------------

(app-define! "Token 用量"
  (list (app-page "总览" usage-url USAGE-INTERVAL usage-render-overview)
        (app-page "Claude" usage-url USAGE-INTERVAL (usage-render-agent "Claude"))
        (app-page "Gemini" usage-url USAGE-INTERVAL (usage-render-agent "Gemini"))
        (app-page "模型与额度" usage-url USAGE-INTERVAL usage-render-models)))

(set! app-subtitle-proc
      (lambda (items) (let ((m (items-find items "meta"))) (if m (it-b m) #f))))
