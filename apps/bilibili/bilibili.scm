;;; =========================================================================
;;; bilibili: B站热门视频, multi-list dashboard, 320x480 portrait, on the app
;;; framework. Several independent lists (小分类: a category, a ranking
;;; partition, or a chosen UP主's newest videos), added, removed and
;;; reordered from the app's web page; each list can page through its own
;;; videos, or not (then it just shows its first few). One applib page
;;; (section 6.5's "several lists, each with its own screens"): the app
;;; keeps the lists and their screens itself, since the user adds and
;;; removes lists at run time and applib's own pages are fixed at
;;; app-define!.
;;;
;;; Only the list on screen keeps its videos and covers in memory (VM heap)
;;; and on the board's storage: switching to a different list drops the one
;;; just left and re-fetches, rather than caching every list ever shown
;;; (6.5 allows either; this one costs much less resident memory, which
;;; matters more with up to BILIBILI-MAX-LISTS lists). Each list's screen
;;; position is still remembered (a single integer per list, negligible).
;;;
;;; Screens turn by themselves, each for its list's seconds: through the
;;; list on screen, or through every list (auto_switch); the header shows
;;; the countdown and the position ("1/10") like other carousel apps. A mid
;;; press stops and starts the turning; while it runs a short or long press
;;; switches between the two cycles; while stopped a short press goes to the
;;; next screen (the next list after the last one), a long press back.
;;;
;;; Every setting (the lists themselves - type, ranking partition or UP主,
;;; whether a list pages at all, how many videos and how many per screen,
;;; its seconds per screen - and auto_switch) lives in the app's own web page and takes
;;; effect at once, no restart (section 13). The web page returns the
;;; lists' own small configuration, never their videos: that would mean
;;; building and returning up to BILIBILI-MAX-TOTAL items per list on every
;;; call, for a page whose job is only picking what to show.
;;;
;;; Data: the app proxy's /app/bilibili (cat=popular|weekly|precious|rank|up,
;;; rid=<partition> for rank, up=<uid/link/name> for up, n=<count>) ->
;;; {"items":[{"t":"v","a":title,"b":aid,"c":views}, ...]}. Covers: /app/
;;; bilibili/pic?id=<aid>&w=&h=, one small baseline JPEG per video,
;;; downloaded one at a time into cache/ (fs-download, section 11.7),
;;; named by both the id and the box size (so a list switch that also
;;; changes the box size never draws a stale cover at the wrong size);
;;; kept as one LRU cache for all lists (section 6).
;;; Titles reach the screen as the server sends them (api = 1.11: the font
;;; server fills any glyph the board's own fonts lack, section 9).
;;; Every global name starts with "bilibili-": all files share one namespace.
;;; =========================================================================

;; 1. Limits: how many lists, and how many videos each may ask for -------------------------------
;; Each list is its own document (~4 KB of values, section 11.3) and, while shown, its own cover
;; files (a few KB each, 11.7). Only the list on screen keeps its videos, so the VM heap stays
;; close to what a single such app would use; the covers of all lists share one cache whose size
;; follows these limits (section 6). The limits also keep one list's document and screens sane. See
;; the guide's own "cap the number of lists and of entries per list" (6.5).

(define BILIBILI-MAX-LISTS 6)        ; at most this many lists at once
(define BILIBILI-MIN-TOTAL 1)        ; a list's video count: fewest it may fetch / show
(define BILIBILI-MAX-TOTAL 15)       ; ... and the most
(define BILIBILI-MIN-PAGE 3)         ; a paging list's videos per screen: fewest
(define BILIBILI-MAX-PAGE 10)        ; ... and the most
(define BILIBILI-MIN-SECS 3)         ; a list's seconds per screen when pages turn by themselves
(define BILIBILI-MAX-SECS 600)
(define BILIBILI-DEFAULT-SECS 10)
(define BILIBILI-DIR "cache")        ; covers live in the app's own cache/ subfolder
(define BILIBILI-INTERVAL 300000)    ; ms between re-fetches of the list on screen (proxy caches too)
(define BILIBILI-CATEGORIES '("popular" "weekly" "precious" "rank" "up"))
(define BILIBILI-DEFAULT-LISTS "popular::1:10:5:10|precious::1:10:5:10")   ; shipped default: two lists

;; The top-level content zones /app/bilibili?cat=rank accepts (must match
;; proxy/bilibili.py's PARTITIONS so the label shown matches the data asked for).
(define BILIBILI-PARTITIONS
  (list (cons "0" "全站") (cons "1" "动画") (cons "3" "音乐") (cons "4" "游戏") (cons "5" "娱乐")
        (cons "36" "知识") (cons "119" "鬼畜") (cons "129" "舞蹈") (cons "155" "时尚") (cons "160" "生活")
        (cons "168" "国创相关") (cons "177" "纪录片") (cons "181" "影视") (cons "188" "科技")
        (cons "211" "美食") (cons "217" "动物圈") (cons "223" "汽车") (cons "234" "运动")))

;; 2. Lists: parsed from one config string, encoded back the same way ----------------------------
;; One list: #(cat param paginate total page secs). param is the ranking partition's rid, or the UP主
;; text the user typed (percent-decoded already); "" for popular/weekly/precious. paginate is 1
;; when the list turns its own screens, 0 when it only ever shows its first "total" videos on one
;; screen (page is kept but unused then, so toggling paginate back on remembers it). secs: how long
;; each of its screens shows when pages turn by themselves (section 8). Encoded as
;; "cat:param:paginate:total:page:secs", lists joined by "|" (secs may be missing: the settings of
;; an older version); param is percent-encoded first (it may
;; hold any character, including "|" and ":", so it never reaches the parser literally).

(define (bilibili-encode-list v)
  (string-append (vector-ref v 0) ":" (url-encode (vector-ref v 1)) ":" (int->str (vector-ref v 2)) ":"
                 (int->str (vector-ref v 3)) ":" (int->str (vector-ref v 4)) ":" (int->str (vector-ref v 5))))

(define (bilibili-encode-lists v) (web-join (map bilibili-encode-list (vector->list v)) "|"))

;; Settings of an older version: one auto_advance (seconds between lists, 0 off) for all lists
(define bilibili-legacy-advance (or (string->fixed (app-config "auto_advance" "0") 0) 0))
(define bilibili-legacy-secs (if (> bilibili-legacy-advance 0) bilibili-legacy-advance BILIBILI-DEFAULT-SECS))

(define (bilibili-decode-list s)
  (let ((f (str-split s #\:)))
    (if (>= (length f) 5)
        (vector (if (member (car f) BILIBILI-CATEGORIES) (car f) "popular")
                (web-decode (cadr f))
                (if (equal? (caddr f) "1") 1 0)
                (clamp (or (string->fixed (list-ref f 3) 0) 10) BILIBILI-MIN-TOTAL BILIBILI-MAX-TOTAL)
                (clamp (or (string->fixed (list-ref f 4) 0) 5) BILIBILI-MIN-PAGE BILIBILI-MAX-PAGE)
                (clamp (or (and (>= (length f) 6) (string->fixed (list-ref f 5) 0)) bilibili-legacy-secs)
                       BILIBILI-MIN-SECS BILIBILI-MAX-SECS))
        #f)))

;; Malformed entries are dropped; an empty or all-malformed string falls back to the default so
;; the app is never left with zero lists (every piece of this app assumes at least one).
(define (bilibili-parse-lists s)
  (let ((v (filter (lambda (x) x) (map bilibili-decode-list (str-split s #\|)))))
    (if (pair? v)
        (take v (min (length v) BILIBILI-MAX-LISTS))
        (filter (lambda (x) x) (map bilibili-decode-list (str-split BILIBILI-DEFAULT-LISTS #\|))))))

;; 3. Settings: read once at the start; bilibili-apply-lists! changes them live ------------------

(define bilibili-lists (list->vector (bilibili-parse-lists (app-config "sections" BILIBILI-DEFAULT-LISTS))))
;; auto_switch: the pages turning by themselves go on through every list (else they stay in the
;; list on screen); the older auto_advance > 0 meant that too
(define bilibili-auto-switch
  (equal? (app-config "auto_switch" (if (> bilibili-legacy-advance 0) "1" "0")) "1"))
(define bilibili-current 0)          ; which list is on screen

(define (bilibili-paginate? i) (= (vector-ref (vector-ref bilibili-lists i) 2) 1))
(define (bilibili-fetch-n i) (vector-ref (vector-ref bilibili-lists i) 3))         ; videos to fetch / show
(define (bilibili-list-secs i) (vector-ref (vector-ref bilibili-lists i) 5))       ; seconds per screen
(define (bilibili-effective-page-size i)                                          ; videos per screen
  (if (bilibili-paginate? i) (vector-ref (vector-ref bilibili-lists i) 4) (bilibili-fetch-n i)))

;; Only the list on screen keeps its videos (bilibili-items) and label (bilibili-meta): dropped
;; the moment the user moves to a different list (section 1). Its screen position is kept per
;; list regardless (bilibili-screen, bilibili-screen-n: two small integers, not the videos).
(define bilibili-items (vector))     ; the list on screen's latest document's videos
(define bilibili-loaded #f)          ; a document of the list on screen came (empty: "暂无数据")
(define bilibili-meta "")            ; its resolved label (weekly's theme, the UP主's name)
(define bilibili-screen (vector))    ; one remembered screen index per list
(define bilibili-screen-n (vector))  ; one remembered screen count per list (1 until first fetched)

(define (bilibili-reset-runtime!)
  (let ((n (vector-length bilibili-lists)))
    (set! bilibili-items (vector))
    (set! bilibili-loaded #f)
    (set! bilibili-meta "")
    (set! bilibili-screen (make-vector n 0))
    (set! bilibili-screen-n (make-vector n 1))
    (let loop ((i 0))                ; until a list is fetched: the screens its settings ask for
      (if (< i n)
          (begin
            (vector-set! bilibili-screen-n i
                         (if (bilibili-paginate? i)
                             (quotient (+ (bilibili-fetch-n i) (bilibili-effective-page-size i) -1)
                                       (bilibili-effective-page-size i))
                             1))
            (loop (+ i 1)))))))

(bilibili-reset-runtime!)

;; The list on screen's count is exact (from its own just-fetched bilibili-items); any other
;; list's is whatever bilibili-screen-n last remembered for it (its own last visit, or 1 if never).
(define (bilibili-screen-count i)
  (if (= i bilibili-current)
      (max 1 (quotient (+ (vector-length bilibili-items) (bilibili-effective-page-size i) -1)
                       (bilibili-effective-page-size i)))
      (vector-ref bilibili-screen-n i)))

(define (bilibili-cat-label cat)
  (cond ((string=? cat "popular") "综合热门")
        ((string=? cat "weekly") "每周必看")
        ((string=? cat "precious") "入站必刷")
        ((string=? cat "rank") "排行榜")
        ((string=? cat "up") "UP主")
        (else "热门")))

(define (bilibili-partition-label rid)
  (let ((p (assoc rid BILIBILI-PARTITIONS))) (if p (cdr p) "全站")))

(define (bilibili-list-label i)
  (let* ((cfg (vector-ref bilibili-lists i)) (cat (vector-ref cfg 0)) (param (vector-ref cfg 1))
         (meta (if (= i bilibili-current) bilibili-meta "")))
    (cond ((string=? cat "rank") (string-append "排行榜·" (bilibili-partition-label param)))
          ((and (string=? cat "up") (not (str-empty? meta))) (string-append "UP主·" meta))
          ((and (string=? cat "weekly") (not (str-empty? meta))) (string-append "每周必看·" meta))
          (else (bilibili-cat-label cat)))))

;; 4. Layout: a 16:9 cover that shrinks as more videos share a screen, matching the list on -------
;; screen's own per-screen count; a pure function of it, so it can be computed for any list (the
;; file-cleanup sweep, 6) without disturbing the list actually on screen.

(define BILIBILI-RANK-X 10)
(define BILIBILI-RANK-W 24)
(define BILIBILI-COVER-X (+ BILIBILI-RANK-X BILIBILI-RANK-W 6))
(define bilibili-row-h 0)
(define bilibili-cover-h 0)
(define bilibili-cover-w 0)
(define BILIBILI-TITLE-X 0)

;; The cover's own cap is 56 px tall (not the body's full row height): a smaller baseline JPEG
;; downloads into a smaller buffer and decodes faster, which matters more with several lists
;; than one hero-sized cover would be worth (16, system heap).
(define (bilibili-cover-dims page-size)
  (let* ((row-h (quotient (- (body-bottom) (body-top)) page-size)) (cov-h (clamp (- row-h 14) 28 56)))
    (cons (quotient (* cov-h 16) 9) cov-h)))

(define (bilibili-recompute-layout!)
  (let* ((ps (bilibili-effective-page-size bilibili-current)) (dims (bilibili-cover-dims ps)))
    (set! bilibili-row-h (quotient (- (body-bottom) (body-top)) ps))
    (set! bilibili-cover-w (car dims))
    (set! bilibili-cover-h (cdr dims))
    (set! BILIBILI-TITLE-X (+ BILIBILI-COVER-X bilibili-cover-w 8))))

(bilibili-recompute-layout!)

;; 5. Talking to the server: one proxy page, its URL rebuilt for whichever list is on screen -----

(define (bilibili-list-url i)
  (let* ((cfg (vector-ref bilibili-lists i)) (cat (vector-ref cfg 0)) (param (vector-ref cfg 1)))
    (app-url (string-append "/app/bilibili?cat=" cat "&n=" (int->str (bilibili-fetch-n i))
                             (cond ((string=? cat "rank") (string-append "&rid=" param))
                                   ((string=? cat "up") (string-append "&up=" (url-encode param)))
                                   (else ""))))))

(define (bilibili-pic-path aid w h) (string-append BILIBILI-DIR "/p" aid "_" (int->str w) "x" (int->str h) ".jpg"))
(define (bilibili-pic-url aid w h)
  (app-url (string-append "/app/bilibili/pic?id=" aid "&w=" (int->str w) "&h=" (int->str h))))

;; 6. Cover pictures: downloaded one at a time for the screen on display (11.7), kept in cache/ as
;; one LRU cache shared by every list. Switching lists (by hand or auto_advance) then shows covers
;; already on disk instead of deleting and downloading them again: every download is a flash
;; write. The cache holds twice as many covers as all lists name together (at most
;; BILIBILI-CACHE-MAX, ~3 KB each against the app's quota); on the flash a cover takes a whole 4 KB
;; block, and the cache never leaves the file system less than BILIBILI-FS-RESERVE free.

(define BILIBILI-CACHE-MAX 100)      ; covers at most (storage_kb 512 holds them with the app image)
(define BILIBILI-FS-RESERVE 131072)  ; bytes of the file system the cache always leaves free
(define BILIBILI-BLOCK 4096)         ; flash one cover takes (a LittleFS block)

(define bilibili-ready '())          ; cover paths on disk for the list on screen (what render draws)
(define bilibili-lru '())            ; every cover path on disk, most recently shown first
(define bilibili-lru-n 0)            ; (length bilibili-lru)
(define bilibili-room 0)             ; covers that still fit above the reserve (counted down; fs-info when low)
(define bilibili-dl-queue '())       ; (aid w h) triples waiting to download
(define bilibili-dl-current #f)      ; the (aid w h) triple downloading now, or #f

(define (bilibili-cover-ready? path) (and (member path bilibili-ready) #t))

(define (bilibili-cache-cap)
  (let loop ((i 0) (n 0))
    (if (< i (vector-length bilibili-lists))
        (loop (+ i 1) (+ n (bilibili-fetch-n i)))
        (min BILIBILI-CACHE-MAX (* 2 n)))))

(define (bilibili-room-update!)
  (let ((info (fs-info)))
    (set! bilibili-room (quotient (- (car info) (cadr info) BILIBILI-FS-RESERVE) BILIBILI-BLOCK))))

(define (bilibili-list-without l x)
  (cond ((null? l) '()) ((equal? (car l) x) (cdr l)) (else (cons (car l) (bilibili-list-without (cdr l) x)))))

;; A cover shown or just downloaded goes to the front
(define (bilibili-lru-touch! path)
  (cond ((and (pair? bilibili-lru) (equal? (car bilibili-lru) path)) #f)
        ((member path bilibili-lru) (set! bilibili-lru (cons path (bilibili-list-without bilibili-lru path))))
        (else (set! bilibili-lru (cons path bilibili-lru)) (set! bilibili-lru-n (+ bilibili-lru-n 1)))))

;; Deletes the least recently shown covers until n remain. The screen on display was touched
;; last, so it is never among them while n is at least one screen.
(define (bilibili-lru-trim! n)
  (if (> bilibili-lru-n n)
      (let ((gone (list-tail bilibili-lru n)))
        (set! bilibili-lru (take bilibili-lru n))
        (set! bilibili-lru-n n)
        (set! bilibili-room (+ bilibili-room (length gone)))
        (for-each (lambda (path)
                    (fs-remove path)
                    (set! bilibili-ready (bilibili-list-without bilibili-ready path)))
                  gone))))

;; At the start: the covers already on disk (from before a restart) join the cache, all as least
;; recently shown; what an interrupted download left behind (not a .jpg) is deleted.
(define (bilibili-cache-load!)
  (for-each (lambda (entry)
              (let* ((name (car entry)) (n (string-length name)) (path (string-append BILIBILI-DIR "/" name)))
                (if (and (str-starts? name "p") (> n 4) (string=? (substring name (- n 4) n) ".jpg"))
                    (begin (set! bilibili-lru (cons path bilibili-lru)) (set! bilibili-lru-n (+ bilibili-lru-n 1)))
                    (fs-remove path))))
            (fs-list BILIBILI-DIR))
  (bilibili-room-update!)
  (bilibili-lru-trim! (bilibili-cache-cap)))

(define (bilibili-want? aid w h)
  (and (> (string-length aid) 0)
       (not (bilibili-cover-ready? (bilibili-pic-path aid w h)))
       (not (equal? (list aid w h) bilibili-dl-current))
       (not (member (list aid w h) bilibili-dl-queue))))

;; Queue the covers of the screen now on display (the ones on disk count as shown): starts from an
;; empty queue every time, so a screen or list change never waits behind covers for a screen the
;; user has already left.
(define (bilibili-queue-active-screen!)
  (set! bilibili-dl-queue '())
  (let* ((ps (bilibili-effective-page-size bilibili-current)) (scr (vector-ref bilibili-screen bilibili-current))
         (base (* scr ps)) (total (vector-length bilibili-items)) (w bilibili-cover-w) (h bilibili-cover-h))
    (let loop ((k (- ps 1)))         ; the top row last: it ends up most recently shown
      (if (>= k 0)
          (begin
            (if (< (+ base k) total)
                (let* ((aid (it-b (vector-ref bilibili-items (+ base k)))) (path (bilibili-pic-path aid w h)))
                  (cond ((bilibili-cover-ready? path) (bilibili-lru-touch! path))
                        ((bilibili-want? aid w h) (set! bilibili-dl-queue (cons (list aid w h) bilibili-dl-queue))))))
            (loop (- k 1)))))))

;; Redraw only the row whose cover arrived: the whole body would decode every cover again, and the
;; next download's on-done waits for that redraw
(define (bilibili-invalidate-cover! aid)
  (let* ((ps (bilibili-effective-page-size bilibili-current))
         (base (* (vector-ref bilibili-screen bilibili-current) ps))
         (total (vector-length bilibili-items)))
    (let loop ((k 0))
      (if (and (< k ps) (< (+ base k) total))
          (if (equal? (it-b (vector-ref bilibili-items (+ base k))) aid)
              (gui-invalidate 0 (+ (body-top) (* k bilibili-row-h)) (scr-w) bilibili-row-h)
              (loop (+ k 1)))))))

;; One fs-download in flight at a time; called when a download ends (its on-done, below) and
;; every tick (the fallback on firmware before API 1.12, which ignores on-done). An
;; in-flight download cannot be cancelled when the queue is reset above; it still finishes and
;; joins the cache (it is simply not on screen any more by the time it lands).
(define (bilibili-dl-step!)
  (if bilibili-dl-current
      (let ((state (cdr (assq 'state (fs-download-status)))))
        (cond ((eq? state 'done)
               (let ((path (bilibili-pic-path (car bilibili-dl-current) (cadr bilibili-dl-current) (caddr bilibili-dl-current))))
                 (if (not (member path bilibili-lru)) (set! bilibili-room (- bilibili-room 1)))
                 (bilibili-lru-touch! path)
                 (if (equal? (cdr bilibili-dl-current) (list bilibili-cover-w bilibili-cover-h))
                     (set! bilibili-ready (cons path bilibili-ready)))
                 (bilibili-lru-trim! (bilibili-cache-cap))
                 (bilibili-invalidate-cover! (car bilibili-dl-current))
                 (set! bilibili-dl-current #f)))
              ((eq? state 'error) (set! bilibili-dl-current #f))
              (else #f)))   ; idle, queued or running: wait
      (if (pair? bilibili-dl-queue)
          (let* ((job (car bilibili-dl-queue)) (aid (car job)) (w (cadr job)) (h (caddr job)))
            ;; no room above the reserve: the least recently shown cover makes way (never the
            ;; screen on display); none to spare: the placeholders stay
            (if (and (<= bilibili-room 0) (> bilibili-lru-n (bilibili-effective-page-size bilibili-current)))
                (bilibili-lru-trim! (- bilibili-lru-n 1)))
            (if (<= bilibili-room 0)
                (set! bilibili-dl-queue '())
                (begin
                  (set! bilibili-dl-queue (cdr bilibili-dl-queue))
                  (if (fs-download (bilibili-pic-url aid w h) (bilibili-pic-path aid w h) bilibili-dl-done)
                      (set! bilibili-dl-current job)
                      (set! bilibili-dl-queue (append bilibili-dl-queue (list job)))))))))) ; busy: retry later

;; The list on screen's current videos, at its own cover size: those already in the cache are
;; ready at once (a list switched back to shows its covers without a download).
(define (bilibili-keep-paths)
  (let ((dims (bilibili-cover-dims (bilibili-effective-page-size bilibili-current))))
    (let loop ((k 0) (acc '()))
      (if (< k (vector-length bilibili-items))
          (loop (+ k 1) (cons (bilibili-pic-path (it-b (vector-ref bilibili-items k)) (car dims) (cdr dims)) acc))
          acc))))

(define (bilibili-rebuild-ready!)
  (set! bilibili-ready (filter (lambda (path) (member path bilibili-lru)) (bilibili-keep-paths))))

;; The lists changed (a web settings edit): the covers stay in the cache, trimmed to the new size;
;; the in-flight download still lands (bilibili-dl-step!)
(define (bilibili-reset-covers!)
  (set! bilibili-ready '())
  (set! bilibili-dl-queue '())
  (bilibili-lru-trim! (bilibili-cache-cap)))

(bilibili-cache-load!)

;; 7. New document arrives: rebuild the view once, not in render (section 16); ignored if the --
;; user has already moved to a different list while it was in flight (nothing to update any more).

;; A document of the list on screen: the fresh one from the feed, or the one applib still keeps in
;; memory for it (bilibili-switch-list!: shown at once, replaced when the fresh one comes)
(define (bilibili-take-items! items)
  (let ((i bilibili-current))
        (set! bilibili-loaded #t)
        (set! bilibili-items (list->vector (items-all items "v")))
        (let ((meta (items-find items "meta"))) (set! bilibili-meta (if meta (it-a meta) "")))
        (vector-set! bilibili-screen-n i (bilibili-screen-count i))
        (vector-set! bilibili-screen i (clamp (vector-ref bilibili-screen i) 0 (- (vector-ref bilibili-screen-n i) 1)))
        (if (< bilibili-room 16) (bilibili-room-update!))   ; fs-info takes ~0.25 s on the board
        (bilibili-rebuild-ready!)
        (bilibili-queue-active-screen!)
        (app-invalidate-all)))

(define (bilibili-on-data! items)
  (if (equal? (json-feed-url) (bilibili-list-url bilibili-current)) (bilibili-take-items! items)))

(set! app-data-proc bilibili-on-data!)

;; "暂无数据" only when it is known: the server sent the list without videos, or it could not be
;; fetched (no proxy, an error object for it, the feed failing). While it loads the body is blank.
(define (bilibili-no-data?)
  (or bilibili-loaded
      (eq? app-error APP-NO-PROXY)
      (and app-error (equal? app-error-url (bilibili-list-url bilibili-current)))
      (eq? (app-status 'state) 'error)))

;; 8. Navigation: short press next screen, long press previous; both cross list boundaries -------
;; at the ends (6.5: "the last screen of a list goes on to the next list"), wrapping around.
;; Pages also turn by themselves (below): any move restarts the countdown.

;; Turning by itself: running (a mid press stops and starts it), going through the list on screen
;; or through every list (auto_switch; a short or long press while running switches the two).
(define bilibili-auto-running #t)
(define bilibili-cycle-all bilibili-auto-switch)
(define bilibili-auto-left 0)        ; seconds left on this screen

(define (bilibili-auto-reset!) (set! bilibili-auto-left (bilibili-list-secs bilibili-current)))
(define (bilibili-cycle-all?) (and bilibili-cycle-all (> (vector-length bilibili-lists) 1)))

(define (bilibili-after-nav!)
  (bilibili-auto-reset!)
  (bilibili-queue-active-screen!)
  (app-invalidate-all))

;; Switches to list i (wrapped), landing on screen land (clamped to that list's own remembered
;; range); only a list switch re-fetches, may resize the layout and drops the videos and covers
;; of the list just left (section 1), never a same-list screen move.
(define (bilibili-switch-list! i land)
  (let ((j (remainder (+ i (vector-length bilibili-lists)) (vector-length bilibili-lists))))
    (set! bilibili-current j)
    (vector-set! bilibili-screen j (clamp land 0 (- (vector-ref bilibili-screen-n j) 1)))
    (set! bilibili-items (vector))
    (set! bilibili-loaded #f)
    (set! bilibili-meta "")
    (set! bilibili-ready '())
    (bilibili-recompute-layout!)
    (let ((e (app-cache-entry (bilibili-list-url j))))   ; seen recently: shown now, refreshed below
      (if e (bilibili-take-items! (vector-ref e 1))))
    (app-set-url! 0 (bilibili-list-url j))
    (bilibili-after-nav!)))

(define (bilibili-next!)
  (let* ((i bilibili-current) (scr (vector-ref bilibili-screen i)) (n (bilibili-screen-count i)))
    (if (< (+ scr 1) n)
        (begin (vector-set! bilibili-screen i (+ scr 1)) (bilibili-after-nav!))
        (bilibili-switch-list! (+ i 1) 0))))

(define (bilibili-prev!)
  (let* ((i bilibili-current) (scr (vector-ref bilibili-screen i)))
    (if (> scr 0)
        (begin (vector-set! bilibili-screen i (- scr 1)) (bilibili-after-nav!))
        (bilibili-switch-list! (- i 1) 9999))))   ; land on the previous list's last remembered screen

;; One turn by itself: the list's next screen if it turns its screens; after its last one the next
;; list (every list) or its first screen again (the list on screen)
(define (bilibili-auto-step!)
  (let* ((i bilibili-current) (scr (vector-ref bilibili-screen i)))
    (cond ((and (bilibili-paginate? i) (< (+ scr 1) (bilibili-screen-count i)))
           (vector-set! bilibili-screen i (+ scr 1))
           (bilibili-after-nav!))
          ((bilibili-cycle-all?) (bilibili-switch-list! (+ i 1) 0))
          ((> scr 0) (vector-set! bilibili-screen i 0) (bilibili-after-nav!))
          (else (bilibili-auto-reset!) (gui-invalidate 0 0 (scr-w) HDR-H)))))   ; one screen: it stays

;; Running: a press switches between the list on screen and every list; stopped: it turns screens
(define (bilibili-toggle-cycle!)
  (set! bilibili-cycle-all (not bilibili-cycle-all))
  (bilibili-auto-reset!)
  (app-invalidate-all))

(define (app-button) (if bilibili-auto-running (bilibili-toggle-cycle!) (bilibili-next!)))
(define (app-long-press) (if bilibili-auto-running (bilibili-toggle-cycle!) (bilibili-prev!)))
(define (app-mid-press)
  (set! bilibili-auto-running (not bilibili-auto-running))
  (bilibili-auto-reset!)
  (app-invalidate-all))

;; The firmware calls it the moment a download ended: the cover is drawn and the next one starts
;; at once (stepping only from the tick made each cover wait up to a second: five took 5..10 s).
;; Twice: the first records the outcome, the second starts the next download.
(define (bilibili-dl-done ok path)
  (bilibili-dl-step!)
  (bilibili-dl-step!))

(define (bilibili-tick! tick)
  (bilibili-dl-step!)
  (if (and bilibili-auto-running (not (info-active?)))
      (begin
        (set! bilibili-auto-left (- bilibili-auto-left 1))
        (if (<= bilibili-auto-left 0)
            (bilibili-auto-step!)
            (gui-invalidate 0 0 (scr-w) HDR-H)))))   ; the countdown

(set! app-tick-proc bilibili-tick!)

;; 9. Header ---------------------------------------------------------------------------------------
;; The header as in other apps whose pages turn by themselves: the title and the list's name, then
;; the countdown bar and the position in the turning ("1/2" through the list on screen, "1/10"
;; through every list, where a list without screens of its own counts once) left of the clock.

(define (bilibili-list-screens i) (if (bilibili-paginate? i) (max 1 (bilibili-screen-count i)) 1))

;; (position . count) of the screen on display in the turning
(define (bilibili-cycle-pos)
  (let* ((i bilibili-current) (here (if (bilibili-paginate? i) (+ (vector-ref bilibili-screen i) 1) 1)))
    (if (bilibili-cycle-all?)
        (let loop ((j 0) (before 0) (total 0))
          (if (< j (vector-length bilibili-lists))
              (loop (+ j 1) (if (< j i) (+ before (bilibili-list-screens j)) before) (+ total (bilibili-list-screens j)))
              (cons (+ before here) total)))
        (cons here (bilibili-list-screens i)))))

;; The countdown, right-aligned at xr (applib's bar): a faint track and what is left; one even bar
;; while stopped
(define (bilibili-render-countdown xr secs)
  (let* ((full (carousel-bar-w secs))
         (left (min full (* (max 0 bilibili-auto-left) (carousel-px secs))))
         (y (quotient (- HDR-H CAROUSEL-BAR-H) 2)))
    (gui-rect (- xr full) y full CAROUSEL-BAR-H (if bilibili-auto-running theme-dark-gray theme-divider) #t)
    (if (and bilibili-auto-running (> left 0))
        (gui-rect (- xr left) y left CAROUSEL-BAR-H CAROUSEL-BAR-COLOR #t))))

;; app-header-proc: [x, x + w) is the header left of the clock (applib keeps 8 px more before it)
(define (bilibili-header items x w)
  (let* ((right (+ x w 6))
         (pos (bilibili-cycle-pos))
         (ind (string-append (int->str (car pos)) "/" (int->str (cdr pos))))
         (iw (+ (txt-w ind) 12))
         (bx (- right iw))
         (secs (bilibili-list-secs bilibili-current))
         (bar-r (- bx 6))
         (text-r (- bar-r (carousel-bar-w secs) 8))
         (sub (bilibili-list-label bilibili-current))
         (tw (txt-w app-title)))
    (gui-round-rect bx 5 iw 22 6 theme-accent-dark #t)
    (txt (+ bx 6) 8 ind theme-accent)
    (bilibili-render-countdown bar-r secs)
    (txt-fit x 8 (- text-r x) app-title theme-text-main)
    (if (< (+ x tw 10) (- text-r 20))
        (txt-fit (+ x tw 10) 8 (- text-r x tw 10) sub theme-accent))))

(set! app-header-proc bilibili-header)

;; A combined app (合集) draws its own header: the list's name after the title there
(define (bilibili-subtitle items) (bilibili-list-label bilibili-current))
(set! app-subtitle-proc bilibili-subtitle)

;; 10. Render: only the list and screen on display, covers already on disk or a placeholder box --

(define (bilibili-draw-rank x y n)
  (txt (+ x 2) (+ y (quotient (- bilibili-row-h 18) 2)) (int->str n) theme-text-sub))

;; The title is one line that scrolls to show all of it (txt-fit, config.ini [text] marquee -
;; "pixel" by default): since firmware v1.0.79 a moving box replays one recording of the screen
;; instead of re-running render every step, so this costs about what static text does (section
;; 9). Never gui-text-wrap here: a wrapped title stops at "…" and never shows the rest.
;; Beside the cover, as the row's height allows: title, @UP主, plays on three lines (rows of 60
;; px and more: 3..6 videos a screen); title, then @UP主 and the plays on the right (41..59 px:
;; 7..10 a screen); the title alone.
(define (bilibili-render-row items idx y)
  (let* ((it (vector-ref items idx)) (aid (it-b it))
         (cov-y (+ y (quotient (- bilibili-row-h bilibili-cover-h) 2)))
         (x BILIBILI-TITLE-X)
         (w (- (scr-w) x 10))
         (lines (cond ((>= bilibili-row-h 60) 3) ((>= bilibili-row-h 40) 2) (else 1)))
         (y0 (+ y (max 0 (quotient (- bilibili-row-h (* lines LINE-H)) 2))))
         (up (if (str-empty? (it-d it)) "" (string-append "@" (it-d it))))
         (views (if (str-empty? (it-c it)) "" (string-append "播放 " (it-c it)))))
    (bilibili-draw-rank BILIBILI-RANK-X y (+ idx 1))
    (if (bilibili-cover-ready? (bilibili-pic-path aid bilibili-cover-w bilibili-cover-h))
        (gui-image BILIBILI-COVER-X cov-y (bilibili-pic-path aid bilibili-cover-w bilibili-cover-h))
        (gui-round-rect BILIBILI-COVER-X cov-y bilibili-cover-w bilibili-cover-h 4 theme-card-hdr #t))
    (txt-fit x y0 w (it-a it) theme-text-main)
    (cond ((= lines 3)
           (txt-fit x (+ y0 LINE-H) w up theme-text-sub)
           (txt x (+ y0 (* 2 LINE-H)) views theme-text-muted))
          ((= lines 2)   ; the plays stay put on the right, a long name scrolls in what is left
           (let ((vw (txt-w views)))
             (txt-right (+ x w) (+ y0 LINE-H) views theme-text-muted)
             (txt-fit x (+ y0 LINE-H) (- w vw 10) up theme-text-sub))))
    (gui-line BILIBILI-RANK-X (+ y bilibili-row-h -1) (- (scr-w) 10) (+ y bilibili-row-h -1) theme-divider)))

(define (bilibili-render items)
  (let* ((ps (bilibili-effective-page-size bilibili-current))
         (total (vector-length bilibili-items)) (base (* (vector-ref bilibili-screen bilibili-current) ps)))
    (if (= total 0)
        (if (bilibili-no-data?) (txt 14 (+ (body-top) 30) "暂无数据" theme-text-muted))   ; loading: blank
        (let loop ((k 0))
          (if (< k ps)
              (begin
                (if (< (+ base k) total) (bilibili-render-row bilibili-items (+ base k) (+ (body-top) (* k bilibili-row-h))))
                (loop (+ k 1))))))))

;; 11. The app's own web page: the lists themselves, added/removed/reordered, every setting -------
;; taking effect at once, no restart (section 13).

(define (bilibili-web-state)
  (web-ok (cons 'lists (list->vector
                         (map (lambda (cfg) (list (cons 'cat (vector-ref cfg 0)) (cons 'param (vector-ref cfg 1))
                                                  (cons 'paginate (vector-ref cfg 2)) (cons 'total (vector-ref cfg 3))
                                                  (cons 'page (vector-ref cfg 4)) (cons 'secs (vector-ref cfg 5))))
                              (vector->list bilibili-lists))))
          (cons 'auto_switch (if bilibili-auto-switch 1 0))
          (cons 'min_secs BILIBILI-MIN-SECS) (cons 'max_secs BILIBILI-MAX-SECS)
          (cons 'max_lists BILIBILI-MAX-LISTS)
          (cons 'min_total BILIBILI-MIN-TOTAL) (cons 'max_total BILIBILI-MAX-TOTAL)
          (cons 'min_page BILIBILI-MIN-PAGE) (cons 'max_page BILIBILI-MAX-PAGE)))

(define (bilibili-apply-lists! encoded switch)
  (set! bilibili-lists (list->vector (bilibili-parse-lists encoded)))
  (set! bilibili-auto-switch switch)
  (set! bilibili-cycle-all switch)
  (app-config-set! "sections" (bilibili-encode-lists bilibili-lists))
  (app-config-set! "auto_switch" (if switch "1" "0"))
  (bilibili-reset-runtime!)
  (set! bilibili-current 0)
  (bilibili-recompute-layout!)
  (bilibili-auto-reset!)
  (bilibili-reset-covers!)
  ;; always re-fetch, even if list 0's new URL happens to equal the old one: bilibili-items was
  ;; just wiped above, and app-set-url! skips the fetch when the URL has not actually changed
  (vector-set! app-urls 0 (bilibili-list-url 0))
  (app-start-feed!)
  (bilibili-queue-active-screen!)
  (app-invalidate-all))

(define (app-web name body)
  (cond ((string=? name "state") (bilibili-web-state))
        ((string=? name "set")
         (bilibili-apply-lists! (or (web-field body "lists") (bilibili-encode-lists bilibili-lists))
                                 (= (web-field-int body "auto_switch" (if bilibili-auto-switch 1 0)) 1))
         (bilibili-web-state))
        (else (web-error (string-append "unknown call: " name)))))

;; 12. Start ---------------------------------------------------------------------------------------

(set! app-render-empty-pages '(0))   ; no document yet: bilibili-render draws a blank body, not applib's waiting text
(app-define! "B站热门" (list (app-page "热门" (lambda () (bilibili-list-url 0)) BILIBILI-INTERVAL bilibili-render)))
(bilibili-auto-reset!)
(bilibili-queue-active-screen!)
