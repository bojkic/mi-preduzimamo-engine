/* ============================================================
   MI bot lazy loader.

   Reads non-executable config from <meta name="mi-chat-config">, renders a
   lightweight launcher, and loads the full chat CSS/JS only after user intent.
   ============================================================ */
(function () {
  "use strict";

  function ready(fn) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", fn, { once: true });
    } else {
      fn();
    }
  }

  function readConfig() {
    var meta = document.querySelector('meta[name="mi-chat-config"]');
    if (!meta) return null;

    try {
      var cfg = JSON.parse(meta.getAttribute("content") || "{}");
      cfg.cssSrc = meta.getAttribute("data-css-src");
      cfg.jsSrc = meta.getAttribute("data-js-src");
      return cfg;
    } catch (_err) {
      return null;
    }
  }

  function appendCss(src) {
    if (!src) return Promise.resolve();
    if (document.querySelector('link[data-mi-chat-css="true"]')) return Promise.resolve();

    return new Promise(function (resolve) {
      var link = document.createElement("link");
      link.rel = "stylesheet";
      link.href = src;
      link.media = "all";
      link.setAttribute("data-mi-chat-css", "true");
      link.addEventListener("load", resolve, { once: true });
      link.addEventListener("error", resolve, { once: true });
      document.head.appendChild(link);
      window.setTimeout(resolve, 1500);
    });
  }

  function appendScript(src) {
    if (!src) return Promise.reject(new Error("missing chat script"));
    if (document.querySelector('script[data-mi-chat-js="true"]')) return Promise.resolve();

    return new Promise(function (resolve, reject) {
      var script = document.createElement("script");
      script.src = src;
      script.defer = true;
      script.setAttribute("data-mi-chat-js", "true");
      script.addEventListener("load", resolve, { once: true });
      script.addEventListener("error", reject, { once: true });
      document.head.appendChild(script);
    });
  }

  function svgHeart() {
    return '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 21s-7.5-4.6-10-9.3C.3 8 1.9 4.4 5.4 4c2-.2 3.7.8 4.6 2.3.9-1.5 2.6-2.5 4.6-2.3 3.5.4 5.1 4 3.4 7.7C19.5 16.4 12 21 12 21z"/></svg>';
  }

  function buildLauncher(cfg) {
    var t = cfg.i18n || {};
    var launcher = document.createElement("button");
    launcher.type = "button";
    launcher.className = "mi-chat-loader__bubble";
    launcher.setAttribute("aria-label", t.aria_open || t.bubble_label || "Chat");
    launcher.innerHTML = '<span class="mi-chat-loader__icon">' + svgHeart() + '</span>';

    if (t.bubble_label) {
      var label = document.createElement("span");
      label.className = "mi-chat-loader__label";
      label.textContent = t.bubble_label;
      launcher.appendChild(label);
    }

    return launcher;
  }

  ready(function () {
    var cfg = readConfig();
    if (!cfg || cfg.disabled || document.getElementById("mi-chat")) return;

    var launcher = buildLauncher(cfg);
    var loading = false;

    launcher.addEventListener("click", function () {
      if (loading) return;
      loading = true;
      launcher.disabled = true;
      launcher.classList.add("is-loading");

      window.MI_CHAT = Object.assign({}, cfg, { autoOpen: true });

      appendCss(cfg.cssSrc)
        .then(function () { return appendScript(cfg.jsSrc); })
        .then(function () { launcher.remove(); })
        .catch(function () {
          loading = false;
          launcher.disabled = false;
          launcher.classList.remove("is-loading");
        });
    });

    document.addEventListener("click", function (event) {
      var trigger = event.target.closest && event.target.closest("[data-mi-chat-open]");
      if (!trigger) return;
      event.preventDefault();
      var draft = trigger.getAttribute("data-mi-chat-draft");
      if (draft) window.MI_CHAT_PENDING_DRAFT = String(draft).slice(0, 1000);
      if (window.MI_CHAT_WIDGET) {
        window.MI_CHAT_WIDGET.open();
        if (draft) window.MI_CHAT_WIDGET.prefill(draft);
      } else { launcher.click(); }
    });

    document.body.appendChild(launcher);
  });
})();
