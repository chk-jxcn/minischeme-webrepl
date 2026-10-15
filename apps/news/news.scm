;;; =========================================================================
;;; Hot news (热点新闻), 320x480 portrait, on the app framework (applib.scm).
;;; Data: the app proxy's /app/news: Baidu hot lists (realtime, livelihood,
;;; finance, sports) and the Zhihu or Toutiao hot list.
;;; All pages share a single aggregated bundle URL (/app/news?cat=all)
;;; so all categories are downloaded upfront at boot for zero-delay flips.
;;; =========================================================================

(define NEWS-INTERVAL 300000)            ; the proxy caches 5 minutes

(define (news-count)
  (clamp (or (string->fixed (app-config "news_count" "10") 0) 10) 6 10))

(define (news-extra)
  (if (equal? (app-config "news_extra" "zhihu") "toutiao") "toutiao" "zhihu"))

(define (news-page-cat i)
  (case i
    ((0) "realtime")
    ((1) "livelihood")
    ((2) "finance")
    ((3) "sports")
    ((4) (news-extra))
    (else "realtime")))

(define (news-all-url)
  (app-url (string-append "/app/news?cat=all&n=" (int->str (news-count)))))

(define (news-tag-color tag)
  (cond ((member tag '("爆" "沸")) theme-danger)
        ((equal? tag "热") col-orange)
        ((equal? tag "新") theme-accent)
        (else theme-purple)))

(define (news-render items)
  (let* ((cat (news-page-cat app-page-index))
         (all-rows (items-all items "item"))
         (matching (filter (lambda (it) (equal? (it-c it) cat)) all-rows))
         (rows (if (null? matching) all-rows matching))
         (n (max 1 (length rows)))
         (row-h (min 46 (quotient (- (body-bottom) (body-top)) n))))
    (if (null? rows)
        (txt 14 60 "榜单暂时为空" theme-text-muted)
        (let loop ((rs rows) (y (- (body-top) 2)))
          (if (pair? rs)
              (let* ((it (car rs)) (rank (or (it-int it 3) 0)) (tag (it-d it))
                     (tagged (not (str-empty? tag))))
                (gui-round-rect 8 (+ y 2) 24 20 4 theme-divider #f)
                (txt-center 20 (+ y 4) (int->str rank) theme-text-sub)
                (txt-wrap 38 (+ y 1) (if tagged 247 274) (* LINE-H 2) (it-a it) theme-text-main)
                (if tagged
                    (begin
                      (gui-round-rect 289 (+ y 1) 23 20 4 (news-tag-color tag) #f)
                      (txt 293 (+ y 3) tag (news-tag-color tag))))
                (gui-line 38 (+ y row-h -1) 312 (+ y row-h -1) theme-divider)
                (loop (cdr rs) (+ y row-h))))))))

(app-define! "热点新闻"
  (list (app-page "热搜" (lambda () (news-all-url)) NEWS-INTERVAL news-render)
        (app-page "民生" (lambda () (news-all-url)) NEWS-INTERVAL news-render)
        (app-page "财经" (lambda () (news-all-url)) NEWS-INTERVAL news-render)
        (app-page "体育" (lambda () (news-all-url)) NEWS-INTERVAL news-render)
        (app-page (if (equal? (news-extra) "toutiao") "头条" "知乎")
                  (lambda () (news-all-url)) NEWS-INTERVAL news-render)))

;; The home page header names its list too
(set! app-subtitle-proc (lambda (items) "热搜"))
