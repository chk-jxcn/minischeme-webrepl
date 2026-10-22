;;; =========================================================================
;;; Medicine reminder, 320x480 portrait, on the app framework (applib.scm).
;;; Set up on the board's web page (the app's tab, apps/medicine/web.html):
;;;   medicines  name, unit (粒, 片, 袋 ...), photo (photos/m<id>.jpg) and a
;;;              plan: long-term, for N days from a date, or by quantity
;;;              (N units: each confirmed dose takes its amount off)
;;;   times      the time points; each lists its medicines with the amount
;;;              taken then, every day or every other day from a date
;;;   settings   how long a reminder may last (0: until every medicine is
;;;              confirmed), the text sizes, sync with the app server, how
;;;              many days of records the board keeps (3 years)
;;; The times go into schedule.ini (persist = 1): the system starts this app
;;; at each of them from any app and, until (app-return), again after a
;;; restart or a power cut (API 1.7, firmware 1.0.68+).
;;;   normal:   the medicines in use one after another: photo, the name and
;;;             the next amount large and bold, the next time bottom left,
;;;             the plan's progress bottom right; a press: the next one
;;;   reminder: "共 N 个药 第 k 个" blinks in the title; a press confirms one;
;;;             after the last, back to the app that ran before. Past the
;;;             time limit, back too: the rest logged as missed (only a
;;;             confirmed dose counts as taken). The page's test shows a
;;;             time point's medicines the same way and logs nothing.
;;; Records can be changed on the page (missed -> taken). With sync on they
;;; go to the app server too (proxy/medicine.py: kept there, the board's
;;; copy wins); a failed upload is tried again later, a server out of reach
;;; changes nothing here. The board downloads them back only on a new
;;; install (the last 30 days, once) or when the page asks (N days).
;;; Amounts and quantities are kept in tenths (0.5 粒 = 5).
;;; Files (the app's folder):
;;;   meds.txt     id|name|unit|plan|n|start|left    plan long, days (n days), count (n, left: tenths)
;;;   slots.txt    id|HH:MM|med.alt.ref.amount,...   alt 1: every other day from day ref
;;;   log-<k>.txt  day|HH:MM|med|how|HH:MM|amount|s  days 16k..16k+15; how ok, miss (time limit),
;;;                skip, auto (old: the time limit counted taken); s 1: on the app server
;;;   names.txt    id|name|unit                      every medicine a record may name
;;;   sync.txt     dirty|k,k  names|0/1  fresh|0/1   files with records to upload, names to
;;;                upload, a new install that loads the server's records once
;;;   (log.txt of version 5 and before is moved into the log files once)
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
(define med-test #f)                    ; the reminder shown is the page's test: nothing logged
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
  (names-sync!)
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
  (set! med-max-minutes (clamp (med-int (app-config "max_minutes" "0") 0) 0 1440))
  (set! med-keep-days (clamp (med-int (app-config "keep_days" "1095") 1095) 7 3650)))

(define (med-scale key) (let ((hit (assoc key med-scales))) (if hit (cdr hit) 1)))

;; 5. The log ----------------------------------------------------------------------------
;; Records in 16-day files: one stays small to read and rewrite. Past
;; keep_days a file goes; when the folder (storage_kb, the image and the
;; photos included) runs short of room, the oldest go first.

(define LOG-DAYS 16)
(define LOG-PREFIX "log-")
(define NAMES-PATH "names.txt")
(define MED-QUOTA-KB 768)               ; meta.ini storage_kb
(define MED-ROOM-KB 64)                 ; kept free in the folder (photos)
(define med-keep-days 1095)

(define (rec-day r) (vector-ref r 0))
(define (rec-time r) (vector-ref r 1))
(define (rec-med r) (vector-ref r 2))
(define (rec-how r) (vector-ref r 3))
(define (rec-at r) (vector-ref r 4))            ; the confirm time, "" for none
(define (rec-amount r) (vector-ref r 5))        ; tenths
(define (rec-synced? r) (= (vector-ref r 6) 1))

(define (rec-parse line)
  (let ((f (str-split line #\|)))
    (and (>= (length f) 4) (med-int (car f) #f) (med-int (caddr f) #f)
         (vector (med-int (car f) 0) (cadr f) (med-int (caddr f) 0) (list-ref f 3)
                 (if (>= (length f) 5) (list-ref f 4) "")
                 (if (>= (length f) 6) (med-int (list-ref f 5) 0) 0)
                 (if (and (>= (length f) 7) (string=? (list-ref f 6) "1")) 1 0)))))

(define (rec-line r)
  (web-join (list (number->string (rec-day r)) (rec-time r) (number->string (rec-med r)) (rec-how r)
                  (rec-at r) (number->string (rec-amount r)) (if (rec-synced? r) "1" "0"))
            "|"))

(define (rec-same? r day time med) (and (= (rec-day r) day) (string=? (rec-time r) time) (= (rec-med r) med)))

(define (rec-in? r recs)
  (let loop ((l recs)) (and (pair? l) (or (rec-same? (car l) (rec-day r) (rec-time r) (rec-med r)) (loop (cdr l))))))

(define (rec-taken? how) (or (string=? how "ok") (string=? how "auto")))

(define (log-bucket day) (quotient day LOG-DAYS))
(define (log-path b) (string-append LOG-PREFIX (number->string b) ".txt"))
(define (log-read b) (filter (lambda (r) r) (map rec-parse (med-read (log-path b)))))
(define (log-write! b recs)
  (if (null? recs)
      (if (fs-exists? (log-path b)) (fs-remove (log-path b)))
      (med-write (log-path b) (map rec-line recs))))

;; Sum and least of a list (apply takes few arguments on the board)
(define (med-sum l) (let loop ((l l) (n 0)) (if (null? l) n (loop (cdr l) (+ n (car l))))))
(define (med-least l) (let loop ((l (cdr l)) (m (car l))) (if (null? l) m (loop (cdr l) (min m (car l))))))

;; The app's folder, #f where app-info does not tell it
(define (med-dir)
  (let ((me (app-info))) (and (pair? me) (= (length me) 4) (cadddr me))))

(define (int-sort l)
  (let ins-all ((l l) (acc '()))
    (if (null? l)
        acc
        (ins-all (cdr l) (let ins ((x (car l)) (a acc))
                           (cond ((null? a) (list x)) ((< x (car a)) (cons x a)) (else (cons (car a) (ins x (cdr a))))))))))

;; The record files' numbers, oldest first
(define (log-buckets)
  (let ((dir (med-dir)) (p (string-length LOG-PREFIX)))
    (int-sort
     (if dir
         (filter (lambda (b) b)
                 (map (lambda (f)
                        (let* ((name (car f)) (n (string-length name)))
                          (and (> n (+ p 4)) (str-starts? name LOG-PREFIX)
                               (string=? (substring name (- n 4) n) ".txt")
                               (med-int (substring name p (- n 4)) #f))))
                      (fs-list dir)))
         (let ((d (med-today)))             ; no listing: the files of the days kept
           (if d
               (let loop ((b (log-bucket (max 0 (- d med-keep-days)))) (acc '()))
                 (if (> b (log-bucket d)) acc (loop (+ b 1) (if (fs-exists? (log-path b)) (cons b acc) acc))))
               '()))))))

;; names.txt: (id name unit) of every medicine records may name
(define (names-load)
  (filter (lambda (x) x)
          (map (lambda (l)
                 (let ((f (str-split l #\|)))
                   (and (= (length f) 3) (med-int (car f) #f) (list (med-int (car f) 0) (cadr f) (caddr f)))))
               (med-read NAMES-PATH))))

(define (names-save! names)
  (med-write NAMES-PATH (map (lambda (x) (web-join (list (number->string (car x)) (cadr x) (caddr x)) "|")) names)))

;; The medicines' names and units kept; a change is uploaded
(define (names-sync!)
  (let* ((names (names-load))
         (changed (let loop ((l med-list))
                    (and (pair? l)
                         (let ((x (assv (med-id (car l)) names)))
                           (or (not x) (not (string=? (cadr x) (med-name (car l))))
                               (not (string=? (caddr x) (med-unit (car l)))) (loop (cdr l))))))))
    (if changed
        (begin (names-save! (append (map (lambda (m) (list (med-id m) (med-name m) (med-unit m))) med-list)
                                    (filter (lambda (x) (not (med-find (car x)))) names)))
               (sync-names-changed!)))))

;; (name . unit) of medicine id in names (names-load)
(define (name-of id names)
  (let ((m (med-find id)))
    (if m
        (cons (med-name m) (med-unit m))
        (let ((x (assv id names))) (if x (cons (cadr x) (caddr x)) (cons "（已删除）" ""))))))

;; A record of day and time point (replacing one of the same medicine), not uploaded yet
(define (log-add! day time med how amount)
  (let* ((b (log-bucket day))
         (r (vector day time med how (if (string=? app-time "--:--") "" app-time) amount 0)))
    (log-write! b (append (filter (lambda (x) (not (rec-same? x day time med))) (log-read b)) (list r)))
    (sync-dirty! b)
    (med-prune-room!)))

;; ((med . how) ...) logged for day and time (taken, missed or skipped)
(define (log-hows day time)
  (map (lambda (r) (cons (rec-med r) (rec-how r)))
       (filter (lambda (r) (and (= (rec-day r) day) (string=? (rec-time r) time))) (log-read (log-bucket day)))))

;; The medicines logged for day and time
(define (log-meds day time) (map car (log-hows day time)))

;; A record changed on the page: taken (ok) or not (skip); a count plan's
;; quantity follows. #t, or a message
(define (log-edit! day time med how)
  (let* ((b (log-bucket day)) (recs (log-read b))
         (r (let loop ((l recs)) (cond ((null? l) #f) ((rec-same? (car l) day time med) (car l)) (else (loop (cdr l)))))))
    (cond ((not r) "没有这条记录")
          ((not (member how '("ok" "skip"))) "how: ok or skip")
          ((string=? how (rec-how r)) #t)
          (else
           (let ((m (med-find med)) (was (rec-taken? (rec-how r))) (now (rec-taken? how)))
             (if (and m (string=? (med-plan m) "count") (not (eq? was now)))
                 (begin (vector-set! m 6 (clamp (+ (med-units m) (if now (- (rec-amount r)) (rec-amount r))) 0 (med-n m)))
                        (med-save!)))
             (vector-set! r 3 how)
             (vector-set! r 6 0)
             (log-write! b recs)
             (sync-dirty! b)
             #t)))))

;; log.txt of version 5 and before: into the log files once (to upload)
(define (log-migrate!)
  (if (fs-exists? LOG-PATH)
      (let ((recs (filter (lambda (r) r) (map rec-parse (med-read LOG-PATH)))))
        (let loop ((l recs) (done '()))
          (if (pair? l)
              (let ((b (log-bucket (rec-day (car l)))))
                (if (memv b done)
                    (loop (cdr l) done)
                    (let ((mine (filter (lambda (r) (= (log-bucket (rec-day r)) b)) recs)))
                      (log-write! b (append (filter (lambda (o) (not (rec-in? o mine))) (log-read b)) mine))
                      (sync-dirty! b)
                      (loop (cdr l) (cons b done)))))))
        (fs-remove LOG-PATH))))

;; Files past keep_days go, then the oldest while the folder is short of room
(define med-pruned-day #f)
(define (med-prune!)
  (let ((d (med-today)))
    (if d
        (begin (set! med-pruned-day d)
               (for-each (lambda (b)
                           (if (< (+ (* b LOG-DAYS) LOG-DAYS -1) (- d med-keep-days))
                               (begin (fs-remove (log-path b)) (sync-undirty! b))))
                         (log-buckets))))
    (med-prune-room!)))

(define (med-prune-room!)
  (let ((dir (med-dir)))
    (if dir
        (let loop ()
          (let ((used (med-sum (map cdr (append (fs-list dir) (fs-list (string-append dir "/photos"))))))
                (bs (log-buckets)))
            (if (and (> used (* 1024 (- MED-QUOTA-KB MED-ROOM-KB))) (> (length bs) 1))
                (begin (fs-remove (log-path (car bs))) (sync-undirty! (car bs)) (loop))))))))

;; 5b. Sync with the app server (proxy/medicine.py) ---------------------------------------
;; One request at a time through the JSON feed (the app has no feed of its
;; own); a request that gets no answer in 30 s fails, tried again 10 minutes
;; later (or sooner, when a record changes). Names first, then the files
;; with records not on the server, then a download asked for.

(define SYNC-PATH "sync.txt")
(define SYNC-RETRY 600)
(define SYNC-TIMEOUT 30)
(define SYNC-URL-MAX 230)               ; a plain request line: 256 bytes before firmware 1.0.69
(define SYNC-KEYS '("t" "n" "e" "d" "h" "m" "w" "a" "nm" "u" "more"))
(define SYNC-GET-LIM 20)
(define sync-dirty '())                 ; log files with records to upload
(define sync-names-dirty #f)
(define sync-fresh #f)                  ; a new install: the server's last 30 days once
(define sync-names-queue '())
(define sync-job #f)                    ; #(kind seconds payload) of the request running
(define sync-wait 10)                   ; seconds to the next step
(define sync-msg "")
(define sync-get #f)                    ; downloading: #(from-day offset stored auto?)

(define (sync-on?) (string=? (app-config "sync" "0") "1"))

(define (sync-save!)
  (med-write SYNC-PATH (list (string-append "dirty|" (web-join (map number->string sync-dirty) ","))
                             (string-append "names|" (if sync-names-dirty "1" "0"))
                             (string-append "fresh|" (if sync-fresh "1" "0")))))

;; sync.txt; without it (a new install, or version 5 and before) a board
;; with no data at all is a new install
(define (sync-load!)
  (let ((lines (med-read SYNC-PATH)))
    (if (null? lines)
        (begin (set! sync-fresh (and (null? med-list) (null? slot-list) (null? (log-buckets)) (not (fs-exists? LOG-PATH))))
               (set! sync-names-dirty (pair? med-list))
               (sync-save!))
        (for-each (lambda (l)
                    (let ((f (str-split l #\|)))
                      (if (= (length f) 2)
                          (cond ((string=? (car f) "dirty")
                                 (set! sync-dirty (filter (lambda (b) b) (map (lambda (x) (med-int x #f)) (str-split (cadr f) #\,)))))
                                ((string=? (car f) "names") (set! sync-names-dirty (string=? (cadr f) "1")))
                                ((string=? (car f) "fresh") (set! sync-fresh (string=? (cadr f) "1")))))))
                  lines))))

(define (sync-soon!) (if (and (not sync-job) (> sync-wait 3)) (set! sync-wait 3)))

(define (sync-dirty! b)
  (if (not (memv b sync-dirty)) (begin (set! sync-dirty (append sync-dirty (list b))) (sync-save!)))
  (sync-soon!))

(define (sync-undirty! b)
  (if (memv b sync-dirty) (begin (set! sync-dirty (filter (lambda (x) (not (= x b))) sync-dirty)) (sync-save!))))

(define (sync-names-changed!) (set! sync-names-dirty #t) (set! sync-names-queue '()) (sync-save!) (sync-soon!))

;; "（08:05）", "" before the clock is set
(define (sync-clock) (if (string=? app-time "--:--") "" (string-append "（" app-time "）")))

(define (sync-failed! why)
  (if sync-job (json-feed-stop))
  (set! sync-job #f)
  (set! sync-msg (string-append "失败" (sync-clock) "：" why "；10 分钟后自动重试"))
  (set! sync-wait SYNC-RETRY))

(define (sync-done! what) (set! sync-msg (string-append what (sync-clock))))

(define (sync-start! kind query payload)
  (set! sync-job (vector kind 0 payload))
  (json-feed-start (string-append (app-proxy) "/app/medicine?" query) 3600000 SYNC-KEYS '((0 prefix "")) 4096 64 2))

;; "08:05" -> "0805", "" -> "-"
(define (hm-wire t) (if (= (string-length t) 5) (string-append (substring t 0 2) (substring t 3 5)) "-"))

(define (rec-wire r)
  (string-append (number->string (rec-day r)) "." (hm-wire (rec-time r)) "." (number->string (rec-med r)) "."
                 (rec-how r) "." (hm-wire (rec-at r)) "." (number->string (rec-amount r))))

;; As many names as one request takes (a long one shortened to fit)
(define (sync-send-names!)
  (if (null? sync-names-queue) (set! sync-names-queue (names-load)))
  (if (null? sync-names-queue)
      (begin (set! sync-names-dirty #f) (sync-save!) (set! sync-wait 0))
      (let loop ((l sync-names-queue) (q "op=names") (n 0))
        (let ((part (and (pair? l)
                         (string-append "&m=" (number->string (car (car l))) "~" (url-encode (med-clean (cadr (car l)) 40))
                                        "~" (url-encode (caddr (car l)))))))
          (if (and part (or (= n 0) (<= (+ 14 (string-length q) (string-length part)) SYNC-URL-MAX)))
              (loop (cdr l) (string-append q part) (+ n 1))
              (sync-start! 'names q n))))))

;; The first file's records not on the server, as many as one request takes
(define (sync-send-records!)
  (let* ((b (car sync-dirty)) (todo (filter (lambda (r) (not (rec-synced? r))) (log-read b))))
    (if (null? todo)
        (begin (sync-undirty! b) (set! sync-wait 0))
        (let loop ((l todo) (q "op=put&r=") (sent '()))
          (let ((part (and (pair? l) (rec-wire (car l)))))
            (if (and part (or (null? sent) (<= (+ 15 (string-length q) (string-length part)) SYNC-URL-MAX)))
                (loop (cdr l) (string-append q (if (null? sent) "" ",") part) (cons (car l) sent))
                (sync-start! 'put q (cons b sent))))))))

(define (sync-next!)
  (let ((d (med-today)))
    (if (and sync-fresh (not sync-get) d) (set! sync-get (vector (- d 29) 0 0 #t)))
    (cond
      ((not (or (sync-on?) sync-get)) #f)
      ((string=? (app-proxy) "")
       (set! sync-msg "没有设置应用服务器（设备设置里的应用代理，或本应用配置的 proxy_url）"))
      ((and (sync-on?) sync-names-dirty) (sync-send-names!))
      ((and (sync-on?) (pair? sync-dirty)) (sync-send-records!))
      (sync-get
       (sync-start! 'get (string-append "op=get&from=" (number->string (vector-ref sync-get 0)) "&off="
                                        (number->string (vector-ref sync-get 1)) "&lim=" (number->string SYNC-GET-LIM))
                    #f))
      (else #f))))

;; Once a second
(define (sync-tick!)
  (cond (sync-job
         (vector-set! sync-job 1 (+ (vector-ref sync-job 1) 1))
         (if (> (vector-ref sync-job 1) SYNC-TIMEOUT)
             (let ((e (assq 'error (json-feed-status))))
               (sync-failed! (if (and e (string? (cdr e)) (> (string-length (cdr e)) 0))
                                 (string-append "连不上应用服务器：" (cdr e))
                                 "连不上应用服务器")))))
        ((> sync-wait 0) (set! sync-wait (- sync-wait 1)))
        (else (set! sync-wait 5) (sync-next!))))

;; The sent records still as they were: on the server now
(define (sync-mark! b sent)
  (let* ((wires (map rec-wire sent))
         (recs (map (lambda (r)
                      (if (member (rec-wire r) wires)
                          (vector (rec-day r) (rec-time r) (rec-med r) (rec-how r) (rec-at r) (rec-amount r) 1)
                          r))
                    (log-read b))))
    (log-write! b recs)
    (if (not (let any ((l recs)) (and (pair? l) (or (not (rec-synced? (car l))) (any (cdr l))))))
        (sync-undirty! b))))

;; Item i of a download: (record . (id name unit)), #f when malformed
(define (sync-item i)
  (let* ((f (lambda (k) (or (json-feed-field i k) "")))
         (day (med-int (f 3) #f)) (time (med-hm (f 4))) (med (med-int (f 5) #f)) (how (f 6)))
    (and day time med (> med 0) (member how '("ok" "miss" "skip" "auto"))
         (cons (vector day time med how (or (med-hm (f 7)) "") (max 0 (med-int (f 1) 0)) 1)
               (list med (med-clean (f 8) MED-NAME-MAX) (med-clean (f 9) MED-UNIT-MAX))))))

;; Downloaded records the board does not have (its own copy wins); how many
(define (sync-store! items)
  (let ((names (names-load)) (added 0))
    (let loop ((l items) (done '()))
      (if (pair? l)
          (let ((b (log-bucket (rec-day (car (car l))))))
            (if (memv b done)
                (loop (cdr l) done)
                (let* ((old (log-read b))
                       (new (filter (lambda (x) (and (= (log-bucket (rec-day (car x))) b) (not (rec-in? (car x) old)))) items)))
                  (if (pair? new) (log-write! b (append old (map car new))))
                  (set! added (+ added (length new)))
                  (loop (cdr l) (cons b done)))))))
    (let ((more (filter (lambda (x) (and (not (assv (car x) names)) (> (string-length (cadr x)) 0)))
                        (map cdr items))))
      (if (pair? more)
          (names-save! (append names (let uniq ((l more) (acc '()))
                                       (cond ((null? l) (reverse acc))
                                             ((assv (car (car l)) acc) (uniq (cdr l) acc))
                                             (else (uniq (cdr l) (cons (car l) acc)))))))))
    added))

(define (sync-doc!)
  (let* ((kind (vector-ref sync-job 0)) (payload (vector-ref sync-job 2)) (n (json-feed-count))
         (t0 (and (> n 0) (json-feed-field 0 0))))
    (json-feed-stop)
    (set! sync-job #f)
    (cond
      ((not t0) (sync-failed! "应用服务器的回答不对（服务器版本太旧？）"))
      ((string=? t0 "err") (sync-failed! (or (json-feed-field 0 2) "应用服务器拒绝了")))
      ((eq? kind 'names)
       (set! sync-names-queue (list-tail sync-names-queue (min payload (length sync-names-queue))))
       (if (null? sync-names-queue) (begin (set! sync-names-dirty #f) (sync-save!)))
       (set! sync-wait 0))
      ((eq? kind 'put)
       (sync-mark! (car payload) (cdr payload))
       (sync-done! "已同步到应用服务器")
       (set! sync-wait 0))
      ((eq? kind 'get)
       (let loop ((i 0) (items '()) (end #f))
         (if (< i n)
             (let ((t (json-feed-field i 0)))
               (cond ((equal? t "r") (loop (+ i 1) (let ((x (sync-item i))) (if x (cons x items) items)) end))
                     ((equal? t "end") (loop (+ i 1) items i))
                     (else (loop (+ i 1) items end))))
             (let* ((added (+ (vector-ref sync-get 2) (sync-store! (reverse items))))   ; the server's order
                    (more (and end (equal? (json-feed-field end 10) "1") (> (- n 1) 0))))
               (if more
                   (begin (vector-set! sync-get 1 (+ (vector-ref sync-get 1) (- n 1)))
                          (vector-set! sync-get 2 added)
                          (set! sync-wait 0))
                   (begin (if (and (vector-ref sync-get 3) (> added 0)) (app-config-set! "sync" "1"))
                          (if sync-fresh (begin (set! sync-fresh #f) (sync-save!)))
                          (set! sync-get #f)
                          (sync-done! (string-append "从应用服务器下载了 " (number->string added) " 条记录"))
                          (app-invalidate-all))))))))))

;; The app loop: a request's answer
(define (sync-step!)
  (if (and sync-job (> (json-feed-seq) 0))
      (begin (set! app-last-seq (json-feed-seq)) (sync-doc!))))

;; Records not on the server yet
(define (sync-pending)
  (med-sum (map (lambda (b) (length (filter (lambda (r) (not (rec-synced? r))) (log-read b)))) sync-dirty)))

;; Local data cleared: the records, or everything (medicines, times, photos)
(define (med-clear! all)
  (for-each (lambda (b) (fs-remove (log-path b))) (log-buckets))
  (if sync-job (json-feed-stop))
  (set! sync-job #f)
  (set! sync-dirty '())
  (set! sync-names-queue '())
  (set! sync-get #f)
  (set! sync-fresh #f)
  (set! sync-msg "")
  (if all
      (begin (for-each (lambda (m) (if (fs-exists? (med-photo-path m)) (fs-remove (med-photo-path m)))) med-list)
             (set! med-list '())
             (set! slot-list '())
             (set! med-info-cache '())
             (if (fs-exists? NAMES-PATH) (fs-remove NAMES-PATH))
             (med-write MED-PATH '())
             (slots-save!))
      (names-save! (map (lambda (m) (list (med-id m) (med-name m) (med-unit m))) med-list)))
  (sync-save!)
  (set! med-index 0)
  (app-invalidate-all))

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

;; The page's test: every medicine of time point at, as a reminder that logs nothing.
;; #t, or a message
(define (med-test! at)
  (let* ((s (slot-at at))
         (due (if s
                  (filter (lambda (x) x)
                          (map (lambda (e) (let ((m (med-find (ent-med e)))) (and m (cons m (ent-amount e))))) (slot-entries s)))
                  '())))
    (if (null? due)
        "这个时间点还没有选药"
        (begin (set! med-test #t)
               (set! med-due due)
               (set! med-due-total (length due))
               (set! med-due-done 0)
               (set! med-due-at at)
               (set! med-due-day (or (med-today) 0))
               (set! med-due-start (or (med-now-minutes) 0))
               (set! med-done-left 0)
               (set! med-blink #t)
               (med-led #t)
               (app-invalidate-all)
               #t))))

;; The reminder of time point at on day d (a new one, or one a restart cut short)
(define (med-remind! at d start)
  (if med-test (begin (set! med-test #f) (set! med-due '())))   ; a real one ends a test
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

;; One dose (med . amount) logged as how; a confirmed one ("ok") off a count
;; plan. The page's test logs nothing.
(define (med-take! x how)
  (let ((m (med-find (med-id (car x)))))
    (if (not med-test)
        (begin
          (log-add! med-due-day med-due-at (med-id (car x)) how (cdr x))
          (if (and m (string=? (med-plan m) "count") (string=? how "ok"))
              (begin (vector-set! m 6 (max 0 (- (med-units m) (cdr x))))
                     (med-save!)))))))

;; Back to the app that ran before; when this app is that one, its normal screen
(define (med-finish!)
  (set! med-test #f)
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
        (if (null? med-due) (begin (set! med-done-left MED-DONE-SECONDS) (med-led #f) (if (not med-test) (pending-clear!))))
        (app-invalidate-all))))

;; Every medicine left, logged as how ("miss": the time limit, "skip": ended on the web page)
(define (med-close-all! how)
  (for-each (lambda (x) (med-take! x how)) med-due)
  (med-finish!))

;; Past the time limit: back to the app before, the rest logged as missed (not taken)
(define (med-check-limit!)
  (let ((now (med-now-minutes)))
    (if (and (> med-max-minutes 0) now (pair? med-due) (>= (- now med-due-start) med-max-minutes))
        (med-close-all! "miss"))))

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
       (let* ((r (max 2 (quotient s 5)))
              (e (quotient (- s (* 2 r)) 2))
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
       (let ((r (quotient (* s 45) 100)) (d (quotient (* s 3) 10)))
         (if half
             (med-half-disk cx cy r color)
             (begin (gui-circle cx cy r color #t)
                    (gui-line (- cx d) (+ cy d) (+ cx d) (- cy d) shade)))))
      ((string=? shape "ball")                 ; a ball with a highlight
       (let ((r (quotient (* s 45) 100)))
         (if half (med-half-disk cx cy r color) (gui-circle cx cy r color #t))
         (gui-circle (- cx (quotient r 3)) (- cy (quotient r 3)) (max 1 (quotient r 4)) light #t)))
      ((string=? shape "oval")                 ; an oval tablet along the diagonal
       (med-oval cx cy (quotient (* s 6) 10) (quotient (* s 2) 10) color half))
      ((string=? shape "sachet")               ; a sachet, crimped at both ends
       (let* ((w (quotient (* s 6) 10)) (h (quotient (* s 95) 100)) (h (if half (quotient h 2) h))
              (x0 (- cx (quotient w 2))) (y0 (- (+ cy (quotient (* s 47) 100)) h)) (c (max 2 (quotient h 8))))
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
         (pct (cond ((member shape '("tablet" "ball")) 100)   ; round: side by side
                    ((string=? shape "sachet") 75)
                    (else 62)))                             ; tilted: the boxes overlap
         (span (lambda (sz) (+ sz (quotient (* (- n 1) sz pct) 100))))
         (s (if (and (not (string=? shape "none")) (> n 0) (<= a (* 10 MED-PILL-MAX)))
                (if (<= (span want) avail) want (quotient (* avail 100) (+ 100 (* (- n 1) pct))))
                0))
         (pills (>= s 12))
         (step (quotient (* s pct) 100))
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
    (txt-fit 10 (+ y 2) (- (scr-w) 30 (txt-w right))
             (if (and med-test (pair? med-due)) "测试，不记录" (next-text (med-next-dose m))) theme-text-sub)))

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
    (med-bold 200 (if med-test "测试完成" "已全部服用") theme-success 2)
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
        (sync-tick!)
        (if (and (= (remainder tick 60) 0) (not (eqv? (med-today) med-pruned-day))) (med-prune!))   ; a new day
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
  (if sync-job (sync-step!) (med-applib-step))
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
  (let ((hows (if d (log-hows d (slot-time s)) '())))
    (list (cons 'id (slot-id s)) (cons 'time (slot-time s))
          (cons 'entries (map (lambda (e)
                                (list (cons 'med (ent-med e)) (cons 'alt (ent-alt? e)) (cons 'ref (ent-ref e))
                                      (cons 'amount (ent-amount e))
                                      (cons 'today (ent-day? e d))
                                      (cons 'done (if (assv (ent-med e) hows) #t #f))
                                      (cons 'how (let ((h (assv (ent-med e) hows))) (if h (cdr h) "")))))
                              (slot-entries s))))))

(define (med-answer . extra)
  (let ((d (med-today)))
    (apply web-ok (append (list (cons 'today (or d 0)) (cons 'time app-time)
                                (cons 'meds (map (lambda (m) (med->alist m d)) med-list))
                                (cons 'slots (map (lambda (s) (slot->alist s d)) (slots-sorted)))
                                (cons 'max MED-MAX) (cons 'maxslots SLOT-MAX)
                                (cons 'reminding (med-reminding?)) (cons 'at med-due-at)
                                (cons 'settings (append (list (cons 'max_minutes med-max-minutes) (cons 'keep_days med-keep-days)
                                                              (cons 'sync (if (sync-on?) 1 0)))
                                                        (map (lambda (p) (cons (string->symbol (car p)) (cdr p))) med-scales)))
                                (cons 'sync (list (cons 'on (sync-on?)) (cons 'msg sync-msg) (cons 'busy (if sync-job #t #f))
                                                  (cons 'pending (sync-pending)) (cons 'server (app-proxy))
                                                  (cons 'downloading (if sync-get #t #f))
                                                  (cons 'oldest (let ((bs (log-buckets)))
                                                                  (if (pair? bs)
                                                                      (let ((rs (log-read (car bs))))
                                                                        (if (pair? rs) (med-least (map rec-day rs)) 0))
                                                                      0))))))
                          extra))))

;; Ids are never used again: records (here and on the server) name them
(define (med-next-id)
  (+ 1 (max (med-int (app-config "last_id" "0") 0)
            (let loop ((l med-list) (hi 0)) (if (null? l) hi (loop (cdr l) (max hi (med-id (car l))))))
            (let loop ((l (names-load)) (hi 0)) (if (null? l) hi (loop (cdr l) (max hi (car (car l)))))))))

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
             (if (not old) (app-config-set! "last_id" (number->string (med-id m))))
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
(define MED-SETTING-MINS '(("max_minutes" . 0) ("sync" . 0) ("keep_days" . 7)))
(define (med-save-settings! body)
  (let loop ((ks (append '(("max_minutes" "0" 1440) ("sync" "0" 1) ("keep_days" "1095" 3650)) MED-SCALE-KEYS)))
    (if (null? ks)
        (begin (med-load-settings!) (med-prune!) (sync-soon!) (app-invalidate-all) #t)
        (let* ((k (car ks)) (v (web-field body (car k))) (n (and v (string->number v)))
               (lo (let ((m (assoc (car k) MED-SETTING-MINS))) (if m (cdr m) 1))))
          (cond ((not v) (loop (cdr ks)))
                ((and (integer? n) (>= n lo) (<= n (caddr k))) (app-config-set! (car k) v) (loop (cdr ks)))
                (else (car k)))))))

;; Records newest first, 60 or more (whole files); before: only files older
;; than that one (the page's "更早"); more: the value for the next page
(define (rec-key r) (+ (* (rec-day r) 10000) (med-int (hm-wire (rec-time r)) 0)))

(define (rec-sort-new l)
  (let ins-all ((l l) (acc '()))
    (if (null? l)
        acc
        (ins-all (cdr l) (let ins ((x (car l)) (a acc))
                           (cond ((null? a) (list x)) ((> (rec-key x) (rec-key (car a))) (cons x a))
                                 (else (cons (car a) (ins x (cdr a))))))))))

(define (log-answer body)
  (let* ((before (web-field-int body "before" -1))
         (bs (reverse (filter (lambda (b) (or (< before 0) (< b before))) (log-buckets))))
         (names (names-load)))
    (let loop ((l bs) (acc '()) (last #f))
      (if (and (pair? l) (< (length acc) 60))
          (loop (cdr l) (append acc (rec-sort-new (log-read (car l)))) (car l))
          (web-ok (cons 'log (map (lambda (r)
                                    (let ((nm (name-of (rec-med r) names)))
                                      (list (cons 'day (rec-day r)) (cons 'time (rec-time r)) (cons 'med (rec-med r))
                                            (cons 'name (car nm))
                                            (cons 'amount (if (> (rec-amount r) 0) (string-append (amt-text (rec-amount r)) " " (cdr nm)) ""))
                                            (cons 'how (rec-how r)) (cons 'at (rec-at r)) (cons 'synced (rec-synced? r)))))
                                  acc))
                  (cons 'more (if (pair? l) last #f)))))))

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
    ((string=? name "log") (log-answer body))
    ((string=? name "edit")                         ; a record: taken (ok) or not (skip)
     (let ((r (log-edit! (web-field-int body "day" -1) (or (med-hm (or (web-field body "time") "")) "")
                         (web-field-int body "med" -1) (or (web-field body "how") ""))))
       (if (string? r) (web-error r) (med-answer))))
    ((string=? name "remind")                       ; the page's test: a time point's medicines now, nothing logged
     (let ((s (slot-at (or (med-hm (or (web-field body "time") "")) ""))))
       (cond ((not s) (web-error "没有这个时间点"))
             ((and (med-reminding?) (not med-test)) (web-error "设备正在提醒，全部确认后再测试"))
             (else (let ((r (med-test! (slot-time s)))) (if (string? r) (web-error r) (med-answer)))))))
    ((string=? name "sync")                         ; upload what is not on the server now
     (if (not (sync-on?))
         (web-error "请先勾选“同步到应用服务器”并保存设置")
         (begin (set! sync-wait 0) (set! sync-msg "正在同步…") (med-answer))))
    ((string=? name "download")                     ; the server's records of the last N days
     (let ((n (web-field-int body "days" 30)) (d (med-today)))
       (cond ((not d) (web-error "设备还没有对时，稍后再试"))
             ((or (< n 1) (> n 3650)) (web-error "天数应为 1..3650"))
             (sync-get (web-error "正在下载"))
             (else (set! sync-get (vector (- d n -1) 0 0 #f)) (set! sync-wait 0) (set! sync-msg "正在从应用服务器下载…")
                   (med-answer)))))
    ((string=? name "clear")                        ; local data: what=log or all
     (cond ((med-reminding?) (web-error "设备正在提醒，结束后再清空"))
           ((not (member (web-field body "what") '("log" "all"))) (web-error "what: log or all"))
           (else (med-clear! (string=? (web-field body "what") "all")) (med-answer))))
    ((string=? name "stop") (if (pair? med-due) (med-close-all! "skip") (if (med-reminding?) (med-finish!))) (med-answer))
    (else (web-error (string-append "unknown call: " name)))))

;; 10. Start ----------------------------------------------------------------------------

(med-migrate!)
(med-load!)
(med-load-settings!)
(sync-load!)
(log-migrate!)
(names-sync!)
(med-prune!)
(app-define! "吃药提醒" (list (app-local-page "药品" (lambda (items) #t))))
(set! gui-render-proc med-render)
(let ((at (app-scheduled))) (if at (med-start! at) (med-resume!)))
(app-invalidate-all)
