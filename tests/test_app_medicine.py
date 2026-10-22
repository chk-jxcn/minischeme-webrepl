"""The medicine app on the simulator (tools/sim.py; skipped without Edge / Chrome /
Chromium): its web calls, the reminder, the page's test, records, the time
limit, sync with the app server and a reminder that a power cut (a reload of
the page) interrupts."""
import json
import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import sim  # noqa: E402


def _browser():
    try:
        return sim.find_browser()
    except sim.SimError:
        return None


# medicine (and calendar) installed in their folders; files: path -> text
INSTALL = r"""(async () => {
  const ex = wasmInstance.exports, te = new TextEncoder();
  const put = (path, bytes) => {
    const enc = te.encode(path + '\0'), p = ex.wasm_alloc_buffer(enc.length);
    new Uint8Array(wasmMemory.buffer).set(enc, p);
    const b = ex.wasm_alloc_buffer(bytes.length || 1);
    new Uint8Array(wasmMemory.buffer).set(bytes, b);
    const e = ex.wasm_fs_write(p, b, bytes.length);
    ex.wasm_free_buffer(b); ex.wasm_free_buffer(p); return e;
  };
  const get = async (u) => new Uint8Array(await (await fetch(u)).arrayBuffer());
  const files = FILES;
  const r = [put('/spiffs/apps/medicine/app.msbc', await get('apps/medicine.msbc')),
             put('/spiffs/apps/calendar/app.msbc', await get('apps/calendar.msbc'))];
  for (const [p, t] of Object.entries(files)) r.push(put(p, te.encode(t)));
  return r.every((x) => x === 0);
})()"""


def install(files):
    import json
    return INSTALL.replace("FILES", json.dumps(files))


def run_sim(args, timeout=300):
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "sim.py"), "--fresh"] + args,
                       capture_output=True, encoding="utf-8", errors="replace", timeout=timeout)
    lines = [l for l in r.stdout.splitlines() if not l.startswith(("saved ", "pressed "))]
    return r, lines


