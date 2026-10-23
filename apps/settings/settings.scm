;;; =========================================================================
;;; System settings (系统设置), 320x480 portrait.
;;; Embedded in the firmware (examples/app_settings_msbc.h): a mid press (3.5 s)
;;; on the hardware pages (KEY 18 held 8 s) restarts the board into it;
;;; leaving it restarts into the boot app.
;;; Short press: next item; long press (0.8 s): choose; mid press (3.5 s):
;;; back a level (on the menu: leave the settings). No "返回" rows.
;;;   设置模式      SoftAP + captive DNS + the settings web page
;;;   启动应用      which app the board starts ([system] boot_app)
;;;   网络 / 硬件 / 存储信息
;;;   退出设置      restart into the boot app
;;; Needs gui.scm loaded first (theme colors, fonts).
;;; =========================================================================

;; 1. Text and layout -----------------------------------------------------------

(define F-TEXT 2)                     ; the default font when 16 px, else msyh / simsun 16
(let ((sys (font-info 0)))           ; (name height ...) when font 0 is set to a ROM font
  (or (and (pair? sys) (= (cadr sys) 16) (use-font 2 (car sys)))
      (use-font 2 "msyh" 16 'system)
      (use-font 2 "simsun" 16 'system)))

(define HDR-H 36)
(define FTR-H 28)
(define (scr-w) (gui-width))

(define (txt x y s c) (gui-text-styled x y s c F-TEXT))
(define (txt-w s) (gui-text-width s F-TEXT))
(define (txt-right xr y s c) (txt (- xr (txt-w s)) y s c))
(define (txt-center cx y s c) (txt (- cx (quotient (txt-w s) 2)) y s c))
(define (txt-fit x y w s c) (gui-text-fit x y w s c F-TEXT))  ; one line; too long: marquee or "…" (config.ini [text])
(define (txt-wrap x y w h s c) (gui-text-area x y w h s c F-TEXT 20))  ; too tall: wrap_marquee or "…"

(define (show v)
  (cond ((string? v) (if (> (string-length v) 0) v "-"))
        ((symbol? v) (symbol->string v))
        ((eq? v #t) "是")
        ((eq? v #f) "-")
        ((number? v) (number->string v))
        (else "-")))

(define (ref alist . keys)              ; nested assq lookup, #f when missing
  (let loop ((v alist) (ks keys))
    (cond ((null? ks) v)
          ((not (pair? v)) #f)
          (else (let ((e (assq (car ks) v))) (loop (if e (cdr e) #f) (cdr ks)))))))

(define (kb n)                          ; bytes -> "42.3 KB" / "1.4 MB"
  (cond ((not (number? n)) "-")
        ((>= n 1048576)
         (string-append (number->string (quotient n 1048576)) "."
                        (number->string (quotient (* (remainder n 1048576) 10) 1048576)) " MB"))
        (else (string-append (number->string (quotient n 1024)) "."
                             (number->string (quotient (* (remainder n 1024) 10) 1024)) " KB"))))

(define (pad2 n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

(define (uptime ms)
  (if (number? ms)
      (let* ((s (quotient ms 1000)) (d (quotient s 86400)) (r (remainder s 86400)))
        (string-append (if (> d 0) (string-append (number->string d) "天 ") "")
                       (pad2 (quotient r 3600)) ":" (pad2 (quotient (remainder r 3600) 60)) ":" (pad2 (remainder r 60))))
      "-"))

(define (str-starts? s p)
  (and (>= (string-length s) (string-length p)) (string=? (substring s 0 (string-length p)) p)))

;; "/spiffs/apps/x.msbc" and "apps/x.msbc" name the same file
(define (rel-path p) (if (str-starts? p "/spiffs/") (substring p 8 (string-length p)) p))

(define (cfg key) (let ((v (config-get key))) (if (and (string? v) (> (string-length v) 0)) v #f)))

(define (bar x y w h used total color)
  (gui-round-rect x y w h 3 theme-dark-gray #t)
  (if (and (number? used) (number? total) (> total 0) (> used 0))
      (gui-round-rect x y (max 6 (quotient (* w (min used total)) total)) h 3 color #t)))

;; 2. State ---------------------------------------------------------------------------

(define screen 'menu)                   ; menu apps market setup info-menu info reset confirm message error
(define failure #f)                     ; (last-app-stats) when the app failed: why we are here
(define sel 0)                          ; selected row of menu / apps
(define info-page 0)                    ; 0 network, 1 hardware, 2 storage
(define apps '())                       ; (app-list) entries: (path id name description pages version)
(define setup #f)                       ; (ssid ip) once the access point runs
(define setup-saved 0)                  ; web page saves seen
(define message "")
(define message-sub "")
(define restart-in 0)                   ; seconds until (restart), 0: none
(define clock "--:--")
(define market '())                     ; (market-apps): (id name version installed status size description)
(define market-note "")                 ; the last outcome shown on the market screen
(define market-busy #f)                 ; refreshing or installing at the last tick
(define market-auto #f)                 ; started by an app's automatic update: install, then return
(define reset-what #f)                  ; the reset being confirmed: a row of (reset-items)
(define reset-sel 0)                    ; its row, for a cancel
(define reset-failed #f)                ; the message screen shows a failed reset

(define (boot-app-path) (or (cfg "boot_app") "app.msbc"))

(define (app-name-of path)
  (let loop ((as apps))
    (cond ((null? as) (rel-path path))
          ((string=? (rel-path (car (car as))) (rel-path path)) (caddr (car as)))
          (else (loop (cdr as))))))

(define (app-name-by-id id)
  (let loop ((as apps))
    (cond ((null? as) id)
          ((string=? (cadr (car as)) id) (caddr (car as)))
          (else (loop (cdr as))))))

(define (menu-items)
  (list (list "设置模式" "开启热点，在手机或电脑上设置 WiFi、启动应用和应用配置")
        (list "启动应用" (string-append "当前：" (app-name-of (boot-app-path))))
        (list "应用市场" "从市场安装新应用，更新已安装的应用")
        (list "设备信息" "网络、硬件、存储")
        (list "恢复出厂" "清空程序 ROM、应用配置、文件系统或字库")
        (list "退出设置" (string-append "重启并运行 " (app-name-of (boot-app-path))))))

;; Second level: the information pages
(define (info-menu-items)
  (list (list "网络信息" (if (wifi-connected?) (string-append (wifi-ssid) "  " (wifi-ip)) "WiFi 未连接"))
        (list "硬件信息" "芯片、内存、显示屏、运行时间")
        (list "存储信息" "文件系统、系统字库、已安装应用")))

;; Second level: the resets (title, what it does, the factory-reset argument)
(define (reset-items)
  (list (list "清空程序 ROM" "擦除应用的 Flash 运行镜像，下次启动应用时重新生成" 'rom)
        (list "清空应用配置" "删除各应用的配置文件，应用下次启动时恢复默认设置" 'configs)
        (list "清空文件系统" "删除全部应用、数据、WiFi 和系统配置" 'files)
        (list "清空字库" "擦除系统字库分区，中文将无法显示，需要重新写入字库" 'fonts)
        (list "全部重置" "清空程序 ROM 和文件系统，回到出厂状态（保留字库）" 'all)))

(define (redraw) (gui-invalidate 0 0 (scr-w) (gui-height)))

;; 3. Drawing ----------------------------------------------------------------------------

(define (render-header title)
  (gui-rect 0 0 (scr-w) HDR-H theme-card-hdr #t)
  (txt 10 10 title theme-text-main)
  ;; the address of the web page, where the rest of the settings are
  (txt (+ 10 (txt-w title) 10) 10 (if (wifi-connected?) (wifi-ip) "未联网") theme-accent)
  (txt-right (- (scr-w) 10) 10 clock theme-text-main))

(define HINT-LIST "短按：下一项  长按：进入  中长按：返回")

(define (render-footer hint)
  (let ((y (- (gui-height) FTR-H)))
    (gui-rect 0 y (scr-w) FTR-H theme-card-hdr #t)
    (txt-center (quotient (scr-w) 2) (+ y 5) hint theme-text-muted)))

;; A selectable row: title and a muted second line; badge: text, or (text color)
(define (render-row y h title sub selected? badge)
  (if selected?
      (begin (gui-round-rect 8 y 304 (- h 6) 8 theme-accent-dark #t)
             (gui-round-rect 8 y 304 (- h 6) 8 theme-accent #f))
      (gui-round-rect 8 y 304 (- h 6) 8 theme-card-border #f))
  (txt 20 (+ y 6) title (if selected? theme-accent theme-text-main))
  (if badge
      (let* ((text (if (pair? badge) (car badge) badge))
             (color (if (pair? badge) (cadr badge) theme-success))
             (w (+ (txt-w text) 12)))
        (gui-round-rect (- 300 w) (+ y 5) w 20 5 color #f)
        (txt (+ (- 300 w) 6) (+ y 7) text color)))
  (txt-fit 20 (+ y 28) 284 sub theme-text-muted))

(define (render-list title items)
  (render-header title)
  (let loop ((items items) (i 0) (y (+ HDR-H 8)))
    (if (pair? items)
        (begin
          (render-row y 56 (car (car items)) (cadr (car items)) (= i sel) #f)
          (loop (cdr items) (+ i 1) (+ y 56)))))
  (render-footer HINT-LIST))

(define (render-menu) (render-list "系统设置" (menu-items)))

;; The reset about to run: what goes, and how to confirm
(define (render-confirm)
  (render-header "确认重置")
  (let ((cx (quotient (scr-w) 2)) (cy (quotient (gui-height) 2)))
    (txt-center cx (- cy 110) (car reset-what) theme-warning)
    (txt-wrap 24 (- cy 70) 272 70 (cadr reset-what) theme-text-main)
    (txt-wrap 24 (+ cy 10) 272 70 "完成后设备重启，进入内置的系统设置。此操作不能撤销。" theme-text-sub)
    (gui-round-rect 24 (+ cy 90) 272 40 8 theme-danger #f)
    (txt-center cx (+ cy 101) "长按确认" theme-danger))
  (render-footer "短按 / 中长按：取消  长按：确认重置"))

(define APP-ROWS 6)                    ; rows on screen; the list scrolls past them

;; The apps: a window of APP-ROWS rows that keeps sel in view
(define (render-apps)
  (render-header "启动应用")
  (let* ((boot (rel-path (boot-app-path)))
         (total (length apps))
         (start (max 0 (min (- sel (- APP-ROWS 1)) (- total APP-ROWS)))))
    (if (> total APP-ROWS)
        (txt-right (- (scr-w) 70) 10 (string-append (number->string (+ sel 1)) "/" (number->string total)) theme-accent))
    (let loop ((i start) (y (+ HDR-H 10)))
      (if (and (< i total) (< i (+ start APP-ROWS)))
          (begin
            (let ((a (list-ref apps i)))
              (render-row y 62 (caddr a) (show (cadddr a)) (= i sel)
                          (cond ((string=? (rel-path (car a)) boot) "当前")
                                ((str-starts? (car a) "/spiffs/user/") (list "自装" theme-warning))
                                (else #f))))
            (loop (+ i 1) (+ y 62))))))
  (render-footer "短按：下一个  长按：选择  中长按：返回"))

;; The app market (minischeme_market.c through market-*): the rows are
;; "全部更新" when there are updates, then the apps
(define (mk-id a) (car a))
(define (mk-name a) (cadr a))
(define (mk-version a) (caddr a))
(define (mk-installed a) (cadddr a))
(define (mk-status a) (list-ref a 4))
(define (mk-size a) (list-ref a 5))
(define (mk-desc a) (list-ref a 6))

(define (market-updates) (filter (lambda (a) (eq? (mk-status a) 'update)) market))

(define (market-rows)
  (append (if (pair? (market-updates)) (list 'updates) '()) market))

(define (market-state) (ref (market-status) 'state))

(define (mk-badge a)
  (let ((s (mk-status a)))
    (cond ((eq? s 'installed) (list "已安装" theme-success))
          ((eq? s 'update) (list "有更新" theme-warning))
          ((eq? s 'incompatible) (list "需新固件" theme-danger))
          (else (list "未安装" theme-text-muted)))))

(define (mk-sub a st)
  (if (and (eq? (ref st 'state) 'installing) (equal? (ref st 'app) (mk-id a)))
      (let ((total (ref st 'total)) (got (ref st 'received)))
        (string-append "正在下载 " (if (and (number? total) (> total 0))
                                       (string-append (number->string (quotient (* 100 got) total)) "%")
                                       (kb got))))
      (string-append "v" (mk-version a)
                     (if (and (mk-installed a) (not (equal? (mk-installed a) (mk-version a))))
                         (string-append "（已装 v" (mk-installed a) "）") "")
                     "  " (kb (mk-size a)) "  " (mk-desc a))))

(define (render-market)
  (render-header (if market-auto "自动更新应用" "应用市场"))
  (let* ((st (market-status)) (state (ref st 'state))
         (rows (market-rows)) (total (length rows))
         (top (+ HDR-H 34))
         (start (max 0 (min (- sel (- APP-ROWS 1)) (- total APP-ROWS)))))
    ;; the state line: what the market does now, or the last outcome
    (txt-fit 14 (+ HDR-H 8) 292
             (cond ((eq? state 'refreshing) "正在读取应用市场…")
                   ((eq? state 'installing) (string-append "正在安装，还有 " (show (ref st 'queued)) " 个排队"))
                   ((eq? state 'error) (string-append "失败：" (ref st 'message)))
                   ((> (string-length market-note) 0) market-note)
                   ((null? market) (string-append "市场：" (show (ref st 'url))))
                   (else (string-append (number->string (length market)) " 个应用，"
                                        (number->string (length (market-updates))) " 个有更新")))
             (if (eq? state 'error) theme-danger theme-text-sub))
    (if (> total APP-ROWS)
        (txt-right (- (scr-w) 70) 10 (string-append (number->string (+ sel 1)) "/" (number->string total)) theme-accent))
    (let loop ((i start) (y top))
      (if (and (< i total) (< i (+ start APP-ROWS)))
          (let ((r (list-ref rows i)))
            (cond ((eq? r 'updates)
                   (render-row y 62 "全部更新" (string-append (number->string (length (market-updates))) " 个应用有新版本")
                               (= i sel) #f))
                  (else
                   (render-row y 62 (mk-name r) (mk-sub r st) (= i sel) (mk-badge r))
                   (if (and (eq? state 'installing) (equal? (ref st 'app) (mk-id r)))
                       (bar 20 (+ y 50) 280 4 (ref st 'received) (ref st 'total) theme-accent))))
            (loop (+ i 1) (+ y 62))))))
  (render-footer (if market-auto "更新完成后自动返回应用" "短按：下一个  长按：安装 / 更新  中长按：返回")))

(define (render-setup)
  (render-header "设置模式")
  (let* ((st (setup-mode-status))
         (ssid (if setup (car setup) "-"))
         (ip (if setup (cadr setup) "-"))
         (pass (if (and setup (pair? (cddr setup))) (caddr setup) (or (ref st 'ap-pass) "-")))
         (sta? (ref st 'sta-connected))
         (y (+ HDR-H 8)))
    (if (not setup)
        (txt-wrap 14 (+ y 10) 292 60 "热点启动失败，请长按退出后重试" theme-danger)
        (begin
          (gui-round-rect 8 y 304 96 8 theme-card-border #f)
          (txt 20 (+ y 6) "1  连接热点（密码纯数字）" theme-text-muted)
          (gui-text-styled 20 (+ y 28) (string-append "热点: " ssid) theme-accent F-TEXT)
          (gui-text-styled 20 (+ y 50) (string-append "密码: " pass) theme-accent F-TEXT)
          (txt 20 (+ y 72) (string-append "已连接设备：" (show (ref st 'clients))) theme-text-sub)
          (gui-round-rect 8 (+ y 104) 304 68 8 theme-card-border #f)
          (txt 20 (+ y 110) "2  浏览器打开（通常会自动弹出）" theme-text-muted)
          (txt 20 (+ y 136) (string-append "http://" ip "/") theme-accent)
          (gui-round-rect 8 (+ y 180) 304 68 8 theme-card-border #f)
          (txt 20 (+ y 186) "3  设置后点保存，立即生效" theme-text-muted)
          (txt-fit 20 (+ y 212) 284 "WiFi、启动应用、各应用的 ini 配置" theme-text-sub)))
    (let ((y2 (+ y 258)))
      (txt 14 y2 "WiFi" theme-text-muted)
      (txt-fit 90 y2 220 (if sta? (string-append "已连接 " (show (ref st 'sta-ssid))) "未连接")
               (if sta? theme-success theme-warning))
      (if sta?
          (begin
            (txt 14 (+ y2 22) "局域网" theme-text-muted)
            (txt-fit 90 (+ y2 22) 220 (string-append "http://" (show (ref st 'sta-ip)) "/") theme-text-sub)))
      (if (> (or (ref st 'saved) 0) 0)
          (txt 14 (+ y2 46) (string-append "网页已保存配置 " (show (ref st 'saved)) " 次") theme-success))))
  (render-footer "短长按：切换热点/密码  中长按：返回"))

(define (row y label value)
  (txt 14 y label theme-text-muted)
  (txt-fit 112 y 198 (show value) theme-text-main))

(define (render-network)
  (let ((info (system-info)) (st (setup-mode-status)))
    (row 52 "WiFi" (if (wifi-connected?) (wifi-ssid) "未连接"))
    (row 76 "IP" (ref info 'network 'ip))
    (row 100 "信号" (let ((r (ref info 'network 'rssi))) (if (number? r) (string-append (number->string r) " dBm") "-")))
    (row 124 "MAC" (ref info 'chip 'mac))
    (row 148 "设备名称" (or (cfg "device_name") "-"))
    (row 172 "配置网页" (if (wifi-connected?) (string-append "http://" (wifi-ip) "/") "-"))
    (row 196 "热点" (if (ref st 'ap) (string-append (show (ref st 'ap-ssid)) "  " (show (ref st 'ap-ip))) "未开启"))
    (row 220 "应用代理" (or (cfg "proxy_url") (cfg "proxy") "-"))
    (row 244 "时间同步" (if (ref info 'time 'ntp-synced) "已同步 (NTP)" "未同步"))
    (row 268 "配置 WiFi" (or (cfg "ssid") (cfg "wifi_ssid") "-"))))

(define (render-hardware)
  (let ((info (system-info)) (app (last-app-stats)))
    (row 52 "芯片" (string-append (show (ref info 'chip 'model)) "  " (show (ref info 'chip 'cores)) " 核  "
                                  (show (ref info 'chip 'cpu-mhz)) " MHz"))
    (row 76 "Flash" (kb (ref info 'flash 'total)))
    (row 100 "ESP-IDF" (ref info 'chip 'idf))
    (row 124 "显示屏" (string-append (show (ref info 'display 'model)) " " (show (ref info 'display 'width))
                                     "x" (show (ref info 'display 'height))))
    (row 148 "显示模式" (string-append (show (ref info 'display 'mode)) "  " (show (ref info 'display 'color-bits)) " 位色"))
    (row 172 "光照 / 背光" (string-append (show (ref info 'peripherals 'light-adc)) " / "
                                         (show (ref info 'peripherals 'backlight))))
    (row 196 "运行时间" (uptime (ref info 'time 'uptime-ms)))
    (row 220 "复位原因" (ref info 'chip 'reset-reason))
    ;; the settings run instead of the app: its memory was recorded before the restart
    (txt 14 254 "上次运行的应用" theme-accent)
    (gui-line (+ 22 (txt-w "上次运行的应用")) 263 310 263 theme-divider)
    (if app
        (let ((heap (ref app 'heap)) (live (ref app 'live)) (peak (ref app 'peak)))
          (row 278 "应用" (app-name-by-id (ref app 'id)))
          (row 302 "VM 堆" (string-append (kb live) " / " (kb heap)))
          (bar 112 324 198 6 live heap theme-accent)
          (row 336 "堆峰值" (string-append (kb peak) "  ROM " (kb (ref app 'rom))))
          (row 360 "系统内存" (string-append (kb (ref app 'free-heap)) "，最低 " (kb (ref app 'min-free)))))
        (txt-wrap 14 278 292 60 "开机直接进入了设置，没有应用的内存记录" theme-text-muted))
    (txt-wrap 14 392 292 44 (string-append "完整信息见设置网页 http://"
                                           (if (wifi-connected?) (wifi-ip) "192.168.4.1") "/")
              theme-text-muted)))

(define (render-storage)
  (let ((fs (fs-info)) (rom (fontrom-info)))
    (row 52 "文件系统" (if fs (string-append (kb (cadr fs)) " / " (kb (car fs))) "-"))
    (if fs (bar 112 74 198 6 (cadr fs) (car fs) theme-accent))
    (row 88 "系统字库" (if rom (string-append (kb (car rom)) " / " (kb (cadr rom))) "-"))
    (if rom (bar 112 110 198 6 (car rom) (cadr rom) theme-purple))
    (let loop ((fonts (fontrom-list)) (y 124))
      (if (and (pair? fonts) (< y 200))
          (begin
            (txt 112 y (string-append (car (car fonts)) "  " (kb (cadddr (car fonts)))) theme-text-sub)
            (loop (cdr fonts) (+ y 22)))))
    (txt 14 210 "已安装应用" theme-accent)
    (gui-line 100 219 310 219 theme-divider)
    (let loop ((as apps) (y 234))
      (if (and (pair? as) (< y 410))
          (let ((a (car as)))
            (txt-fit 14 y 220 (caddr a) theme-text-main)
            (txt-right 310 y (app-source a) theme-text-sub)
            (loop (cdr as) (+ y 22)))))))

;; Where an app came from: its folder (/spiffs/apps: the market, /spiffs/user: uploaded)
(define (app-source a)
  (cond ((str-starts? (car a) "/spiffs/user/") "自装")
        ((str-starts? (car a) "/spiffs/apps/") "市场")
        (else "内置")))

(define (str-ends? s e)
  (and (>= (string-length s) (string-length e))
       (string=? (substring s (- (string-length s) (string-length e)) (string-length s)) e)))

(define (app-image? f) (or (str-ends? (car f) ".msbc") (str-ends? (car f) ".fasl")))

(define (render-info)
  (let ((titles '("网络信息" "硬件信息" "存储信息")))
    (render-header (list-ref titles info-page))
    (txt-right (- (scr-w) 70) 10 (string-append (number->string (+ info-page 1)) "/3") theme-accent)
    (cond ((= info-page 0) (render-network))
          ((= info-page 1) (render-hardware))
          (else (render-storage)))
    (render-footer "短按：下一页  长按 / 中长按：返回")))

;; The app failed (image build, load or crash): why, before the menu
(define (render-error)
  (render-header "系统设置")
  (let ((cy (quotient (gui-height) 2)) (phase (ref failure 'phase)))
    (txt-center (quotient (scr-w) 2) (- cy 120)
                (cond ((eq? phase 'rom) "应用镜像构建失败") ((eq? phase 'load) "应用加载失败")
                      ((eq? phase 'api) "应用与固件不兼容") (else "应用运行出错"))
                theme-warning)
    (txt-center (quotient (scr-w) 2) (- cy 90) (app-name-by-id (ref failure 'id)) theme-text-main)
    (txt-wrap 20 (- cy 50) 280 160 (ref failure 'error) theme-text-sub))
  (render-footer "按键：进入设置菜单"))

(define (render-message)
  (render-header "系统设置")
  (let ((cy (quotient (gui-height) 2)))
    (txt-center (quotient (scr-w) 2) (- cy 30) message theme-accent)
    (txt-wrap 20 cy 280 80 message-sub theme-text-sub)))

(define (render)
  (gui-clear theme-bg)
  (cond ((eq? screen 'apps) (render-apps))
        ((eq? screen 'market) (render-market))
        ((eq? screen 'setup) (render-setup))
        ((eq? screen 'info) (render-info))
        ((eq? screen 'info-menu) (render-list "设备信息" (info-menu-items)))
        ((eq? screen 'reset) (render-list "恢复出厂" (reset-items)))
        ((eq? screen 'confirm) (render-confirm))
        ((eq? screen 'message) (render-message))
        ((eq? screen 'error) (render-error))
        (else (render-menu)))
  (gui-flush))

;; 4. Actions ------------------------------------------------------------------------------

(define (go screen-name) (set! screen screen-name) (set! sel 0) (redraw))

(define (restart-soon title sub)
  (set! message title)
  (set! message-sub sub)
  (set! restart-in 2)
  (set! screen 'message)
  (redraw))

(define (choose-menu)
  (cond ((= sel 0)
         (set! setup (setup-mode-start))
         (go 'setup))
        ((= sel 1) (set! apps (app-list)) (go 'apps))
        ((= sel 2) (open-market))
        ((= sel 3) (set! apps (app-list)) (go 'info-menu))
        ((= sel 4) (go 'reset))
        (else (restart-soon "正在重启" (string-append "即将运行 " (app-name-of (boot-app-path)))))))

(define (choose-info-menu)
  (set! info-page sel)
  (set! screen 'info)
  (redraw))

(define (choose-reset)
  (set! reset-what (list-ref (reset-items) sel))
  (set! reset-sel sel)
  (set! screen 'confirm)
  (redraw))

;; Back to the menu with item i selected
(define (back-to-menu i) (go 'menu) (set! sel i) (redraw))

;; Confirmed: the firmware resets, then restarts into the built-in settings
(define (run-reset)
  (let ((r (factory-reset (caddr reset-what))))
    (set! reset-failed (not (eq? r #t)))
    (set! message (if (eq? r #t) (string-append (car reset-what) "：已完成") "重置失败"))
    (set! message-sub (if (eq? r #t) "正在重启，进入内置的系统设置..." (if (string? r) r "")))
    (set! screen 'message)
    (redraw)))

(define (open-market)
  (let ((r (market-refresh)))
    (set! market (market-apps))
    (set! market-note (if (string? r) (string-append "失败：" r) ""))
    (set! market-busy (eq? r #t))
    (go 'market)))

;; Long press on a market row: install / update one, or all updates
(define (choose-market)
  (let ((rows (market-rows)))
    (if (< sel (length rows))
        (let ((r (list-ref rows sel)))
          (cond ((and (pair? r) (eq? (mk-status r) 'incompatible))
                 (set! market-note (string-append (mk-name r) " 需要更新后的固件"))
                 (redraw))
                (else
                 (let ((n (market-install (if (eq? r 'updates) 'updates (mk-id r)))))
                   (set! market-note (if (string? n) (string-append "失败：" n) ""))
                   (set! market-busy (number? n))
                   (redraw))))))))

(define (choose-app)
  (if (< sel (length apps))
      (let ((a (list-ref apps sel)))
        (config-set! "system" "boot_app" (rel-path (car a)))
        (restart-soon (string-append "已设为启动应用")
                      (string-append (caddr a) "（" (rel-path (car a)) "），正在重启...")))))

;; 5. Firmware hooks -------------------------------------------------------------------------

(define gui-render-proc render)

(define (app-button)
  (cond ((eq? screen 'menu) (set! sel (remainder (+ sel 1) (length (menu-items)))) (redraw))
        ((eq? screen 'apps) (set! sel (remainder (+ sel 1) (max 1 (length apps)))) (redraw))
        ((eq? screen 'market) (set! sel (remainder (+ sel 1) (max 1 (length (market-rows))))) (redraw))
        ((eq? screen 'info) (set! info-page (remainder (+ info-page 1) 3)) (redraw))
        ((eq? screen 'info-menu) (set! sel (remainder (+ sel 1) (length (info-menu-items)))) (redraw))
        ((eq? screen 'reset) (set! sel (remainder (+ sel 1) (length (reset-items)))) (redraw))
        ((eq? screen 'confirm) (set! screen 'reset) (set! sel reset-sel) (redraw))   ; cancel
        ((and (eq? screen 'message) reset-failed) (set! reset-failed #f) (go 'reset))
        ((eq? screen 'error) (go 'menu))
        (else #f)))

(define (app-long-press)
  (cond ((eq? screen 'menu) (choose-menu))
        ((eq? screen 'apps) (choose-app))
        ((eq? screen 'market) (choose-market))
        ((eq? screen 'setup) (set! setup (setup-mode-start #t)) (redraw))
        ((eq? screen 'info) (set! sel info-page) (set! screen 'info-menu) (redraw))
        ((eq? screen 'info-menu) (choose-info-menu))
        ((eq? screen 'reset) (choose-reset))
        ((eq? screen 'confirm) (run-reset))
        ((eq? screen 'error) (go 'menu))
        (else #f)))

;; Mid press: back a level; on the menu, leave the settings
(define (app-mid-press)
  (cond ((eq? screen 'menu) (restart-soon "正在重启" (string-append "即将运行 " (app-name-of (boot-app-path)))))
        ((eq? screen 'apps) (back-to-menu 1))
        ((eq? screen 'market) (if (not market-auto) (back-to-menu 2)))
        ((eq? screen 'info-menu) (back-to-menu 3))
        ((eq? screen 'info) (set! sel info-page) (set! screen 'info-menu) (redraw))
        ((eq? screen 'reset) (back-to-menu 4))
        ((eq? screen 'confirm) (set! screen 'reset) (set! sel reset-sel) (redraw))   ; cancel
        ((eq? screen 'setup) (back-to-menu 0))
        ((and (eq? screen 'message) reset-failed) (set! reset-failed #f) (go 'reset))
        ((eq? screen 'error) (go 'menu))))

(define (app-touch x y) (app-button))

(define (app-tick hm sec week date lux bl . rest)
  (if (theme-tick! (if (pair? rest) (car rest) 0)) (redraw))   ; day / night, a theme.css changed
  (if (not (equal? hm clock))
      (begin (set! clock hm) (gui-invalidate 0 0 (scr-w) HDR-H)))
  (cond ((> restart-in 0)
         (set! restart-in (- restart-in 1))
         (if (= restart-in 0) (restart)))
        ((and market-auto (ref (market-status) 'return))   ; the automatic update is over
         (set! market-auto #f)
         (restart-soon (cond ((str-ends? (ref (market-status) 'message) " 0 failed") "应用已更新")
                             ((str-ends? (ref (market-status) 'message) " failed") "部分应用更新失败")
                             (else "没有完成自动更新"))
                       (string-append "正在返回 " (app-name-of (boot-app-path)) "...")))
        ((eq? screen 'setup)
         (let ((saved (or (ref (setup-mode-status) 'saved) 0)))
           (set! setup-saved saved)
           (gui-invalidate 0 HDR-H (scr-w) (- (gui-height) HDR-H FTR-H))))
        ((eq? screen 'info)
         (if (< info-page 2) (gui-invalidate 0 HDR-H (scr-w) (- (gui-height) HDR-H FTR-H))))
        ((eq? screen 'market)       ; progress every second; the list once a round ends
         (let* ((state (market-state)) (busy (or (eq? state 'refreshing) (eq? state 'installing))))
           (if (and market-busy (not busy))
               (begin
                 (set! market (market-apps))
                 (if (eq? state 'idle)
                     (set! market-note (let ((m (ref (market-status) 'message)))
                                         (if (str-ends? m "installed") "已安装，退出设置（重启）后生效" ""))))
                 (if (>= sel (length (market-rows))) (set! sel 0))))
           (if (or busy market-busy) (redraw))
           (set! market-busy busy)))))

(define (app-step) #f)

(set! apps (app-list))
(let ((app (last-app-stats)))
  (if (and app (ref app 'error))
      (begin (set! failure app) (set! screen 'error))))
;; an app's boot found updates: show them being installed (the firmware runs the round)
(if (eq? (ref (market-status) 'auto) 'update)
    (begin (set! market-auto #t)
           (set! market-note "自动更新：等待网络…")
           (set! screen 'market)))
(redraw)
