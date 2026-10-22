/* appweb.js: helpers of an app's own web page (inlined by tools/build_apps.py).
 *
 * appCall(name, fields) posts the fields form-encoded to /api/app/call?fn=name;
 * the board runs the app's (app-web name body) and answers its string. JSON
 * answers are parsed; {"success":false,"error":..} and HTTP errors throw. The
 * WebREPL's app page panel (app_web.js) answers the same calls. */
/* The board serves this page as /app?t=<token>: a sandboxed page sends no
 * Referer, so its calls carry the token back to show they come from it */
const APP_PAGE_TOKEN = new URLSearchParams(location.search).get('t') || '';
function appUrl(url) {
  return APP_PAGE_TOKEN ? url + '&t=' + encodeURIComponent(APP_PAGE_TOKEN) : url;
}

async function appCall(name, fields) {
  const body = new URLSearchParams(fields || {}).toString();
  const r = await fetch(appUrl('/api/app/call?fn=' + encodeURIComponent(name)), {
    method: 'POST', body, headers: {'Content-Type': 'application/x-www-form-urlencoded'}});
  const text = await r.text();
  let v = text;
  try { v = JSON.parse(text); } catch (e) { /* plain text */ }
  if (!r.ok || (v && typeof v === 'object' && v.success === false)) {
    throw new Error((v && v.error) || text || ('HTTP ' + r.status));
  }
  return v;
}

/* The app's own files (photos, data) in its folder on the board, through
 * /api/app/file: appFile(name) => Blob, appFileWrite(name, data) and
 * appFileDelete(name). A body goes as an ArrayBuffer (no Content-Type: the
 * request stays CORS-simple from the page's sandbox). */
async function appFileRequest(query, opts) {
  const r = await fetch(appUrl('/api/app/file?' + query), opts);
  if (r.ok && (!opts || !opts.method)) return r;
  const text = await r.text();
  let v = {};
  try { v = JSON.parse(text); } catch (e) { /* not JSON */ }
  if (!r.ok || v.success === false) throw new Error(v.error || text || ('HTTP ' + r.status));
  return v;
}
async function appFile(name) {
  return (await appFileRequest('name=' + encodeURIComponent(name))).blob();
}
async function appFileWrite(name, data) {
  const body = data && typeof data.arrayBuffer === 'function' ? await data.arrayBuffer() : data;   /* a Blob of any frame */
  return appFileRequest('name=' + encodeURIComponent(name), {method: 'POST', body});
}
async function appFileDelete(name) {
  return appFileRequest('delete=1&name=' + encodeURIComponent(name), {method: 'POST'});
}

function $(id) { return document.getElementById(id); }

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) =>
    ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
}

/* A note at the top of the page: say(text, 'ok'); kind ok, warn or bad */
let sayTimer = 0;
function say(text, kind) {
  let m = $('msg');
  if (!m) {
    m = document.createElement('div');
    m.id = 'msg';
    document.body.prepend(m);
  }
  m.textContent = text;
  m.className = kind || '';
  m.style.display = 'block';
  clearTimeout(sayTimer);
  sayTimer = setTimeout(() => { m.style.display = 'none'; }, kind === 'bad' ? 8000 : 3000);
}

/* Runs fn(), shows its error */
async function attempt(fn) {
  try { return await fn(); } catch (e) { say(e.message, 'bad'); return undefined; }
}

/* The board's page shows this one in a frame: tell it the height */
(function () {
  if (window.parent === window) return;
  const post = () => window.parent.postMessage({appHeight: document.documentElement.scrollHeight}, '*');
  window.addEventListener('load', post);
  if (window.ResizeObserver) new ResizeObserver(post).observe(document.documentElement);
})();