# (name . expression): each must give #t; run in order on one device
CHECKS = [
    ("starts without data", '(and (null? med-list) (null? slot-list))'),
    ("an empty name is refused", '(str-contains? (app-web "save" "name=&unit=粒") "\\"success\\":false")'),
    ("a quantity must be positive", '(str-contains? (app-web "save" "name=X&plan=count&n=0") "\\"success\\":false")'),
    ("a long-term medicine", '(begin (app-web "save" "name=A%7Cb&unit=片&plan=long") '
                             '(let ((m (med-find 1))) (and (string=? (med-name m) "A b") (string=? (med-plan-text m (med-today)) "长期"))))'),
    ("a 3-day course", '(begin (app-web "save" "name=B&unit=粒&plan=days&n=3") '
                       '(string=? (med-plan-text (med-find 2) (med-today)) "疗程: 1/3天"))'),
    ("a course that has not started", '(begin (app-web "save" (string-append "name=L&plan=days&n=3&start=" '
                                      '(number->string (+ (med-today) 5)))) (eq? (med-status (med-find 3) (med-today)) (quote later)))'),
    ("a course that is over", '(eq? (med-status (med-find 2) (+ (med-today) 3)) (quote done))'),
    ("a quantity in tenths", '(begin (app-web "save" "name=C&unit=片&plan=count&n=100") '
                             '(string=? (med-plan-text (med-find 4) (med-today)) "疗程: 0/10 片"))'),
    ("time points: a malformed one is refused", '(str-contains? (app-web "slots" "slots=8:5=1.0.0.10") "\\"success\\":false")'),
    ("time points: a repeated one is refused",
     '(str-contains? (app-web "slots" "slots=08:00=1.0.0.10|8:00=2.0.0.10") "\\"success\\":false")'),
    ("time points: an unknown medicine is refused", '(str-contains? (app-web "slots" "slots=08:00=9.0.0.10") "不存在")'),
    ("amounts per time point, every other day from tomorrow",
     '(begin (app-web "slots" (string-append "slots=19:00=4.1." (number->string (+ (med-today) 1)) ".10|8:00=1.0.0.10,2.0.0.20,4.0.0.5")) '
     '(equal? (map slot-line (slots-sorted)) (list "2|08:00|1.0.0.10,2.0.0.20,4.0.0.5" '
     '(string-append "1|19:00|4.1." (number->string (+ (med-today) 1)) ".10"))))'),
    ("schedule.ini: the times, persisting",
     '(let ((t (fs-read "schedule.ini"))) (and (str-contains? t "times = 19:00, 08:00") (str-contains? t "persist = 1")))'),
    ("not due on its off day", '(null? (med-due-for "19:00" (med-today)))'),
    ("due on its day", '(= (length (med-due-for "19:00" (+ (med-today) 1))) 1)'),
    ("the reminder takes the medicines due with their amounts",
     '(begin (med-remind! "08:00" (med-today) #f) (and (= med-due-total 3) (not med-test) '
     '(equal? (map (lambda (x) (cons (med-name (car x)) (cdr x))) med-due) (list (cons "A b" 10) (cons "B" 20) (cons "C" 5)))))'),
    ("a confirmed dose is logged and its amount taken off",
     '(begin (med-confirm!) (med-confirm!) (med-confirm!) '
     '(and (= (length (log-read (log-bucket (med-today)))) 3) (string=? (med-plan-text (med-find 4) (med-today)) "疗程: 0.5/10 片") '
     '(not (fs-exists? "pending.txt"))))'),
    ("records: in the day's 16-day file, not uploaded yet",
     '(let ((r (car (log-read (log-bucket (med-today)))))) (and (fs-exists? (string-append "log-" (number->string (quotient (med-today) 16)) ".txt")) '
     '(not (rec-synced? r)) (string=? (rec-how r) "ok") (memv (log-bucket (med-today)) sync-dirty) #t))'),
    ("a confirmed time point is not reminded again", '(begin (med-finish!) (med-remind! "08:00" (med-today) #f) (not (med-reminding?)))'),
    ("the page's test shows every medicine, whether taken or not",
     '(begin (app-web "remind" "time=08:00") (and med-test (= med-due-total 3) (med-reminding?)))'),
    ("the test logs nothing and takes nothing off",
     '(begin (med-confirm!) (med-confirm!) (med-confirm!) '
     '(and (= (length (log-read (log-bucket (med-today)))) 3) (string=? (med-plan-text (med-find 4) (med-today)) "疗程: 0.5/10 片")))'),
    ("after the test: normal again", '(begin (med-finish!) (and (not med-test) (not (med-reminding?))))'),
    ("a record changed to not taken: the amount comes back",
     '(begin (app-web "edit" (string-append "day=" (number->string (med-today)) "&time=08:00&med=4&how=skip")) '
     '(and (string=? (med-plan-text (med-find 4) (med-today)) "疗程: 0/10 片") '
     '(equal? (cdr (assv 4 (log-hows (med-today) "08:00"))) "skip")))'),
    ("and back to taken", '(begin (app-web "edit" (string-append "day=" (number->string (med-today)) "&time=08:00&med=4&how=ok")) '
     '(string=? (med-plan-text (med-find 4) (med-today)) "疗程: 0.5/10 片"))'),
    ("an unknown record is refused", '(str-contains? (app-web "edit" "day=1&time=08:00&med=4&how=ok") "没有这条记录")'),
    ("the log answers newest first with more", '(let ((a (app-web "log" ""))) (and (str-contains? a "\\"synced\\":false") '
     '(str-contains? a "\\"more\\":false")))'),
    ("a version 5 log.txt moves into the log files",
     '(begin (fs-write "log.txt" (string-append (number->string (- (med-today) 60)) "|08:00|1|ok|08:01|10")) (log-migrate!) '
     '(and (not (fs-exists? "log.txt")) (= (length (log-read (log-bucket (- (med-today) 60)))) 1) '
     '(memv (log-bucket (- (med-today) 60)) sync-dirty) #t))'),
    ("records past keep_days go", '(begin (app-web "settings" "keep_days=30") '
     '(and (= med-keep-days 30) (null? (log-read (log-bucket (- (med-today) 60)))) (pair? (log-read (log-bucket (med-today))))))'),
    ("keep_days out of range is refused", '(str-contains? (app-web "settings" "keep_days=3") "\\"success\\":false")'),
    ("the next dose: a time point and its amount",
     '(and (member (cdr (med-next-dose (med-find 4))) (list (list "08:00" 5) (list "19:00" 10))) #t)'),
    ("version 3 files are converted (the dose's amount kept)",
     '(begin (fs-write "meds.txt" "1|D|0.5粒|1|count|20|0|20") (fs-write "slots.txt" "1|08:00|1.0.0") (med-load!) '
     '(and (string=? (med-unit (med-find 1)) "粒") (= (med-units (med-find 1)) 200) '
     '(= (ent-amount (car (slot-entries (car slot-list)))) 5) (string=? (car (med-read "slots.txt")) "1|08:00|1.0.0.5")))'),
    ("a medicine's delete takes it off the time points",
     '(begin (app-web "delete" "id=1") (null? (slot-entries (car slot-list))))'),
    ("a shape and a color are kept", '(begin (app-web "save" "name=S&unit=片&plan=long&shape=oval&color=yellow") '
                                     '(let ((m (med-find (- (med-next-id) 1)))) (and (string=? (med-shape m) "oval") (string=? (med-color m) "yellow"))))'),
    ("hex colors, two for a capsule", '(begin (app-web "save" "name=H&unit=粒&shape=capsule&color=%23E84A4A&color2=%233A7BD5") '
                                      '(let ((m (med-find (- (med-next-id) 1)))) (and (string=? (med-color m) "#E84A4A") '
                                      '(string=? (med-color2 m) "#3A7BD5") (equal? (med-hex-rgb "#E84A4A") (list 232 74 74)))))'),
    ("a malformed color is refused", '(str-contains? (app-web "save" "name=Q&color=%23GG0000") "#RRGGBB")'),
    ("an unknown shape is refused", '(str-contains? (app-web "save" "name=T&shape=star") "\\"success\\":false")'),
    ("auto shapes follow the unit", '(equal? (map (lambda (u) (med-shape-of (vector 0 "x" u "long" 0 0 0 "auto" "white"))) '
                                    '(list "粒" "片" "颗" "袋" "毫升")) (list "capsule" "tablet" "ball" "sachet" "none"))'),
    ("a size out of range is refused", '(str-contains? (app-web "settings" "name_size=9") "\\"success\\":false")'),
    ("settings are saved", '(begin (app-web "settings" "max_minutes=30&name_size=4") '
                           '(and (= med-max-minutes 30) (= (med-scale "name_size") 4)))'),
    ("the log answers with amounts", '(str-contains? (app-web "log" "") "\\"how\\":\\"ok\\"")'),
    ("ids are not used again", '(let ((n (med-next-id))) (app-web "delete" (string-append "id=" (number->string (- n 1)))) '
     '(= (med-next-id) n))'),
    ("sync needs the setting", '(str-contains? (app-web "sync" "") "\\"success\\":false")'),
    ("the local records cleared", '(begin (app-web "clear" "what=log") (and (null? (log-buckets)) (null? sync-dirty) (pair? med-list)))'),
    ("everything cleared", '(begin (app-web "clear" "what=all") (and (null? med-list) (null? slot-list) (not sync-fresh)))'),
]


