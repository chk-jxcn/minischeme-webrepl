;;; =========================================================================
;;; PC performance monitor (320x480 portrait)
;;; Shows a PC's sensors read from LibreHardwareMonitor's web server
;;; (Options -> Remote Web Server, port 8085).
;;;
;;; The firmware only offers a generic JSON feed (json-feed-start): it polls a
;;; URL in the background and keeps the JSON objects our selectors pick.
;;; Everything specific to LibreHardwareMonitor lives here: which keys a
;;; sensor node has, which sensors to keep, and how to read their values.
;;; The button cycles: monitor -> link status -> hardware info.
;;; Needs gui.scm loaded first (theme colors, fonts).
;;; =========================================================================

;; 1. LibreHardwareMonitor data source -------------------------------------

;; config.ini: [app] pcmon_url = http://<pc>:8085/data.json; unset: LibreHardwareMonitor
;; on the PC of the app proxy ([app] proxy = http://<pc>:8087), port 8085
(define (pcmon-default-url)
  (let* ((p1 (config-get "proxy_url"))
         (p (if (and (string? p1) (> (string-length p1) 0)) p1 (or (config-get "proxy") "")))
         (n (string-length p))
         (start (if (and (> n 7) (string=? (substring p 0 7) "http://")) 7 0)))
    (let loop ((i start))           ; the host: up to ":" or "/"
      (cond ((or (= i n) (char=? (string-ref p i) #\:) (char=? (string-ref p i) #\/))
             (if (> i start) (string-append "http://" (substring p start i) ":8085/data.json") ""))
            (else (loop (+ i 1)))))))

;; data.json is a tree of nodes, each a JSON object with these keys
(define LHM-KEYS '("SensorId" "Value" "Text" "ImageURL"))
(define K-SID 0) (define K-VALUE 1) (define K-TEXT 2) (define K-IMG 3)

;; Sensor ids; on the device (json-feed-dump) lists every node of a PC
(define pcmon-sensor-ids
  (list "/intelcpu/0/load/0"            ; 0  CPU total load
        "/intelcpu/0/clock/1"           ; 1  CPU core #1 clock
        "/intelcpu/0/temperature/6"     ; 2  CPU package temperature
        "/ram/data/0"                   ; 3  memory used (GB)
        "/ram/data/1"                   ; 4  memory available (GB)
        "/gpu-nvidia/0/load/0"          ; 5  GPU core load
        "/gpu-nvidia/0/clock/0"         ; 6  GPU core clock
        "/gpu-nvidia/0/temperature/0"   ; 7  GPU core temperature
        "/gpu-nvidia/0/smalldata/1"     ; 8  GPU memory used (MB)
        "/gpu-nvidia/0/smalldata/2"     ; 9  GPU memory total (MB)
        "/gpu-nvidia/0/power/0"         ; 10 GPU package power
        "/nvme/2/temperature/0"         ; 11 system disk temperature
        "/lpc/nct6796dr/fan/5"          ; 12 system fan (RPM)
        "/lpc/nct6796dr/fan/1"          ; 13 CPU fan (RPM)
        "/gpu-nvidia/0/fan/1"           ; 14 GPU fan (RPM)
        "/lpc/nct6796dr/control/5"      ; 15 system fan duty (%)
        "/lpc/nct6796dr/control/1"      ; 16 CPU fan duty (%)
        "/gpu-nvidia/0/control/1"))     ; 17 GPU fan duty (%)

(define S-CPU-LOAD 0) (define S-CPU-CLOCK 1) (define S-CPU-TEMP 2)
(define S-MEM-USED 3) (define S-MEM-AVAIL 4)
(define S-GPU-LOAD 5) (define S-GPU-CLOCK 6) (define S-GPU-TEMP 7)
(define S-GPU-MEM 8) (define S-GPU-MEM-TOTAL 9) (define S-GPU-POWER 10)
(define S-DISK-TEMP 11)
(define S-FAN-SYS 12) (define S-FAN-CPU 13) (define S-FAN-GPU 14)
(define S-DUTY-SYS 15) (define S-DUTY-CPU 16) (define S-DUTY-GPU 17)
(define PCMON-NSENSORS 18)

;; Per-thread loads for the core grid (the total, sensor 0, matches first)
(define pcmon-core-prefix "/intelcpu/0/load/")

;; Hardware nodes are recognised by their icon; we keep their names
(define pcmon-icons
  '("images_icon/computer.png" "images_icon/cpu.png"
    "images_icon/nvidia.png" "images_icon/ati.png" "images_icon/amd.png" "images_icon/intel.png"))

;; Selector indexes: sensors first, then the core prefix, then the icons
(define SEL-CORES PCMON-NSENSORS)
(define SEL-PC (+ SEL-CORES 1))
(define SEL-CPU (+ SEL-CORES 2))          ; anything after it is a GPU

(define (pcmon-selectors)
  (append (map (lambda (id) (list K-SID 'equal id K-VALUE)) pcmon-sensor-ids)
          (list (list K-SID 'prefix pcmon-core-prefix K-VALUE))
          (map (lambda (icon) (list K-IMG 'equal icon K-TEXT)) pcmon-icons)))

(define (pcmon-url)
  (let ((u (config-get "pcmon_url")))
    (if (and u (> (string-length u) 7)) u (pcmon-default-url))))

(define (pcmon-start!)
  (json-feed-start (pcmon-url) 1000 LHM-KEYS (pcmon-selectors)))

;; "12.3 %" -> 123 (tenths), #f when the node has no number
(define (pcmon-tenths str) (if str (string->fixed str 1) #f))

;; 2. State --------------------------------------------------------------------

(define PCMON-POINTS 80)
(define (pcmon-ring) (make-vector PCMON-POINTS 0))

(define pcmon-hist-cpu (pcmon-ring))
(define pcmon-hist-gpu (pcmon-ring))
(define pcmon-hist-tcpu (pcmon-ring))
(define pcmon-hist-tgpu (pcmon-ring))
(define pcmon-hist-tdisk (pcmon-ring))
(define pcmon-hist-fsys (pcmon-ring))
(define pcmon-hist-fcpu (pcmon-ring))
(define pcmon-hist-fgpu (pcmon-ring))
(define pcmon-head 0)      ; next ring slot
(define pcmon-filled 0)    ; samples stored, up to PCMON-POINTS

(define pcmon-vals (make-vector PCMON-NSENSORS #f)) ; latest values, tenths or #f
(define pcmon-cores (make-vector 16 #f))            ; per-thread loads, tenths
(define pcmon-ncores 0)
(define pcmon-last-seq 0)
(define pcmon-samples 0)
(define pcmon-pc-name "PC MONITOR")
(define pcmon-cpu-name "CPU")
(define pcmon-gpu-name "GPU")
(define pcmon-time "--:--")
(define PAGE-MONITOR 0) (define PAGE-LINK 1) (define PAGE-HARDWARE 2)
(define pcmon-page PAGE-MONITOR)

;; 3. Sampling -----------------------------------------------------------------

(define (pcmon-val i) (vector-ref pcmon-vals i))

(define (pcmon-push! ring i)
  (let ((v (pcmon-val i)))
    (vector-set! ring pcmon-head (if v v 0))))

;; "NVIDIA GeForce RTX 4060" -> "RTX 4060": the tile is narrow
(define (pcmon-short-gpu name)
  (let loop ((prefixes '("NVIDIA GeForce " "AMD Radeon " "Intel(R) ")))
    (cond
      ((null? prefixes) name)
      ((let ((p (car prefixes)))
         (and (> (string-length name) (string-length p))
              (string=? (substring name 0 (string-length p)) p)))
       (substring name (string-length (car prefixes)) (string-length name)))
      (else (loop (cdr prefixes))))))

;; Hardware names change rarely: read them every 30th sample
(define (pcmon-note-name! sel name gpu-seen?)
  (cond ((not name) gpu-seen?)
        ((= sel SEL-PC)
         (if (not (string=? name pcmon-pc-name))
             (begin
               (set! pcmon-pc-name name)
               (pcmon-refresh 0 28)))      ; the header only redraws on demand
         gpu-seen?)
        ((= sel SEL-CPU) (set! pcmon-cpu-name name) gpu-seen?)
        (gpu-seen? #t)                     ; keep the first GPU
        (else (set! pcmon-gpu-name (pcmon-short-gpu name)) #t)))

;; One document: route every kept object by the selector it matched
(define (pcmon-sample! seq)
  (set! pcmon-last-seq seq)
  (vector-fill! pcmon-vals #f)
  (set! pcmon-ncores 0)
  (let ((n (json-feed-count))
        (names? (= (remainder pcmon-samples 30) 0)))
    (let loop ((i 0) (gpu-seen? #f))
      (if (< i n)
          (let ((sel (json-feed-selector i)))
            (cond
              ((< sel SEL-CORES)
               (vector-set! pcmon-vals sel (pcmon-tenths (json-feed-field i K-VALUE)))
               (loop (+ i 1) gpu-seen?))
              ((= sel SEL-CORES)
               (if (< pcmon-ncores 16)
                   (begin
                     (vector-set! pcmon-cores pcmon-ncores (pcmon-tenths (json-feed-field i K-VALUE)))
                     (set! pcmon-ncores (+ pcmon-ncores 1))))
               (loop (+ i 1) gpu-seen?))
              (names? (loop (+ i 1) (pcmon-note-name! sel (json-feed-field i K-TEXT) gpu-seen?)))
              (else (loop (+ i 1) gpu-seen?)))))))
  (set! pcmon-samples (+ pcmon-samples 1))
  (pcmon-push! pcmon-hist-cpu S-CPU-LOAD)
  (pcmon-push! pcmon-hist-gpu S-GPU-LOAD)
  (pcmon-push! pcmon-hist-tcpu S-CPU-TEMP)
  (pcmon-push! pcmon-hist-tgpu S-GPU-TEMP)
  (pcmon-push! pcmon-hist-tdisk S-DISK-TEMP)
  (pcmon-push! pcmon-hist-fsys S-DUTY-SYS)
  (pcmon-push! pcmon-hist-fcpu S-DUTY-CPU)
  (pcmon-push! pcmon-hist-fgpu S-DUTY-GPU)
  (set! pcmon-head (remainder (+ pcmon-head 1) PCMON-POINTS))
  (if (< pcmon-filled PCMON-POINTS) (set! pcmon-filled (+ pcmon-filled 1)))
  (if (= pcmon-page PAGE-MONITOR) (pcmon-refresh 30 (- (gui-height) 30))))

;; 4. Formatting (values arrive in tenths) -------------------------------------

(define (pcmon-int v) (if v (number->string (quotient (+ v 5) 10)) "--"))

(define (pcmon-dec v)                      ; one decimal: 427 -> "42.7"
  (if v
      (string-append (number->string (quotient v 10)) "." (number->string (remainder v 10)))
      "--"))

(define (pcmon-mem-text)                   ; "43G/128G"
  (let ((used (pcmon-val S-MEM-USED)) (avail (pcmon-val S-MEM-AVAIL)))
    (if (and used avail)
        (string-append (pcmon-int used) "G/" (pcmon-int (+ used avail)) "G")
        "--/--")))

(define (pcmon-vram-text)                  ; MB tenths -> "3.5G/8G"
  (let ((used (pcmon-val S-GPU-MEM)) (total (pcmon-val S-GPU-MEM-TOTAL)))
    (if (and used total)
        (string-append (pcmon-dec (quotient used 1024)) "G/"
                       (number->string (quotient (+ total 5120) 10240)) "G")
        "--/--")))

;; Load / temperature colors: warn when the PC runs hot or busy
(define (pcmon-load-color v)
  (cond ((not v) theme-text-muted)
        ((>= v 900) theme-danger)
        ((>= v 700) theme-warning)
        (else theme-text-main)))

(define (pcmon-temp-color v base)
  (cond ((not v) theme-text-muted)
        ((>= v 850) theme-danger)
        ((>= v 750) theme-warning)
        (else base)))

;; 5. Drawing ------------------------------------------------------------------

(define PCMON-SEC-Y 32)      ; first section
(define PCMON-SEC-H 102)     ; section pitch
(define PCMON-CHART-X 8)
(define PCMON-CHART-W 142)
(define PCMON-CHART-H 92)
(define PCMON-INFO-X 160)

(define (pcmon-sec-y i) (+ PCMON-SEC-Y (* i PCMON-SEC-H)))

;; Chart frame plus one or more series (ring, lo, hi, color) in tenths
(define (pcmon-chart y series)
  (gui-round-rect PCMON-CHART-X y PCMON-CHART-W PCMON-CHART-H 4 theme-card-border #f)
  (let ((start (if (< pcmon-filled PCMON-POINTS) 0 pcmon-head)))
    (let loop ((s series))
      (if (pair? s)
          (let ((e (car s)))
            (if (>= pcmon-filled 2)
                (gui-chart (+ PCMON-CHART-X 2) (+ y 3) (- PCMON-CHART-W 4) (- PCMON-CHART-H 6)
                           (car e) start pcmon-filled (cadr e) (caddr e) (cadddr e)))
            (loop (cdr s)))))))

(define (pcmon-text x y str color) (gui-text-styled x y str color FONT-SYS-16))
(define (pcmon-big x y str color) (gui-text-styled x y str color FONT-CLOCK-32))

(define (pcmon-text-right x-right y str color)
  (pcmon-text (- x-right (gui-text-width str FONT-SYS-16)) y str color))

;; Big number with a small unit right after it ("12" "%" / "30" "°")
(define (pcmon-big-unit x y num unit color)
  (pcmon-big x y num color)
  (pcmon-text (+ x (gui-text-width num FONT-CLOCK-32) 1) (+ y 2) unit color))

(define (pcmon-render-header)
  (gui-rect 0 0 (gui-width) 28 theme-card-hdr #t)
  (pcmon-text 8 6 pcmon-pc-name theme-text-main)
  (pcmon-text-right (- (gui-width) 8) 6 pcmon-time theme-text-main))

;; Thread loads as a heat grid (what the original wanted to show with LEDs)
(define (pcmon-core-color v)
  (cond ((not v) theme-dark-gray)
        ((>= v 800) theme-danger)
        ((>= v 500) theme-warning)
        ((>= v 200) theme-success)
        (else theme-accent-dark)))

(define (pcmon-render-cores x y)
  (let ((cols 4) (cell 13) (gap 3))
    (let loop ((i 0))
      (if (< i (max pcmon-ncores 12))
          (begin
            (gui-rect (+ x (* (remainder i cols) (+ cell gap)))
                      (+ y (* (quotient i cols) (+ cell gap)))
                      cell cell
                      (pcmon-core-color (if (< i pcmon-ncores) (vector-ref pcmon-cores i) #f))
                      #t)
            (loop (+ i 1)))))))

(define (pcmon-render-cpu y)
  (pcmon-chart y (list (list pcmon-hist-cpu 0 1000 theme-accent)))
  (let ((load (pcmon-val S-CPU-LOAD)))
    (pcmon-text PCMON-INFO-X (+ y 4) pcmon-cpu-name theme-text-muted)
    (pcmon-big-unit PCMON-INFO-X (+ y 28) (pcmon-int load) "%" (pcmon-load-color load))
    (pcmon-text PCMON-INFO-X (+ y 70) (pcmon-mem-text) theme-text-sub))
  (pcmon-text-right 312 (+ y 4) (string-append (pcmon-int (pcmon-val S-CPU-CLOCK)) "MHz") theme-text-sub)
  (pcmon-render-cores 250 (+ y 30)))

(define (pcmon-render-temps y)
  (pcmon-chart y (list (list pcmon-hist-tcpu 200 1000 theme-danger)
                       (list pcmon-hist-tgpu 200 1000 theme-accent)
                       (list pcmon-hist-tdisk 200 1000 theme-warning)))
  (pcmon-text PCMON-INFO-X (+ y 4) "Temperature" theme-text-muted)
  (let loop ((cols (list (list "CPU" S-CPU-TEMP theme-danger)
                         (list "GPU" S-GPU-TEMP theme-accent)
                         (list "DISK" S-DISK-TEMP theme-warning)))
             (x PCMON-INFO-X))
    (if (pair? cols)
        (let* ((c (car cols)) (v (pcmon-val (cadr c))))
          (pcmon-text x (+ y 30) (car c) (caddr c))
          (pcmon-big-unit x (+ y 52) (pcmon-int v) "°" (pcmon-temp-color v theme-text-main))
          (loop (cdr cols) (+ x 52))))))

(define (pcmon-render-gpu y)
  (pcmon-chart y (list (list pcmon-hist-gpu 0 1000 theme-danger)))
  (let ((load (pcmon-val S-GPU-LOAD)) (power (pcmon-val S-GPU-POWER)))
    (pcmon-text PCMON-INFO-X (+ y 4) pcmon-gpu-name theme-text-muted)
    (pcmon-big-unit PCMON-INFO-X (+ y 28) (pcmon-int load) "%" (pcmon-load-color load))
    (pcmon-text PCMON-INFO-X (+ y 70) (pcmon-vram-text) theme-text-sub)
    (pcmon-text-right 312 (+ y 30) (string-append (pcmon-int (pcmon-val S-GPU-CLOCK)) "MHz") theme-text-sub)
    (pcmon-text-right 312 (+ y 52) (string-append (pcmon-int power) "W") theme-text-sub)))

;; Fan gauge: 270 degree track, filled by duty, RPM in the middle
(define (pcmon-gauge cx cy label rpm duty color)
  (gui-arc cx cy 24 5 135 270 theme-dark-gray)
  (if (and duty (> duty 0))
      (gui-arc cx cy 24 5 135 (max 1 (quotient (* (min duty 1000) 270) 1000)) color))
  (let ((t (pcmon-int rpm)))
    (pcmon-text (- cx (quotient (gui-text-width t FONT-SYS-16) 2)) (- cy 8) t theme-text-main))
  (pcmon-text (- cx (quotient (gui-text-width label FONT-SYS-16) 2)) (- cy 44) label color))

(define (pcmon-render-fans y)
  (pcmon-chart y (list (list pcmon-hist-fsys 0 1000 theme-success)
                       (list pcmon-hist-fcpu 0 1000 theme-danger)
                       (list pcmon-hist-fgpu 0 1000 theme-warning)))
  (pcmon-text PCMON-INFO-X (+ y 4) "Fans" theme-text-muted)
  (pcmon-gauge 184 (+ y 66) "SYS" (pcmon-val S-FAN-SYS) (pcmon-val S-DUTY-SYS) theme-success)
  (pcmon-gauge 236 (+ y 66) "CPU" (pcmon-val S-FAN-CPU) (pcmon-val S-DUTY-CPU) theme-danger)
  (pcmon-gauge 288 (+ y 66) "GPU" (pcmon-val S-FAN-GPU) (pcmon-val S-DUTY-GPU) theme-warning))

(define (pcmon-status-field key)
  (let ((e (assq key (json-feed-status)))) (if e (cdr e) #f)))

;; Bottom strip: connection state (the original left it for message icons)
(define (pcmon-render-footer)
  (let* ((y (- (gui-height) 28))
         (state (pcmon-status-field 'state))
         (ms (pcmon-status-field 'fetch-ms))
         (text (cond ((eq? state 'ok)
                      (string-append "LHM ok  " (number->string (quotient (+ (pcmon-status-field 'bytes) 512) 1024)) " KB"
                                     (if (and ms (> ms 0)) (string-append "  " (number->string ms) " ms") "")))
                     ((eq? state 'error) (string-append "LHM: " (pcmon-status-field 'error)))
                     (else "Connecting to LibreHardwareMonitor..."))))
    (gui-rect 0 y (gui-width) 28 theme-card-hdr #t)
    (pcmon-text 8 (+ y 6) text (if (eq? state 'ok) theme-text-muted theme-warning))))

;; Label / value rows for the two info pages
(define (pcmon-row y label value)
  (pcmon-text 12 y label theme-text-muted)
  (pcmon-text 132 y value theme-text-main))

(define (pcmon-show v)
  (cond ((string? v) (if (> (string-length v) 0) v "-"))
        ((symbol? v) (symbol->string v))
        ((eq? v #t) "yes")
        ((eq? v #f) "-")
        ((number? v) (number->string v))
        (else "-")))

(define (pcmon-page-title text)
  (pcmon-text 12 38 text theme-accent))

;; Page 2: everything needed to debug the connection
(define (pcmon-render-link)
  (pcmon-page-title "Link: LibreHardwareMonitor")
  (pcmon-text 12 62 (pcmon-url) theme-text-sub)
  (let loop ((rows (json-feed-status)) (y 92))
    (if (pair? rows)
        (begin
          (pcmon-row y (symbol->string (caar rows)) (pcmon-show (cdar rows)))
          (loop (cdr rows) (+ y 24))))))

;; Page 3: board and memory, like the shared hardware pages
(define (pcmon-ref alist . keys)          ; nested lookup, #f when missing
  (let loop ((v alist) (ks keys))
    (cond ((null? ks) v)
          ((not (pair? v)) #f)
          (else (let ((e (assq (car ks) v))) (loop (if e (cdr e) #f) (cdr ks)))))))

(define (pcmon-kb n)                       ; bytes -> "42.3 KB"
  (if (number? n)
      (string-append (number->string (quotient n 1024)) "."
                     (number->string (quotient (* (remainder n 1024) 10) 1024)) " KB")
      "-"))

(define (pcmon-2d n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

(define (pcmon-uptime ms)                  ; "3d 04:05:06"
  (if (number? ms)
      (let* ((s (quotient ms 1000)) (d (quotient s 86400)) (r (remainder s 86400)))
        (string-append (if (> d 0) (string-append (number->string d) "d ") "")
                       (pcmon-2d (quotient r 3600)) ":" (pcmon-2d (quotient (remainder r 3600) 60))
                       ":" (pcmon-2d (remainder r 60))))
      "-"))

(define (pcmon-render-hardware)
  (let* ((info (system-info))
         (st (vm-stats))
         (vm-heap (pcmon-ref info 'memory 'vm-heap))
         (vm-used (pcmon-ref info 'memory 'vm-used))
         (rssi (pcmon-ref info 'network 'rssi)))
    (pcmon-page-title "Hardware")
    (pcmon-row 62 "IP" (pcmon-show (pcmon-ref info 'network 'ip)))
    (pcmon-row 84 "MAC" (pcmon-show (pcmon-ref info 'chip 'mac)))
    (pcmon-row 106 "WiFi" (string-append (pcmon-show (pcmon-ref info 'network 'ssid))
                                         (if (number? rssi) (string-append "  " (number->string rssi) " dBm") "")))
    (pcmon-row 134 "System free" (pcmon-kb (pcmon-ref info 'memory 'free-heap)))
    (pcmon-row 156 "Largest block" (pcmon-kb (pcmon-ref info 'memory 'largest-block)))
    (pcmon-row 178 "VM heap" (pcmon-kb vm-heap))
    (pcmon-row 200 "VM used" (pcmon-kb vm-used))
    (pcmon-row 222 "VM free" (if (and (number? vm-heap) (number? vm-used)) (pcmon-kb (- vm-heap vm-used)) "-"))
    (pcmon-row 244 "Allocated" (string-append (number->string (pcmon-ref st 'alloc-kb)) " KB total"))
    (pcmon-row 266 "GC" (string-append (number->string (pcmon-ref st 'minor-gcs)) " minor  "
                                       (number->string (pcmon-ref st 'major-gcs)) " major"))
    (pcmon-row 294 "Chip" (string-append (pcmon-show (pcmon-ref info 'chip 'model)) "  "
                                         (pcmon-show (pcmon-ref info 'chip 'cpu-mhz)) " MHz x"
                                         (pcmon-show (pcmon-ref info 'chip 'cores))))
    (pcmon-row 316 "Flash" (pcmon-kb (pcmon-ref info 'chip 'flash-bytes)))
    (pcmon-row 338 "App ROM" (pcmon-kb (pcmon-ref info 'memory 'app-rom)))
    (pcmon-row 360 "IDF" (pcmon-show (pcmon-ref info 'chip 'idf)))
    (pcmon-row 382 "Reset" (pcmon-show (pcmon-ref info 'chip 'reset-reason)))
    (pcmon-row 404 "Uptime" (pcmon-uptime (pcmon-ref info 'time 'uptime-ms)))))

(define (pcmon-render)
  (gui-clear theme-bg)
  (if (gui-visible? 0 28) (pcmon-render-header))
  (cond
    ((= pcmon-page PAGE-LINK) (pcmon-render-link))
    ((= pcmon-page PAGE-HARDWARE) (pcmon-render-hardware))
    (else
     (let loop ((i 0))
       (if (< i 4)
           (let ((y (pcmon-sec-y i)))
             (if (gui-visible? y PCMON-CHART-H)
                 (cond ((= i 0) (pcmon-render-cpu y))
                       ((= i 1) (pcmon-render-temps y))
                       ((= i 2) (pcmon-render-gpu y))
                       (else (pcmon-render-fans y))))
             (loop (+ i 1)))))))
  (if (gui-visible? (- (gui-height) 28) 28) (pcmon-render-footer))
  (gui-flush))

;; Every buffer mode clears the marked rows and re-runs gui-render-proc
(define (pcmon-refresh y h)
  (gui-invalidate 0 y (gui-width) h))

;; 6. Firmware hooks -----------------------------------------------------------

(define gui-render-proc pcmon-render)

;; Main loop: sample whenever the feed holds a new document
(define (app-step)
  (let ((seq (json-feed-seq)))
    (if (and (> seq 0) (not (= seq pcmon-last-seq)))
        (pcmon-sample! seq))))

;; 1 Hz clock: header time, info pages, footer state (the firmware sets the
;; backlight from the light sensor: (backlight-auto))
(define (app-tick hm sec week date lux bl . rest)
  (if (theme-tick! (if (pair? rest) (car rest) 0)) (gui-invalidate 0 0 (scr-w) (gui-height)))   ; day / night
  (if (not (equal? hm pcmon-time))
      (begin
        (set! pcmon-time hm)
        (pcmon-refresh 0 28)))
  (let ((tick (if (pair? rest) (car rest) 0)))
    (cond ((not (= pcmon-page PAGE-MONITOR))
           (if (= (remainder tick 2) 0) (pcmon-refresh 30 (- (gui-height) 30))))
          ((= pcmon-last-seq 0) (pcmon-refresh (- (gui-height) 28) 28)))))

;; Button: monitor -> link status -> hardware info -> monitor
(define (app-button)
  (set! pcmon-page (remainder (+ pcmon-page 1) 3))
  (pcmon-refresh 0 (gui-height)))

(define (app-touch x y) (app-button))

;; A FASL snapshot restores Scheme state only: restart the feed task
(define (app-resume)
  (pcmon-start!)
  (pcmon-refresh 0 (gui-height)))

(pcmon-start!)
(pcmon-refresh 0 (gui-height))
