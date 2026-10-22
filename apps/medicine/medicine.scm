;;; =========================================================================
;;; Medicine reminder, 320x480 portrait, on the app framework (applib.scm).
;;; Set up on the board's web page (the app's tab, apps/medicine/web.html):
;;;   medicines  name, unit (粒, 片, 袋 ...), photo (photos/m<id>.jpg) and a
;;;              plan: long-term, for N days from a date, or by quantity
;;;              (N units: each confirmed dose takes its amount off)
;;;   times      the time points; each lists its medicines with the amount
;;;              taken then, every day or every other day from a date
;;;   settings   how long a reminder may last (0: until every medicine is
;;;              confirmed), the text sizes
;;; The times go into schedule.ini (persist = 1): the system starts this app
;;; at each of them from any app and, until (app-return), again after a
;;; restart or a power cut (API 1.7, firmware 1.0.68+).
;;;   normal:   the medicines in use one after another: photo, the name and
;;;             the next amount large and bold, the next time bottom left,
;;;             the plan's progress bottom right; a press: the next one
;;;   reminder: "共 N 个药 第 k 个" blinks in the title; a press confirms one;
;;;             after the last, back to the app that ran before. Past the
;;;             time limit the rest count as taken.
;;; Amounts and quantities are kept in tenths (0.5 粒 = 5).
;;; Files (the app's folder):
;;;   meds.txt     id|name|unit|plan|n|start|left    plan long, days (n days), count (n, left: tenths)
;;;   slots.txt    id|HH:MM|med.alt.ref.amount,...   alt 1: every other day from day ref
;;;   log.txt      day|HH:MM|med|how|HH:MM|amount    how ok, auto (time limit), skip
;;;   pending.txt  day|HH:MM|start                   the reminder in progress (start: minutes)
;;; Days are counted from 1970-01-01 (time-local), minutes from that day too.
;;; =========================================================================

(define MED-PATH "meds.txt")
(define SLOT-PATH "slots.txt")
(define LOG-PATH "log.txt")
(define PENDING-PATH "pending.txt")
(define MED-SCHEDULE "schedule.ini")
(define MED-MAX 20)
(define SLOT-MAX 6)
(define LOG-KEEP 300)                   ; lines of log.txt kept
(define MED-NAME-MAX 60)                ; bytes
(define MED-UNIT-MAX 12)
(define MED-PHOTO-TOP 37)               ; 5 px under the title bar (HDR-H)
(define MED-SHOW-SECONDS 8)             ; normal mode: seconds per medicine
(define MED-DONE-SECONDS 3)
(define MED-WAIT-SECONDS 20)            ; a scheduled start waits this long for the date
(define MED-NL (list->string (list #\newline)))
(define MED-SCALE-KEYS '(("name_size" "3" 4) ("amount_size" "2" 4) ("list_size" "2" 3)))

(define med-list '())                   ; #(id name unit plan n start left)
(define slot-list '())                  ; #(id time entries), entries: (#(med alt ref amount) ...)
(define med-index 0)
(define med-left MED-SHOW-SECONDS)
(define med-info-cache '())             ; (id . image-info)
(define med-scales '())
(define med-max-minutes 0)              ; 0: a reminder lasts until every medicine is confirmed
(define med-due '())                    ; reminder: ((med . amount) ...) still to take
(define med-due-total 0)
(define med-due-done 0)
(define med-due-at "")                  ; reminder: its time, "" in normal mode
(define med-due-day 0)                  ; reminder: its day
(define med-due-start 0)                ; reminder: when it began (minutes)
(define med-done-left 0)
(define med-blink #t)
(define med-pending-at #f)              ; a scheduled start waiting for the date
(define med-pending-secs 0)

;; 1. Small helpers ------------------------------------------------------------------------

(define (med-trim s)
  (let* ((n (string-length s))
         (blank? (lambda (i) (<= (char->integer (string-ref s i)) 32)))
         (a (let loop ((i 0)) (if (and (< i n) (blank? i)) (loop (+ i 1)) i)))
         (b (let loop ((j n)) (if (and (> j a) (blank? (- j 1))) (loop (- j 1)) j))))
    (substring s a b)))

(define (med-int s default)
  (let ((n (and (string? s) (string->number (med-trim s))))) (if (integer? n) n default)))

;; "8:05" / "08:05" -> "08:05", else #f
(define (med-hm s)
  (let ((p (str-split (med-trim s) #\:)))
    (and (= (length p) 2)
         (= (string-length (cadr p)) 2)
         (let ((h (string->number (car p))) (m (string->number (cadr p))))
           (and (integer? h) (integer? m) (>= h 0) (< h 24) (>= m 0) (< m 60)
                (string-append (pad2 h) ":" (pad2 m)))))))

;; One line of at most limit bytes without | and ~ (the files' separators),
;; never cut inside a UTF-8 character
(define (med-clean s limit)
  (let* ((flat (med-trim (list->string (map (lambda (c) (if (or (memv c '(#\| #\~)) (< (char->integer c) 32)) #\space c))
                                            (string->list s)))))
         (n (string-length flat)))
    (if (<= n limit)
        flat
        (let back ((k limit))
          (if (and (> k 0) (= (quotient (char->integer (string-ref flat k)) 64) 2))
              (back (- k 1))
              (substring flat 0 k))))))

(define (med-read path)
  (let ((text (and (fs-exists? path) (fs-read path))))
    (if (string? text) (filter (lambda (l) (> (string-length (med-trim l)) 0)) (str-split text #\newline)) '())))

(define (med-write path lines) (fs-write path (web-join lines MED-NL)))

;; tenths -> "2", "0.5", "12.5"
(define (amt-text a)
  (if (= (remainder a 10) 0)
      (number->string (quotient a 10))
      (string-append (number->string (quotient a 10)) "." (number->string (remainder a 10)))))

(define (med-digit? c) (let ((b (char->integer c))) (or (and (>= b 48) (<= b 57)) (= b 46))))

;; "0.5粒" / "2 粒" / "半片" -> (tenths . unit): the leading number (1 without one) and the rest
(define (dose-split s)
  (let* ((t (med-trim s)) (n (string-length t))
         (end (let loop ((i 0)) (if (and (< i n) (med-digit? (string-ref t i))) (loop (+ i 1)) i)))
         (num (and (> end 0) (string->number (substring t 0 end))))
         (unit (med-trim (substring t end n))))
    (cons (if (and num (> num 0)) (max 1 (round->int (* num 10))) 10) (if (str-empty? unit) "次" unit))))

(define (round->int x) (let ((r (round x))) (if (exact? r) r (inexact->exact r))))

;; Days since 1970-01-01 of a date
(define (med-civil-days y m d)
  (let* ((y (if (<= m 2) (- y 1) y))
         (era (quotient (if (>= y 0) y (- y 399)) 400))
         (yoe (- y (* era 400)))
         (doy (+ (quotient (+ (* 153 (+ m (if (> m 2) -3 9))) 2) 5) (- d 1)))
         (doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)) doy)))
    (+ (* era 146097) doe -719468)))

(define (med-today)
  (let ((t (time-local))) (if t (med-civil-days (car t) (cadr t) (caddr t)) #f)))

;; minutes since day 0 (local wall time), #f without the clock
(define (med-now-minutes)
  (let ((t (time-local)))
    (if t (+ (* 1440 (med-civil-days (car t) (cadr t) (caddr t))) (* 60 (list-ref t 3)) (list-ref t 4)) #f)))

;; 2. Medicines --------------------------------------------------------------------------

(define (med-id m) (vector-ref m 0))
(define (med-name m) (vector-ref m 1))
(define (med-unit m) (vector-ref m 2))
(define (med-plan m) (vector-ref m 3))          ; "long" "days" "count"
(define (med-n m) (vector-ref m 4))             ; days, or tenths bought
(define (med-start m) (vector-ref m 5))         ; first day
(define (med-units m) (vector-ref m 6))         ; tenths left (count plan)
(define (med-shape m) (vector-ref m 7))         ; auto, capsule, tablet, ball, oval, sachet, none
(define (med-color m) (vector-ref m 8))         ; "#RRGGBB" (or a name of MED-COLORS)
(define (med-color2 m) (vector-ref m 9))        ; a capsule's other half
(define (med-photo-path m) (string-append "photos/m" (number->string (med-id m)) ".jpg"))

;; meds.txt: 7 fields; the 8 of version 3 (id|name|dose|per|plan|n|start|left,
;; whole units) are converted, their dose's amount kept for the time points
(define med-v3-amounts '())             ; (id . tenths) of converted version 3 lines

(define (med-parse line)
  (let ((f (str-split line #\|)))
    (cond ((or (= (length f) 7) (= (length f) 9) (= (length f) 10))
           (let ((id (med-int (car f) #f)) (plan (list-ref f 3)))
             (and id (member plan '("long" "days" "count"))
                  (vector id (cadr f) (caddr f) plan (max 0 (med-int (list-ref f 4) 0)) (med-int (list-ref f 5) 0)
                          (max 0 (med-int (list-ref f 6) 0))
                          (if (and (= (length f) 9) (member (list-ref f 7) MED-SHAPES)) (list-ref f 7) "auto")
                          (if (and (>= (length f) 9) (med-color-ok? (list-ref f 8))) (list-ref f 8) "white")
                          (if (and (= (length f) 10) (med-color-ok? (list-ref f 9))) (list-ref f 9) MED-CAPSULE-2)))))
          ((= (length f) 8)
           (let ((id (med-int (car f) #f)) (plan (list-ref f 4)) (d (dose-split (caddr f))))
             (and id (member plan '("long" "days" "count"))
                  (begin
                    (set! med-v3-amounts (cons (cons id (car d)) med-v3-amounts))
                    (vector id (cadr f) (cdr d) plan
                            (* (if (string=? plan "count") 10 1) (max 0 (med-int (list-ref f 5) 0)))
                            (med-int (list-ref f 6) 0) (* 10 (max 0 (med-int (list-ref f 7) 0))) "auto" "white" MED-CAPSULE-2)))))
          (else #f))))

(define (med-line m)
  (web-join (list (number->string (med-id m)) (med-name m) (med-unit m) (med-plan m)
                  (number->string (med-n m)) (number->string (med-start m)) (number->string (med-units m))
                  (med-shape m) (med-color m) (med-color2 m))
            "|"))

(define (med-find id)
  (let loop ((l med-list)) (cond ((null? l) #f) ((= (med-id (car l)) id) (car l)) (else (loop (cdr l))))))

;; 'later (not started), 'active, 'done (days over or used up) on day d (#f: unknown)
(define (med-status m d)
  (cond ((and d (< d (med-start m))) 'later)
        ((and d (string=? (med-plan m) "days") (>= d (+ (med-start m) (med-n m)))) 'done)
        ((and (string=? (med-plan m) "count") (<= (med-units m) 0)) 'done)
        (else 'active)))

(define (med-active? m d) (eq? (med-status m d) 'active))

;; "长期" / "剩余 5/7 天" / "剩余 20/60 粒"
(define (med-plan-text m d)
  (let ((st (med-status m d)))
    (cond ((eq? st 'later) "尚未开始")
          ((eq? st 'done) (if (string=? (med-plan m) "count") "已用完" "疗程已结束"))
          ((string=? (med-plan m) "days")              ; 疗程: day k of N
           (string-append "疗程: " (number->string (clamp (+ 1 (- (or d (med-start m)) (med-start m))) 1 (med-n m)))
                          "/" (number->string (med-n m)) "天"))
          ((string=? (med-plan m) "count")             ; 疗程: taken / bought
           (string-append "疗程: " (amt-text (- (med-n m) (med-units m))) "/" (amt-text (med-n m)) " " (med-unit m)))
          (else "长期"))))

;; 3. Time points ------------------------------------------------------------------------

(define (slot-id s) (vector-ref s 0))
(define (slot-time s) (vector-ref s 1))
(define (slot-entries s) (vector-ref s 2))
(define (ent-med e) (vector-ref e 0))
(define (ent-alt? e) (= (vector-ref e 1) 1))
(define (ent-ref e) (vector-ref e 2))
(define (ent-amount e) (vector-ref e 3))        ; tenths

(define (ent-parse s)
  (let ((f (str-split s #\.)))
    (and (>= (length f) 3) (<= (length f) 4) (med-int (car f) #f)
         (let ((id (med-int (car f) 0)))
           (vector id (if (string=? (cadr f) "1") 1 0) (med-int (caddr f) 0)
                   (if (= (length f) 4)
                       (clamp (med-int (list-ref f 3) 10) 1 10000)
                       (let ((v3 (assv id med-v3-amounts))) (if v3 (cdr v3) 10))))))))

(define (slot-parse line)
  (let ((f (str-split line #\|)))
    (and (>= (length f) 2) (med-int (car f) #f) (med-hm (cadr f))
         (vector (med-int (car f) 0) (med-hm (cadr f))
                 (if (and (>= (length f) 3) (> (string-length (caddr f)) 0))
                     (filter (lambda (e) e) (map ent-parse (str-split (caddr f) #\,)))
                     '())))))

(define (ent-text e)
  (string-append (number->string (ent-med e)) "." (if (ent-alt? e) "1" "0") "." (number->string (ent-ref e))
                 "." (number->string (ent-amount e))))

(define (slot-line s)
  (string-append (number->string (slot-id s)) "|" (slot-time s) "|" (web-join (map ent-text (slot-entries s)) ",")))

(define (slot-at time)
  (let loop ((l slot-list)) (cond ((null? l) #f) ((string=? (slot-time (car l)) time) (car l)) (else (loop (cdr l))))))

(define (slot-entry s id)
  (let loop ((l (slot-entries s))) (cond ((null? l) #f) ((= (ent-med (car l)) id) (car l)) (else (loop (cdr l))))))

;; taken on day d: every day, or every other day from its ref
(define (ent-day? e d) (or (not (ent-alt? e)) (not d) (= (modulo (- d (ent-ref e)) 2) 0)))

;; The slots sorted by time
(define (slots-sorted)
  (let insert-all ((l slot-list) (acc '()))
    (if (null? l)
        acc
        (insert-all (cdr l)
                    (let ins ((s (car l)) (a acc))
                      (cond ((null? a) (list s))
                            ((string<? (slot-time s) (slot-time (car a))) (cons s a))
                            (else (cons (car a) (ins s (cdr a))))))))))

;; m's next dose: (days-ahead time amount) after now (today, tomorrow or the day
;; after, counting every-other-day plans), #f when no time point takes it
(define (med-next-dose m)
  (let ((d (med-today)) (now (if (string=? app-time "--:--") "" app-time)) (slots (slots-sorted)))
    (let day-loop ((k 0))
      (if (> k 2)
          #f
          (or (let loop ((l slots))
                (cond ((null? l) #f)
                      ((let ((e (slot-entry (car l) (med-id m))))
                         (and e (ent-day? e (and d (+ d k))) (or (> k 0) (string<? now (slot-time (car l))))
                              (list k (slot-time (car l)) (ent-amount e)))))
                      (else (loop (cdr l)))))
              (day-loop (+ k 1)))))))

;; 4. Load and save ----------------------------------------------------------------------

;; Files of version 1 and 2: meds.txt "id|name|qty|slots|alt|ref" (slots: time
;; point numbers), the times only in schedule.ini. Made into the new files once.
(define (med-migrate!)
  (let ((lines (med-read MED-PATH)))
    (if (and (pair? lines) (not (fs-exists? SLOT-PATH)) (= (length (str-split (car lines) #\|)) 6))
        (let* ((old (filter (lambda (f) (= (length f) 6)) (map (lambda (l) (str-split l #\|)) lines)))
               (ini (med-read MED-SCHEDULE))
               (tline (let loop ((l ini)) (cond ((null? l) #f) ((str-starts? (med-trim (car l)) "times") (car l)) (else (loop (cdr l))))))
               (tval (and tline (let ((kv (str-split tline #\=))) (and (pair? (cdr kv)) (car (str-split (cadr kv) #\;))))))
               (times (if tval (filter (lambda (t) t) (map med-hm (str-split tval #\,))) '())))
          (set! med-list (map (lambda (f) (vector (med-int (car f) 0) (cadr f) (cdr (dose-split (caddr f))) "long" 0 0 0 "auto" "white" MED-CAPSULE-2)) old))
          (set! slot-list
                (let loop ((ts times) (k 1) (acc '()))
                  (if (null? ts)
                      (reverse acc)
                      (loop (cdr ts) (+ k 1)
                            (cons (vector k (car ts)
                                          (filter (lambda (e) e)
                                                  (map (lambda (f)
                                                         (and (memv k (map (lambda (x) (med-int x 0)) (str-split (list-ref f 3) #\,)))
                                                              (vector (med-int (car f) 0) (if (string=? (list-ref f 4) "1") 1 0)
                                                                      (med-int (list-ref f 5) 0) (car (dose-split (caddr f))))))
                                                       old)))
                                  acc)))))
          (med-write MED-PATH (map med-line med-list))
          (slots-save!)))))

(define (med-load!)
  (set! med-v3-amounts '())
  (set! med-list (filter (lambda (m) m) (map med-parse (med-read MED-PATH))))
  (set! slot-list (filter (lambda (s) s) (map slot-parse (med-read SLOT-PATH))))
  (if (pair? med-v3-amounts)                       ; version 3 files: written in the new form once
      (begin (med-write MED-PATH (map med-line med-list)) (slots-save!) (set! med-v3-amounts '())))
  (set! med-info-cache '()))

(define (med-save!)
  (med-write MED-PATH (map med-line med-list))
  (set! med-info-cache '())
  (app-invalidate-all))

;; slots.txt and schedule.ini (the firmware reads times and persist)
(define (slots-save!)
  (med-write SLOT-PATH (map slot-line slot-list))
  (fs-write MED-SCHEDULE
            (string-append "[schedule]" MED-NL
                           "; written by the medicine app: the system starts it at these times" MED-NL
                           "times = " (web-join (map slot-time slot-list) ", ") MED-NL
                           "persist = 1 ; a reminder comes back after a restart until it is confirmed" MED-NL))
  (app-invalidate-all))

(define (med-load-settings!)
  (set! med-scales
        (map (lambda (k)
               (cons (car k) (clamp (med-int (app-config (car k) (cadr k)) (string->number (cadr k))) 1 (caddr k))))
             MED-SCALE-KEYS))
  (set! med-max-minutes (clamp (med-int (app-config "max_minutes" "0") 0) 0 1440)))

(define (med-scale key) (let ((hit (assoc key med-scales))) (if hit (cdr hit) 1)))

;; 5. The log ----------------------------------------------------------------------------

;; "day|HH:MM|med|how|HH:MM|amount" lines; the last LOG-KEEP kept
(define (log-add! day time med how amount)
  (let* ((lines (med-read LOG-PATH))
         (all (append lines (list (web-join (list (number->string day) time (number->string med) how
                                                  (if (string=? app-time "--:--") "" app-time) (number->string amount))
                                            "|"))))
         (n (length all)))
    (med-write LOG-PATH (if (> n LOG-KEEP) (list-tail all (- n LOG-KEEP)) all))))

;; The medicines logged for day and time (taken, timed out or skipped)
(define (log-meds day time)
  (let ((prefix (string-append (number->string day) "|" time "|")))
    (map (lambda (l) (med-int (list-ref (str-split l #\|) 2) -1))
         (filter (lambda (l) (str-starts? l prefix)) (med-read LOG-PATH)))))

;; 6. The reminder -----------------------------------------------------------------------

(define (med-reminding?) (not (string=? med-due-at "")))

(define (med-led on) (if (defined? 'led-set) (if on (led-set 255 96 0) (led-set 0 0 0))))

;; ((med . amount) ...) of time point at due on day d and not logged yet
(define (med-due-for at d)
  (let ((s (slot-at at)) (done (if d (log-meds d at) '())))
    (if (not s)
        '()
        (filter (lambda (x) x)
                (map (lambda (e)
                       (let ((m (med-find (ent-med e))))
                         (and m (med-active? m d) (ent-day? e d) (not (memv (med-id m) done)) (cons m (ent-amount e)))))
                     (slot-entries s))))))

(define (pending-save!)
  (fs-write PENDING-PATH (string-append (number->string med-due-day) "|" med-due-at "|" (number->string med-due-start))))

(define (pending-clear!) (if (fs-exists? PENDING-PATH) (fs-remove PENDING-PATH)))

;; The reminder of time point at on day d (a new one, or one a restart cut short)
(define (med-remind! at d start)
  (let* ((day (or d 0))
         (ids (map (lambda (x) (med-id (car x))) med-due))
         (more (filter (lambda (x) (not (memv (med-id (car x)) ids))) (med-due-for at d))))
    (if (null? med-due)
        ;; already confirmed at this time point (a reminder a restart cut short) count as done
        (let* ((s (slot-at at))
               (sids (if s (map ent-med (slot-entries s)) '()))
               (done (if d (length (filter (lambda (id) (memv id sids)) (log-meds d at))) 0)))
          (set! med-due-done (if (null? more) 0 done))
          (set! med-due-total med-due-done)))
    (set! med-due (append med-due more))
    (set! med-due-total (+ med-due-total (length more)))
    (set! med-due-at at)
    (set! med-due-day day)
    (set! med-due-start (or start (med-now-minutes) 0))
    (set! med-done-left 0)
    (set! med-blink #t)
    (if (null? med-due)
        (med-finish!)                                  ; nothing to take now
        (begin (pending-save!) (med-led #t) (app-invalidate-all)))))

;; Takes one dose (med . amount): logged, the amount off a count plan
(define (med-take! x how)
  (let ((m (med-find (med-id (car x)))))
    (log-add! med-due-day med-due-at (med-id (car x)) how (cdr x))
    (if (and m (string=? (med-plan m) "count") (not (string=? how "skip")))
        (begin (vector-set! m 6 (max 0 (- (med-units m) (cdr x))))
               (med-save!)))))

;; Back to the app that ran before; when this app is that one, its normal screen
(define (med-finish!)
  (set! med-due '())
  (set! med-due-at "")
  (set! med-due-total 0)
  (set! med-due-done 0)
  (set! med-done-left 0)
  (pending-clear!)
  (med-led #f)
  (if (not (app-return))
      (begin (set! med-left MED-SHOW-SECONDS) (app-invalidate-all))))

(define (med-confirm!)
  (if (pair? med-due)
      (begin
        (med-take! (car med-due) "ok")
        (set! med-due (cdr med-due))
        (set! med-due-done (+ med-due-done 1))
        (if (null? med-due) (begin (set! med-done-left MED-DONE-SECONDS) (med-led #f) (pending-clear!)))
        (app-invalidate-all))))

;; Every medicine left, logged as how ("auto": the time limit, "skip": ended on the web page)
(define (med-close-all! how)
  (for-each (lambda (x) (med-take! x how)) med-due)
  (med-finish!))

;; Past the time limit: the rest count as taken
(define (med-check-limit!)
  (let ((now (med-now-minutes)))
    (if (and (> med-max-minutes 0) now (pair? med-due) (>= (- now med-due-start) med-max-minutes))
        (med-close-all! "auto"))))

(define (med-shown) (filter (lambda (m) (med-active? m (med-today))) med-list))

(define (med-next! step)
  (let ((n (length (med-shown))))
    (if (> n 0) (set! med-index (modulo (+ med-index step) n)))
    (set! med-left MED-SHOW-SECONDS)
    (app-invalidate-all)))

;; 7. Screen -----------------------------------------------------------------------------

(define (med-photo-info m)
  (let ((hit (assv (med-id m) med-info-cache)))
    (if hit
        (cdr hit)
        (let ((info (image-info (med-photo-path m))))
          (set! med-info-cache (cons (cons (med-id m) info) med-info-cache))
          info))))

;; The photo under the title bar, centered across, cut at bottom
(define (med-render-photo m bottom)
  (let ((info (med-photo-info m)))
    (if info (gui-image (quotient (- (scr-w) (car info)) 2) MED-PHOTO-TOP (med-photo-path m)))
    (gui-rect 0 bottom (scr-w) (- (gui-height) bottom) theme-bg #t)))

;; Without a photo the name and the amount are one size larger
(define (med-size m key) (+ (med-scale key) (if (med-photo-info m) 0 1)))

;; Where the text block (block px high) goes between the photo and bottom:
;; (cut . y), the photo cut at cut, the block at y, centered in the space
;; under the photo, or pushed up into the photo when the space is short
(define (med-layout m block bottom)
  (let* ((info (med-photo-info m))
         (photo-end (+ MED-PHOTO-TOP (if info (cadr info) 0)))
         (space (- bottom photo-end)))
    (if (>= space (+ block 16))
        (cons photo-end (+ photo-end (quotient (- space block) 2)))
        (cons (- bottom block 16) (- bottom block 8)))))

;; The largest multiple up to s at which text (1 px wider: bold) fits the width
(define (med-fit-scale s text)
  (if (or (<= s 1) (<= (+ 1 (* s (txt-w text))) (- (scr-w) 16))) (max s 1) (med-fit-scale (- s 1) text)))

;; Bold text at x, y, k times the font's size: drawn twice, 1 px apart
(define (med-bold-at x y text color k)
  (if (> k 1)
      (begin (gui-text-scaled x y text color k F-TEXT)
             (gui-text-scaled (+ x 1) y text color k F-TEXT))
      (begin (txt x y text color) (txt (+ x 1) y text color))))

;; The amount, then the dose drawn as that many shapes of the medicine's
;; kind (a half one for .5), at most 5, tilted: their boxes overlap, the
;; shapes do not
(define MED-PILL-MAX 5)
(define MED-SHAPES '("auto" "capsule" "tablet" "ball" "oval" "sachet" "none"))
(define MED-COLORS '(("white" 235 235 228) ("yellow" 240 200 60) ("orange" 240 140 50) ("red" 215 60 60)
                     ("pink" 240 150 180) ("blue" 80 140 230) ("green" 90 190 110) ("brown" 165 110 70)))

(define MED-CAPSULE-2 "#EBEBE4")         ; a capsule's other half by default: off-white

;; "#RRGGBB": its 0..255 parts, else #f
(define (med-hex-rgb c)
  (and (string? c) (= (string-length c) 7) (char=? (string-ref c 0) #\#)
       (let ((part (lambda (i) (string->number (substring c i (+ i 2)) 16))))
         (let ((r (part 1)) (g (part 3)) (b (part 5)))
           (and (integer? r) (integer? g) (integer? b) (list r g b))))))

(define (med-color-ok? c) (or (assoc c MED-COLORS) (med-hex-rgb c)))

(define (med-rgb name)
  (let ((c (assoc name MED-COLORS)) (h (med-hex-rgb name)))
    (cond (c (gui-rgb (cadr c) (caddr c) (cadddr c)))
          (h (gui-rgb (car h) (cadr h) (caddr h)))
          (else (gui-rgb 235 235 228)))))

;; The shape drawn: the medicine's, or one from its unit ("auto")
(define (med-shape-of m)
  (let ((sh (med-shape m)) (u (med-unit m)))
    (if (not (string=? sh "auto"))
        sh
        (cond ((member u '("粒")) "capsule")
              ((member u '("片")) "tablet")
              ((member u '("颗" "丸")) "ball")
              ((member u '("袋" "包")) "sachet")
              (else "none")))))

(define (med-isqrt n) (if (<= n 0) 0 (inexact->exact (floor (sqrt (exact->inexact n))))))

;; The left half of a disk (a broken tablet)
(define (med-half-disk cx cy r color)
  (let loop ((dy (- r)))
    (if (<= dy r)
        (let ((dx (med-isqrt (- (* r r) (* dy dy)))))
          (gui-rect (- cx dx) (+ cy dy) (+ dx 1) 1 color #t)
          (loop (+ dy 1))))))

;; An oval tablet along the rising diagonal, semi-axes a and b; half: its lower-left half
(define (med-oval cx cy a b color half)
  (let* ((fa (exact->inexact a)) (fb (exact->inexact b))
         (qa (/ 1.0 (* 2.0 fa fa))) (qb (/ 1.0 (* 2.0 fb fb)))
         (aa (+ qa qb)))
    (let loop ((dy (- a)))
      (if (<= dy a)
          (let* ((y (exact->inexact dy))
                 (bb (* 2.0 y (- qb qa)))
                 (cc (- (* aa y y) 1.0))
                 (disc (- (* bb bb) (* 4.0 aa cc))))
            (if (>= disc 0.0)
                (let* ((r (sqrt disc))
                       (lo (/ (- (- bb) r) (* 2.0 aa)))
                       (hi (/ (+ (- bb) r) (* 2.0 aa)))
                       (hi (if half (min hi y) hi))
                       (x0 (inexact->exact (round lo)))
                       (x1 (inexact->exact (round hi))))
                  (if (>= x1 x0) (gui-rect (+ cx x0) (+ cy dy) (+ 1 (- x1 x0)) 1 color #t))))
            (loop (+ dy 1)))))))

;; Half a capsule: rounded at x1 y1, cut square (perpendicular to its axis)
;; e px further along the rising diagonal; radius r. Rows: the body is the
;; band |X + Y| <= r*sqrt(2) between the end and the cut, X - Y in [0, 2e]
;; (X, Y relative to x1 y1), plus the round end's disk.
(define (med-half-capsule x1 y1 e r color)
  (let ((r2 (* (exact->inexact r) 1.41421356)))
    (let loop ((dy (- (+ e r 1))))
      (if (<= dy (+ r 1))
          (let* ((y (exact->inexact dy))
                 (lo (max (- (- y) r2) y))
                 (hi (min (+ (- y) r2) (+ y (* 2.0 e)))))
            (if (<= lo hi)
                (let ((x0 (inexact->exact (round lo))) (x1r (inexact->exact (round hi))))
                  (gui-rect (+ x1 x0) (+ y1 dy) (+ 1 (- x1r x0)) 1 color #t)))
            (loop (+ dy 1)))))
    (gui-circle x1 y1 r color #t)))

;; One dose shape in the box x y (s x s)
(define (med-pill shape x y s color color2 half)
  (let* ((cx (+ x (quotient s 2))) (cy (+ y (quotient s 2)))
         (light (gui-rgb 235 235 228)) (shade (gui-rgb 120 120 120)))
    (cond
      ((string=? shape "capsule")              ; two halves along the rising diagonal
       (let* ((r (max 2 (quotient s 6)))
              (e (quotient (* (- s (* 2 r)) 4) 10))
              (steps (max 2 e))
              (other color2))
         (if half
             (med-half-capsule (- cx e) (+ cy e) e r color)
             (let loop ((i 0))
               (if (<= i (* 2 steps))
                   (let ((px (+ (- cx e) (quotient (* i e) steps)))
                         (py (- (+ cy e) (quotient (* i e) steps))))
                     (gui-circle px py r (if (<= i steps) color other) #t)
                     (loop (+ i 2))))))))
      ((string=? shape "tablet")               ; a round tablet with its score line
       (let ((r (quotient (* s 3) 10)) (d (quotient (* s 2) 10)))
         (if half
             (med-half-disk cx cy r color)
             (begin (gui-circle cx cy r color #t)
                    (gui-line (- cx d) (+ cy d) (+ cx d) (- cy d) shade)))))
      ((string=? shape "ball")                 ; a ball with a highlight
       (let ((r (quotient (* s 3) 10)))
         (if half (med-half-disk cx cy r color) (gui-circle cx cy r color #t))
         (gui-circle (- cx (quotient r 3)) (- cy (quotient r 3)) (max 1 (quotient r 4)) light #t)))
      ((string=? shape "oval")                 ; an oval tablet along the diagonal
       (med-oval cx cy (quotient (* s 45) 100) (quotient (* s 2) 10) color half))
      ((string=? shape "sachet")               ; a sachet, crimped at both ends
       (let* ((w (quotient (* s 55) 100)) (h (quotient (* s 8) 10)) (h (if half (quotient h 2) h))
              (x0 (- cx (quotient w 2))) (y0 (- (+ cy (quotient (* s 4) 10)) h)) (c (max 2 (quotient h 8))))
         (gui-rect x0 y0 w h color #t)
         (gui-rect x0 y0 w c shade #t)
         (gui-rect x0 (- (+ y0 h) c) w c shade #t)))
      (else #f))))

(define (med-amount-line y m a color k)
  (let* ((text (string-append (amt-text a) " " (med-unit m)))
         (k (med-fit-scale k text))
         (tw (+ 1 (* k (txt-w text))))
         (shape (med-shape-of m))
         (whole (quotient a 10))
         (half (>= (remainder a 10) 5))
         (n (+ whole (if half 1 0)))
         (avail (- (scr-w) 16 tw 12))
         (want (* 16 k))                                   ; a box as tall as the text
         (span (lambda (sz) (+ sz (quotient (* (- n 1) sz 62) 100))))
         (s (if (and (not (string=? shape "none")) (> n 0) (<= a (* 10 MED-PILL-MAX)))
                (if (<= (span want) avail) want (quotient (* avail 100) (+ 100 (* (- n 1) 62))))
                0))
         (pills (>= s 12))
         (step (quotient (* s 62) 100))
         (total (if pills (+ tw 12 (span s)) tw))
         (x0 (quotient (- (scr-w) total) 2)))
    (med-bold-at x0 y text color k)
    (if pills
        (let loop ((i 0) (x (+ x0 tw 12)))
          (if (< i n)
              (begin (med-pill shape x (+ y (quotient (- (* 16 k) s) 2)) s (med-rgb (med-color m)) (med-rgb (med-color2 m))
                               (and half (= i (- n 1))))
                     (loop (+ i 1) (+ x step))))))))

;; Bold text centered at y, k times the font's size: drawn twice, 1 px apart
(define (med-bold y text color k)
  (let ((x (quotient (- (scr-w) (* k (txt-w text)) 1) 2)))
    (cond ((> k 1)
           (gui-text-scaled x y text color k F-TEXT)
           (gui-text-scaled (+ x 1) y text color k F-TEXT))
          ((<= (txt-w text) (- (scr-w) 16))
           (txt x y text color)
           (txt (+ x 1) y text color))
          (else (txt-fit 8 y (- (scr-w) 16) text color)))))

(define (med-header title right bg fg)
  (med-header-colors title right bg fg fg))

;; The title on the left, the clock right-aligned (as every app's header)
(define (med-header-colors title right bg fg right-fg)
  (gui-rect 0 0 (scr-w) HDR-H bg #t)
  (txt-fit 8 8 (- (scr-w) 24 (txt-w right)) title fg)
  (txt-right (- (scr-w) 8) 8 right right-fg))


;; "【已服1/共4种  服药时间08:00】"
(define (med-reminder-title)
  (string-append "【已服" (number->string med-due-done) "/共" (number->string med-due-total) "种  服药时间" med-due-at "】"))

;; 1..99 in Chinese numerals: 一, 十二, 二十
(define (cn-num n)
  (let ((d (vector "零" "一" "二" "三" "四" "五" "六" "七" "八" "九")))
    (cond ((< n 10) (vector-ref d n))
          ((< n 20) (string-append "十" (if (= n 10) "" (vector-ref d (- n 10)))))
          ((< n 100) (string-append (vector-ref d (quotient n 10)) "十"
                                    (if (= (remainder n 10) 0) "" (vector-ref d (remainder n 10)))))
          (else (number->string n)))))

;; A count: 两 for 2 ("共两个药"), else as cn-num
(define (cn-count n) (if (= n 2) "两" (cn-num n)))

;; The next time point of all, "08:00" (the first one tomorrow after the last), #f
(define (med-next-time)
  (if (or (null? slot-list) (string=? app-time "--:--"))
      #f
      (let loop ((l (map slot-time slot-list)) (best #f) (first #f))
        (if (null? l)
            (or best first)
            (let ((t (car l)))
              (loop (cdr l)
                    (if (and (string<? app-time t) (or (not best) (string<? t best))) t best)
                    (if (or (not first) (string<? t first)) t first)))))))

;; A medicine's next dose and what is left, in small text on the line ending at bottom
(define MED-INFO-H 22)
(define (med-info-line m bottom)
  (let ((y (- bottom MED-INFO-H)) (right (med-plan-text m (med-today))))
    (txt-right (- (scr-w) 10) (+ y 2) right theme-text-sub)
    (txt-fit 10 (+ y 2) (- (scr-w) 30 (txt-w right)) (next-text (med-next-dose m)) theme-text-sub)))

;; The bottom bar: left and right texts
(define (med-footer left right)
  (let ((y (- (gui-height) FTR-H)))
    (gui-rect 0 y (scr-w) FTR-H theme-card-hdr #t)
    (txt-right (- (scr-w) 8) (+ y 3) right theme-text-sub)
    (txt-fit 8 (+ y 3) (- (scr-w) 24 (txt-w right)) left theme-text-main)))

(define (next-text nd)
  (if nd
      (string-append "下次: " (cond ((= (car nd) 1) "明天 ") ((= (car nd) 2) "后天 ") (else "")) (cadr nd))
      "下次: 未安排"))

(define (med-render-empty)
  (let ((cx (quotient (scr-w) 2)))
    (txt-center cx 180 (if (null? med-list) "还没有药品" "没有正在服用的药品") theme-text-main)
    (txt-center cx 212 "在设备网页的应用标签里设置" theme-text-muted)
    (txt-center cx 236 "药品和服药时间" theme-text-muted)
    (if (wifi-connected?) (txt-center cx 272 (string-append "http://" (wifi-ip) "/") theme-accent))))

(define (med-render-normal)
  (let* ((shown (med-shown)) (n (length shown)) (d (med-today)))
    (if (>= med-index (max 1 n)) (set! med-index 0))
    (med-header (if (> n 1) (string-append "吃药提醒  " (number->string (+ med-index 1)) "/" (number->string n)) "吃药提醒")
                app-time theme-card-hdr theme-text-main)
    (if (= n 0)
        (med-render-empty)
        (let* ((m (list-ref shown med-index))
               (nd (med-next-dose m))
               (amount (if nd (string-append (amt-text (caddr nd)) " " (med-unit m)) ""))
               (k (med-size m "list_size"))
               (kn (med-fit-scale k (med-name m)))
               (ka (med-fit-scale k amount))
               (block (+ (* 16 kn) (if nd (+ 8 (* 16 ka)) 0)))
               (place (med-layout m block (- (gui-height) FTR-H MED-INFO-H)))
               (name-y (cdr place))
               (amount-y (+ name-y (* 16 kn) 8)))
          (med-render-photo m (car place))
          (med-bold name-y (med-name m) theme-text-main kn)
          (if nd (med-amount-line amount-y m (caddr nd) theme-accent ka))
          (med-info-line m (- (gui-height) FTR-H))))
    (let ((next (med-next-time)))
      (med-footer (cond ((null? slot-list) "未设置服药时间") (next (string-append "下次提醒 " next)) (else ""))
                  (if (wifi-connected?) (string-append "网页 " (wifi-ip)) "")))))

(define (med-render-reminder)
  (let* ((cx (quotient (scr-w) 2))
         (x (car med-due))
         (m (car x))
         (amount (string-append (amt-text (cdr x)) " " (med-unit m)))
         (kn (med-fit-scale (med-size m "name_size") (med-name m)))
         (kq (med-fit-scale (med-size m "amount_size") amount))
         (confirm "服药后按背部按钮确认")
         (kb (let fit ((k kq)) (if (or (<= k 1) (<= (* k (txt-w confirm)) (scr-w))) (max k 1) (fit (- k 1)))))   ; as the amount, the width at most
         (bar-h (+ (* 16 kb) 12))
         (bar-y (- (gui-height) bar-h))
         (place (med-layout m (+ (* 16 kn) 10 (* 16 kq)) (- bar-y MED-INFO-H)))
         (name-y (cdr place))
         (amount-y (+ name-y (* 16 kn) 10)))
    (med-header-colors (med-reminder-title) app-time
                       (if med-blink theme-warning theme-card-hdr)
                       (if med-blink theme-bg theme-warning)
                       (if med-blink theme-bg theme-text-main))   ; white, dark on the yellow (white would not show)
    (med-render-photo m (car place))
    (med-bold name-y (med-name m) theme-text-main kn)
    (med-amount-line amount-y m (cdr x) theme-accent kq)
    (med-info-line m bar-y)
    (gui-rect 0 bar-y (scr-w) bar-h theme-accent-dark #t)
    (med-bold-at (max 0 (quotient (- (scr-w) (* kb (txt-w confirm))) 2)) (+ bar-y 6) confirm theme-text-main kb)))

(define (med-render-done)
  (let ((cx (quotient (scr-w) 2)))
    (med-header (med-reminder-title) app-time theme-card-hdr theme-text-main)
    (med-bold 200 "已全部服用" theme-success 2)
    (txt-center cx 256 "即将回到原来的应用" theme-text-muted)))

(define (med-render-waiting)
  (let ((cx (quotient (scr-w) 2)))
    (med-header "吃药时间" med-pending-at theme-warning theme-bg)
    (txt-center cx 220 "正在读取日期..." theme-text-muted)))

(define (med-render)
  (gui-clear theme-bg)
  (cond ((pair? med-due) (med-render-reminder))
        ((med-reminding?) (med-render-done))
        (med-pending-at (med-render-waiting))
        (else (med-render-normal)))
  (gui-flush))

;; 8. Button, time, the scheduled start --------------------------------------------------

(define (app-button)
  (cond ((pair? med-due) (med-confirm!))
        ((med-reminding?) (med-finish!))
        (med-pending-at #t)
        (else (med-next! 1))))

(define (app-touch x y) (app-button))

;; The system: one of the times came while this app runs
(define (app-schedule at) (med-start! at))

;; Day counting needs the date: a start waits for the first clock tick. A
;; reminder a restart cut short (pending.txt) goes on with its own day and start.
(define (med-start! at)
  (if (or (time-local) (>= med-pending-secs MED-WAIT-SECONDS))
      (let* ((p (med-read PENDING-PATH))
             (f (if (pair? p) (str-split (car p) #\|) '()))
             (same (and (= (length f) 3) (string=? (cadr f) at))))
        (set! med-pending-at #f)
        (if same
            (med-remind! at (med-int (car f) 0) (med-int (caddr f) #f))
            (med-remind! at (med-today) #f)))
      (begin (set! med-pending-at at) (app-invalidate-all))))

;; At the start: a reminder a power cut interrupted while this app was the
;; boot app (no scheduled launch then) goes on
(define (med-resume!)
  (let* ((p (med-read PENDING-PATH)) (f (if (pair? p) (str-split (car p) #\|) '())))
    (if (= (length f) 3) (med-start! (cadr f)))))

(set! app-tick-proc
      (lambda (tick)
        (cond (med-pending-at
               (set! med-pending-secs (+ med-pending-secs 1))
               (med-start! med-pending-at))
              ((pair? med-due)
               (if (= (remainder tick 10) 0) (med-check-limit!)))
              ((med-reminding?)
               (set! med-done-left (- med-done-left 1))
               (if (<= med-done-left 0) (med-finish!)))
              (else
               (if (and (> (length (med-shown)) 1) (not (info-active?)))
                   (begin (set! med-left (- med-left 1))
                          (if (<= med-left 0) (med-next! 1))))
               (if (= (remainder tick 30) 0) (gui-invalidate 0 (- (gui-height) FTR-H) (scr-w) FTR-H))))))

;; The reminder's title bar blinks twice a second (the LED with it), from the app loop
(define med-applib-step app-step)
(define med-blink-at 0)
(define (app-step)
  (med-applib-step)
  (if (pair? med-due)
      (let ((now (time-ms)))
        (if (>= (- now med-blink-at) 500)
            (begin (set! med-blink-at now)
                   (set! med-blink (not med-blink))
                   (med-led med-blink)
                   (gui-invalidate 0 0 (scr-w) HDR-H))))))

;; 9. The web page's calls (app-web name body) -------------------------------------------

(define (med->alist m d)
  (let ((nd (med-next-dose m)))
    (list (cons 'id (med-id m)) (cons 'name (med-name m)) (cons 'unit (med-unit m))
          (cons 'plan (med-plan m)) (cons 'n (med-n m)) (cons 'start (med-start m)) (cons 'left (med-units m))
          (cons 'status (symbol->string (med-status m d))) (cons 'text (med-plan-text m d))
          (cons 'next (if nd (string-append (next-text nd) " · " (amt-text (caddr nd)) " " (med-unit m)) ""))
          (cons 'shape (med-shape m)) (cons 'drawn (med-shape-of m)) (cons 'color (med-color m)) (cons 'color2 (med-color2 m))
          (cons 'photo (if (med-photo-info m) #t #f)))))

(define (slot->alist s d)
  (let ((done (if d (log-meds d (slot-time s)) '())))
    (list (cons 'id (slot-id s)) (cons 'time (slot-time s))
          (cons 'entries (map (lambda (e)
                                (list (cons 'med (ent-med e)) (cons 'alt (ent-alt? e)) (cons 'ref (ent-ref e))
                                      (cons 'amount (ent-amount e))
                                      (cons 'today (ent-day? e d)) (cons 'done (if (memv (ent-med e) done) #t #f))))
                              (slot-entries s))))))

(define (med-answer . extra)
  (let ((d (med-today)))
    (apply web-ok (append (list (cons 'today (or d 0)) (cons 'time app-time)
                                (cons 'meds (map (lambda (m) (med->alist m d)) med-list))
                                (cons 'slots (map (lambda (s) (slot->alist s d)) (slots-sorted)))
                                (cons 'max MED-MAX) (cons 'maxslots SLOT-MAX)
                                (cons 'reminding (med-reminding?)) (cons 'at med-due-at)
                                (cons 'settings (cons (cons 'max_minutes med-max-minutes)
                                                      (map (lambda (p) (cons (string->symbol (car p)) (cdr p))) med-scales))))
                          extra))))

(define (med-next-id)
  (+ 1 (let loop ((l med-list) (hi 0)) (if (null? l) hi (loop (cdr l) (max hi (med-id (car l))))))))

;; The medicine of body (id 0: a new one); its id, or a message. n and left
;; of a count plan are tenths.
(define (med-save-from! body)
  (let* ((id (web-field-int body "id" 0))
         (old (and (> id 0) (med-find id)))
         (name (med-clean (or (web-field body "name") "") MED-NAME-MAX))
         (unit (med-clean (or (web-field body "unit") "") MED-UNIT-MAX))
         (plan (or (web-field body "plan") "long"))
         (n (med-int (web-field body "n") 0))
         (start (med-int (web-field body "start") (or (med-today) 0)))
         (left (web-field body "left"))
         (shape (or (web-field body "shape") (if old (med-shape old) "auto")))
         (color (or (web-field body "color") (if old (med-color old) "white")))
         (color2 (or (web-field body "color2") (if old (med-color2 old) MED-CAPSULE-2))))
    (cond ((str-empty? name) "药品名称不能为空")
          ((not (member shape MED-SHAPES)) "shape: auto, capsule, tablet, ball, oval, sachet or none")
          ((not (and (med-color-ok? color) (med-color-ok? color2))) "颜色应为 #RRGGBB")
          ((not (member plan '("long" "days" "count"))) "plan: long, days or count")
          ((and (string=? plan "days") (or (< n 1) (> n 3650))) "服用天数应为 1..3650")
          ((and (string=? plan "count") (or (< n 1) (> n 1000000))) "总数量应为 0.1..100000")
          ((and (> id 0) (not old)) "没有这个药品")
          ((and (not old) (>= (length med-list) MED-MAX)) "最多 20 个药品")
          (else
           ;; left: given, else kept while the plan is the same, else full
           (let* ((units (cond ((and (string? left) (string=? plan "count")) (clamp (med-int left n) 0 1000000))
                               ((and old (string=? (med-plan old) plan) (= (med-n old) n)) (med-units old))
                               (else n)))
                  (m (vector (if old id (med-next-id)) name (if (str-empty? unit) "粒" unit) plan n start units shape color color2)))
             (set! med-list (if old (map (lambda (x) (if (eq? x old) m x)) med-list) (append med-list (list m))))
             (med-save!)
             (med-id m))))))

(define (every-med? entries)
  (let loop ((l entries)) (cond ((null? l) #t) ((and (car l) (med-find (ent-med (car l)))) (loop (cdr l))) (else #f))))

;; slots=08:00=1.0.0.20,2.1.20380.5|12:30=...: every time point at once
;; (med.alt.ref.amount, the amount in tenths); #t or a message
(define (slots-save-from! body)
  (let* ((text (or (web-field body "slots") ""))
         (parts (filter (lambda (p) (> (string-length p) 0)) (str-split text #\|)))
         (parsed (map (lambda (p)
                        (let ((kv (str-split p #\=)))
                          (and (med-hm (car kv))
                               (cons (med-hm (car kv))
                                     (if (and (= (length kv) 2) (> (string-length (cadr kv)) 0))
                                         (map ent-parse (str-split (cadr kv) #\,))
                                         '())))))
                      parts)))
    (cond ((memv #f parsed) "时间格式应为 HH:MM")
          ((> (length parsed) SLOT-MAX) "最多 6 个时间点")
          ((let dup ((l (map car parsed))) (and (pair? l) (or (member (car l) (cdr l)) (dup (cdr l))))) "时间点重复")
          ((let bad ((l parsed)) (and (pair? l) (or (not (every-med? (cdar l))) (bad (cdr l))))) "药品不存在")
          (else
           (set! slot-list
                 (let loop ((l parsed) (k 1) (acc '()))
                   (if (null? l) (reverse acc) (loop (cdr l) (+ k 1) (cons (vector k (caar l) (cdar l)) acc)))))
           (slots-save!)
           #t))))

;; Saves the settings body has; #t, or the first key with a bad value
(define (med-save-settings! body)
  (let loop ((ks (cons '("max_minutes" "0" 1440) MED-SCALE-KEYS)))
    (if (null? ks)
        (begin (med-load-settings!) (app-invalidate-all) #t)
        (let* ((k (car ks)) (v (web-field body (car k))) (n (and v (string->number v)))
               (lo (if (string=? (car k) "max_minutes") 0 1)))
          (cond ((not v) (loop (cdr ks)))
                ((and (integer? n) (>= n lo) (<= n (caddr k))) (app-config-set! (car k) v) (loop (cdr ks)))
                (else (car k)))))))

;; The last 60 lines of the log, newest first
(define (log-answer)
  (let* ((lines (med-read LOG-PATH)) (n (length lines)) (last (if (> n 60) (list-tail lines (- n 60)) lines)))
    (web-ok (cons 'log (reverse
                        (filter (lambda (x) x)
                                (map (lambda (l)
                                       (let ((f (str-split l #\|)))
                                         (and (>= (length f) 4)
                                              (let ((m (med-find (med-int (list-ref f 2) -1)))
                                                    (amt (if (>= (length f) 6) (med-int (list-ref f 5) 0) 0)))
                                                (list (cons 'day (med-int (car f) 0)) (cons 'time (cadr f))
                                                      (cons 'med (med-int (list-ref f 2) -1))
                                                      (cons 'name (if m (med-name m) "（已删除）"))
                                                      (cons 'amount (if (and m (> amt 0)) (string-append (amt-text amt) " " (med-unit m)) ""))
                                                      (cons 'how (list-ref f 3))
                                                      (cons 'at (if (>= (length f) 5) (list-ref f 4) "")))))))
                                     last)))))))

(define (app-web name body)
  (cond
    ((string=? name "list") (med-load!) (med-load-settings!) (app-invalidate-all) (med-answer))
    ((string=? name "save")
     (let ((r (med-save-from! body))) (if (string? r) (web-error r) (med-answer (cons 'id r)))))
    ((string=? name "delete")
     (let ((m (med-find (web-field-int body "id" -1))))
       (if (not m)
           (web-error "没有这个药品")
           (begin (set! med-list (filter (lambda (x) (not (eq? x m))) med-list))
                  (set! slot-list (map (lambda (s) (vector (slot-id s) (slot-time s)
                                                           (filter (lambda (e) (not (= (ent-med e) (med-id m)))) (slot-entries s))))
                                       slot-list))
                  (med-save!)
                  (slots-save!)
                  (med-answer)))))
    ((string=? name "slots")
     (let ((r (slots-save-from! body))) (if (string? r) (web-error r) (med-answer))))
    ((string=? name "settings")
     (let ((r (med-save-settings! body))) (if (string? r) (web-error (string-append "bad value for " r)) (med-answer))))
    ((string=? name "log") (log-answer))
    ((string=? name "remind")                       ; the page's test: a time point's reminder now
     (let ((s (slot-at (or (med-hm (or (web-field body "time") "")) ""))))
       (if (not s)
           (web-error "没有这个时间点")
           (begin (med-remind! (slot-time s) (med-today) #f) (med-answer)))))
    ((string=? name "stop") (if (pair? med-due) (med-close-all! "skip") (if (med-reminding?) (med-finish!))) (med-answer))
    (else (web-error (string-append "unknown call: " name)))))

;; 10. Start ----------------------------------------------------------------------------

(med-migrate!)
(med-load!)
(med-load-settings!)
(app-define! "吃药提醒" (list (app-local-page "药品" (lambda (items) #t))))
(set! gui-render-proc med-render)
(let ((at (app-scheduled))) (if at (med-start! at) (med-resume!)))
(app-invalidate-all)