@unittest.skipUnless(_browser(), "no Edge / Chrome / Chromium")
class TestMedicineApp(unittest.TestCase):
    def test_web_calls_and_reminder(self):
        args = ["--wait", "1", "--js", install({}), "--config", "system.boot_app=apps/medicine/app.msbc",
                "--js", 'bootWasmDevice("test")', "--wait", "2"]
        for _, expr in CHECKS:
            args += ["--eval", expr]
        r, lines = run_sim(args)
        self.assertEqual(r.returncode, 0, r.stderr)
        results = lines[-len(CHECKS):]
        for (name, _), got in zip(CHECKS, results):
            with self.subTest(check=name):
                self.assertEqual(got, "#t")

    def test_time_limit_counts_the_rest_as_missed(self):
        files = {"/spiffs/apps/medicine/meds.txt": "1|A|片|long|0|0|0\n2|B|片|count|50|0|50",
                 "/spiffs/apps/medicine/slots.txt": "1|08:00|1.0.0.10,2.0.0.10",
                 "/spiffs/apps/medicine/config.ini": "[config]\nmax_minutes = 15\n"}
        r, lines = run_sim(["--wait", "1", "--js", install(files),
                            "--config", "system.boot_app=apps/medicine/app.msbc", "--js", 'bootWasmDevice("t")',
                            "--wait", "2", "--eval", '(begin (med-remind! "08:00" (med-today) #f) med-due-total)',
                            "--eval", "(begin (set! med-due-start (- (med-now-minutes) 20)) #t)", "--wait", "11",
                            "--eval", '(list (med-reminding?) (med-units (med-find 2)) '
                                      '(map rec-how (log-read (log-bucket (med-today)))))'])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(lines[-3], "2")
        # back to the app before; nothing taken off the count plan, both logged as missed
        self.assertEqual(lines[-1], '(#f 50 ("miss" "miss"))')

    def test_sync_with_the_app_server(self):
        # A and B (a count plan) at 08:00, sync on; the simulator's server keeps
        # the records (its database is temporary: sim.py --fresh)
        files = {"/spiffs/apps/medicine/meds.txt": "1|A|片|long|0|0|0\n2|B|片|count|50|0|50",
                 "/spiffs/apps/medicine/slots.txt": "1|08:00|1.0.0.10,2.0.0.10",
                 "/spiffs/apps/medicine/config.ini": "[config]\nsync = 1\n"}
        state = '(list (sync-pending) sync-dirty sync-names-dirty (if sync-job #t #f))'
        server = ("fetch('/api/fetch?url=' + encodeURIComponent('http://proxy.local/app/medicine?op=get&from=0'), "
                  "{headers: simDeviceHeaders()}).then(r => r.json()).then(d => d.items.map(i => i.t + ':' + (i.nm || i.n)))")
        r, lines = run_sim(["--wait", "1", "--js", install(files), "--config", "app.proxy=http://proxy.local",
                            "--config", "system.boot_app=apps/medicine/app.msbc", "--js", 'bootWasmDevice("t")',
                            "--wait", "3",
                            "--eval", '(begin (med-remind! "08:00" (med-today) #f) (med-confirm!) (med-confirm!) (med-finish!) '
                                      '(set! sync-wait 0) (sync-pending))',
                            "--wait", "12", "--eval", state, "--eval", "sync-msg", "--js", server,
                            # the board's copy wins: an edit goes up again
                            "--eval", '(begin (log-edit! (med-today) "08:00" 2 "skip") (set! sync-wait 0) (sync-pending))',
                            "--wait", "8", "--eval", state, "--js", server,
                            # cleared here, downloaded back (the server keeps them)
                            "--eval", '(begin (med-clear! #f) (app-web "download" "days=3") (length (log-buckets)))',
                            "--wait", "8",
                            "--eval", '(map (lambda (r) (list (rec-med r) (rec-how r) (rec-synced? r))) (log-read (log-bucket (med-today))))',
                            # a new install with sync off: the last 30 days come back once, sync turns on
                            "--eval", '(begin (med-clear! #t) (app-config-set! "sync" "0") (fs-remove "sync.txt") (sync-load!) '
                                      '(set! sync-wait 0) (list sync-fresh (sync-on?)))',
                            "--wait", "8",
                            "--eval", '(list (length (log-read (log-bucket (med-today)))) sync-fresh (sync-on?) (length (names-load)))'])
        self.assertEqual(r.returncode, 0, r.stderr)
        out = lines[-11:]
        self.assertEqual(out[0], "2", "two records to upload")
        self.assertEqual(out[1], "(0 () #f #f)", "uploaded: names, then the records")
        self.assertIn("已同步到应用服务器", out[2])
        self.assertEqual(json.loads(out[3]), ["r:A", "r:B", "end:2"])
        self.assertEqual(out[4], "1")
        self.assertEqual(out[5], "(0 () #f #f)")
        self.assertEqual(json.loads(out[6]), ["r:A", "r:B", "end:2"])
        self.assertEqual(out[7], "0")
        self.assertEqual(out[8], '((1 "ok" #t) (2 "skip" #t))', "downloaded: as the board last had them, on the server")
        self.assertEqual(out[9], "(#t #f)")
        self.assertEqual(out[10], "(2 #f #t 2)", "restored on a new install, sync on, the names kept")

    def test_a_power_cut_does_not_end_the_reminder(self):
        # calendar is the boot app; medicine (persist = 1) starts at 08:00; after
        # one confirm the page reloads (the power cut): the board comes back to
        # the reminder with the other medicine, then returns to calendar
        files = {"/spiffs/apps/medicine/meds.txt": "1|A|片|long|0|0|0\n2|B|粒|count|100|0|100",
                 "/spiffs/apps/medicine/slots.txt": "1|08:00|1.0.0.10,2.0.0.20",
                 "/spiffs/apps/medicine/schedule.ini": "[schedule]\ntimes = 08:00\npersist = 1\n"}
        state = '(list (cadr (app-info)) (app-scheduled) med-due-total med-due-done (map (lambda (x) (med-name (car x))) med-due))'
        r, lines = run_sim(["--wait", "1", "--js", install(files),
                            "--config", "system.boot_app=apps/calendar/app.msbc", "--js", 'bootWasmDevice("t")',
                            "--wait", "2", "--js", "wasmInstance.exports.wasm_schedule_fire(8, 0)", "--wait", "3",
                            "--eval", state, "--press", "short", "--wait", "1",
                            "--js", "simStorage.poll(wasmInstance.exports, () => wasmMemory); "
                                    "new Promise(r => setTimeout(r, 1500)).then(() => location.reload())",
                            "--wait", "8", "--eval", state, "--press", "short", "--wait", "6",
                            "--eval", '(list (cadr (app-info)) (fs-exists? "/spiffs/.sched_launch"))'])
        self.assertEqual(r.returncode, 0, r.stderr)
        # the outputs: ... state, the reload's null, state, the end
        self.assertEqual(lines[-4], '("medicine" "08:00" 2 0 ("A" "B"))')
        self.assertEqual(lines[-2], '("medicine" "08:00" 2 1 ("B"))', "resumed after the power cut")
        self.assertEqual(lines[-1], '("calendar" #f)', "back to the boot app, the launch forgotten")


if __name__ == "__main__":
    unittest.main()
