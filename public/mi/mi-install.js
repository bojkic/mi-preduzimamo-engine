/* Platform PWA install nudge. Captures beforeinstallprompt; shows a branded
   banner when ?app=1 (post-registration landing) or on the 3rd visit. When
   the browser cannot offer a prompt, the same banner gives manual guidance.
   Localized copy is passed via data attributes on the script tag and read at
   load time (before any async work), with generic Serbian strings as fallbacks. */
(function () {
  "use strict";
  // Capture data attributes synchronously at load time — document.currentScript
  // is only available during initial script execution, not inside callbacks.
  var _script = document.currentScript;
  var _data = _script ? _script.dataset : {};
  var INSTALL_TEXT = _data.installText || "Instaliraj aplikaciju platforme na telefon.";
  var IOS_TEXT = _data.iosText ||
    "Dodaj platformu na početni ekran: dodirni ⎖ Share pa „Add to Home Screen“.";
  var MANUAL_TEXT = _data.manualText ||
    "Otvori meni preglednika i izaberi „Dodaj platformu na početni ekran“ ili „Instaliraj aplikaciju platforme“.";
  var WEBVIEW_TEXT = _data.webviewText ||
    "Otvori platformu u Chromeu ili Safariju da bi je dodao/dodala na početni ekran.";
  var INSTALL_LABEL = _data.installLabel || "Instaliraj";
  var DISMISS_LABEL = _data.dismissLabel || "Ne sada";

  var KEY = "miInstall";
  var SESSION_FORCE_KEY = "miInstallForceOffer";
  var deferred = null;
  var fallbackTimer = null;
  var bannerMode = null;
  var params = new URLSearchParams(window.location.search || "");
  var force = params.get("app") === "1";
  var forceWasOfferedInSession = false;

  // app=1 is a one-time hand-off marker from the authenticated success page.
  // Remove only that value in-place so a refresh cannot force the offer again,
  // while preserving every other query parameter and the hash fragment.
  function consumeAppMarker() {
    if (!force || !window.history || typeof window.history.replaceState !== "function") return;
    try {
      var rawSearch = window.location.search || "";
      var kept = rawSearch.replace(/^\?/, "").split("&").filter(function (part) {
        if (!part) return true;
        var separator = part.indexOf("=");
        var rawKey = separator === -1 ? part : part.slice(0, separator);
        var rawValue = separator === -1 ? "" : part.slice(separator + 1);
        var key;
        var value;
        try {
          key = decodeURIComponent(rawKey.replace(/\+/g, " "));
          value = decodeURIComponent(rawValue.replace(/\+/g, " "));
        } catch (e) {
          return true;
        }
        return !(key === "app" && value === "1");
      }).join("&");
      var target = (window.location.pathname || "") + (kept ? "?" + kept : "") +
        (window.location.hash || "");
      window.history.replaceState(window.history.state || null, document.title, target);
    } catch (e) { /* an unusual history implementation must not block sign-in */ }
  }
  consumeAppMarker();

  // A successful landing gets one offer per browser session. Keeping this
  // separate from localStorage prevents a refresh from becoming a new generic
  // 3-visit offer, while allowing a later app=1 landing to offer again.
  try {
    if (force) {
      window.sessionStorage.setItem(SESSION_FORCE_KEY, "1");
    } else {
      forceWasOfferedInSession = window.sessionStorage.getItem(SESSION_FORCE_KEY) === "1";
    }
  } catch (e) { /* session storage may be unavailable in private webviews */ }

  var standalone = window.matchMedia("(display-mode: standalone)").matches ||
    window.navigator.standalone === true;
  // An installed PWA gets no install offer, but still consumes app=1 above.
  if (standalone) return;

  var state = {};
  try { state = JSON.parse(localStorage.getItem(KEY) || "{}"); } catch (e) { state = {}; }
  if (state.dismissed && !force) return;
  state.visits = (state.visits || 0) + 1;
  function saveState() {
    try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) { /* private mode */ }
  }
  saveState();

  var userAgent = navigator.userAgent || "";
  var isIos = /iphone|ipad|ipod/i.test(userAgent);
  // Embedded webviews cannot use the browser's install prompt. Their guidance
  // explicitly asks the user to open the page in a real browser.
  var isWebView = /;\s*wv\)|\bFBAN|\bFBAV|Instagram|\bLine\/|;\s*WebView|GSA\//i.test(userAgent) ||
    (/iphone|ipad|ipod/i.test(userAgent) && /AppleWebKit/i.test(userAgent) &&
      !/(Safari|CriOS|FxiOS|EdgiOS|OPiOS)/i.test(userAgent));

  // --- Cookie-consent gating ------------------------------------------------
  function consentBannerActive() {
    var banner = document.getElementById("dc-dialog-wrapper");
    return !!(banner && !banner.hidden && banner.getClientRects().length);
  }

  function consentResolved() {
    return !consentBannerActive();
  }

  function whenConsentResolved(fn) {
    if (consentResolved()) { fn(); return; }
    var done = false;
    var observer = null;
    function fire() {
      if (done || !consentResolved()) return;
      done = true;
      document.removeEventListener("dataconsent", fire);
      if (observer) observer.disconnect();
      fn();
    }
    document.addEventListener("dataconsent", fire);
    var banner = document.getElementById("dc-dialog-wrapper");
    if (banner && "MutationObserver" in window) {
      observer = new MutationObserver(fire);
      observer.observe(banner, { attributes: true, attributeFilter: ["hidden", "class", "style"] });
    }
  }

  function eligible() {
    return (force || (!forceWasOfferedInSession && state.visits >= 3)) &&
      (!state.dismissed || force);
  }

  function clearFallbackTimer() {
    if (fallbackTimer !== null) {
      clearTimeout(fallbackTimer);
      fallbackTimer = null;
    }
  }

  window.addEventListener("beforeinstallprompt", function (e) {
    e.preventDefault();
    deferred = e;
    clearFallbackTimer();
    if (eligible()) whenConsentResolved(function () { show("prompt"); });
  });
  window.addEventListener("appinstalled", function () {
    state.dismissed = true;
    force = false;
    clearFallbackTimer();
    saveState();
    remove();
  });

  function scheduleOffer() {
    if (!eligible()) return;
    if (isWebView) {
      whenConsentResolved(function () { show("webview"); });
    } else if (isIos) {
      whenConsentResolved(function () { show("ios"); });
    } else {
      // beforeinstallprompt can arrive after this script. Keep listening and
      // use manual guidance only if the browser never supplies the event.
      fallbackTimer = setTimeout(function () {
        fallbackTimer = null;
        if (eligible() && !deferred) {
          whenConsentResolved(function () { show("manual"); });
        }
      }, 1500);
    }
  }
  scheduleOffer();

  function escHtml(str) {
    return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  function copyFor(mode) {
    if (mode === "ios") return IOS_TEXT;
    if (mode === "webview") return WEBVIEW_TEXT;
    return MANUAL_TEXT;
  }

  function show(mode) {
    if (!eligible()) return;
    var installable = mode === "prompt" && !!deferred;
    var existing = document.getElementById("mi-install-banner");
    // A late prompt event upgrades an already-visible manual banner. Avoid
    // creating a competing banner or replacing an equivalent one.
    if (existing && (bannerMode === "prompt" || !installable)) return;
    if (existing) remove();
    if (consentBannerActive()) { whenConsentResolved(function () { show(mode); }); return; }
    bannerMode = installable ? "prompt" : mode;
    document.documentElement.classList.add("mi-install-open");
    var el = document.createElement("div");
    el.id = "mi-install-banner";
    var text = installable ? INSTALL_TEXT : copyFor(mode);
    el.setAttribute("role", "dialog");
    el.setAttribute("aria-label", text);
    el.setAttribute("aria-live", "polite");
    el.style.cssText = "position:fixed;left:50%;bottom:1rem;transform:translateX(-50%);" +
      "z-index:1100;background:#1d2d50;color:#fff;border-radius:12px;padding:0.9rem 1rem;" +
      "box-shadow:0 8px 30px rgba(0,0,0,.25);box-sizing:border-box;" +
      "max-width:min(22rem, calc(100% - 2rem));width:calc(100% - 2rem);" +
      "font:600 0.95rem/1.4 system-ui,sans-serif;text-align:center;";
    el.innerHTML = escHtml(text) + (installable
      ? " <button id=\"mi-install-go\">" + escHtml(INSTALL_LABEL) + "</button>"
      : "") +
      " <button id=\"mi-install-close\">" + escHtml(DISMISS_LABEL) + "</button>";
    [].forEach.call(el.querySelectorAll("button"), function (b) {
      b.style.cssText = "margin:0.5rem 0.25rem 0;padding:0.6rem 1rem;border-radius:999px;" +
        "border:0;font-weight:700;cursor:pointer;background:#c25435;color:#fff;min-height:2.75rem;";
    });
    document.body.appendChild(el);
    var go = document.getElementById("mi-install-go");
    if (go) go.addEventListener("click", function () {
      if (!deferred) return remove();
      var event = deferred;
      deferred = null;
      force = false;
      try { event.prompt(); } catch (e) { remove(); return; }
      if (event.userChoice && typeof event.userChoice.then === "function") {
        event.userChoice.then(function (choice) {
          if (choice && choice.outcome === "dismissed") {
            state.dismissed = true;
            saveState();
          }
          remove();
        }, remove);
      } else {
        remove();
      }
    });
    document.getElementById("mi-install-close").addEventListener("click", function () {
      state.dismissed = true;
      force = false;
      deferred = null;
      clearFallbackTimer();
      saveState();
      remove();
    });
  }

  function remove() {
    bannerMode = null;
    document.documentElement.classList.remove("mi-install-open");
    var el = document.getElementById("mi-install-banner");
    if (el) el.remove();
  }
})();
