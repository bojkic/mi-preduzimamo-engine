/* ============================================================
   MI bot — floating web-chat widget (vanilla JS, no deps)
   Builds a bubble + chat panel into <body> when loaded and
   talks to the host-provided chat endpoint (same-origin JSON fetch,
   CSRF + X-Requested-With). All config and localized strings come
   from window.MI_CHAT, set by /mi/mi-chat-loader.js after user intent.

   Accessibility: bubble has aria-label; panel is role=dialog, focus
   is trapped while open, Esc closes and returns focus to the bubble.
   Respects prefers-reduced-motion via CSS (no JS animation here).
   ============================================================ */
(function () {
  "use strict";

  var CFG = window.MI_CHAT || {};
  // Bail quietly if config is missing (e.g. asset cached but head not updated)
  // or if the widget is suppressed on this page (the bot showcase).
  if (!CFG || CFG.disabled) return;

  var T = CFG.i18n || {};
  var ENDPOINT = CFG.endpoint;
  if (!ENDPOINT) return;
  var QUICK = Array.isArray(CFG.quick) ? CFG.quick : [];
  var FEEDBACK = T.feedback || {};
  var LOC_TTL_MS = 5 * 60 * 1000;
  // Ordinary turns have a ten-second server budget. A turn that explicitly
  // asks for current location gets up to eight seconds for GPS, then a fresh
  // ten seconds for the server; the UI never pretends those budgets overlap.
  var LOCATION_TIMEOUT_MS = 8000;
  var SERVER_TIMEOUT_MS = 10000;
  var FEEDBACK_TIMEOUT_MS = 10000;
  var MAX_LOCATION_ACCURACY_METERS = 1000000;

  // ---- small DOM helpers --------------------------------------------------
  function el(tag, cls, attrs) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (attrs) {
      Object.keys(attrs).forEach(function (k) { node.setAttribute(k, attrs[k]); });
    }
    return node;
  }
  function svg(markup) {
    var span = el("span", "mi-chat__ico");
    span.setAttribute("aria-hidden", "true");
    span.innerHTML = markup;
    return span.firstChild;
  }

  // ---- inline icons (same-origin, no external requests) -------------------
  var ICON_HEART =
    '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 21s-7.5-4.6-10-9.3C.3 8 1.9 4.4 5.4 4c2-.2 3.7.8 4.6 2.3.9-1.5 2.6-2.5 4.6-2.3 3.5.4 5.1 4 3.4 7.7C19.5 16.4 12 21 12 21z"/></svg>';
  var ICON_CLOSE =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>';
  var ICON_SEND =
    '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3.4 3.3 21 12 3.4 20.7l2.1-7.2 8.5-1.5-8.5-1.5z"/></svg>';
  var ICON_LOCATION =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><path d="M12 21s7-6.1 7-12a7 7 0 1 0-14 0c0 5.9 7 12 7 12z"/><circle cx="12" cy="9" r="2.3"/></svg>';
  var ICON_THUMBS_UP =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7 10v11"/><path d="M15 5.9 14 10h5.8a2 2 0 0 1 2 2.3l-.9 6a3 3 0 0 1-3 2.7H7"/><path d="M7 10H4a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h3"/><path d="M15 5.9V4a2 2 0 0 0-2-2l-5 8"/></svg>';
  var ICON_THUMBS_DOWN =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 14V3"/><path d="M9 18.1 10 14H4.2a2 2 0 0 1-2-2.3l.9-6A3 3 0 0 1 6 3h11"/><path d="M17 14h3a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2h-3"/><path d="M9 18.1V20a2 2 0 0 0 2 2l5-8"/></svg>';

  // ---- state --------------------------------------------------------------
  var root, panel, body, field, sendBtn, locateBtn, bubble, lastFocused;
  var consentWatchers = [];
  var greeted = false;
  var sending = false;
  var turnGeneration = 0;
  var lastLocation = null;
  var lastQuickWrap = null;

  // ---- markdown-lite link rendering (safe) --------------------------------
  // Replies are untrusted data. Build text and anchors as DOM nodes so a
  // hostile reply can never provide markup or an executable attribute.
  function linkPunctuation(url) {
    var value = url;
    while (/[.,;:!?]$/.test(value)) value = value.slice(0, -1);
    while (/[\)\]\}]$/.test(value)) {
      var closing = value.charAt(value.length - 1);
      var opening = closing === ")" ? "(" : closing === "]" ? "[" : "{";
      var opens = (value.match(new RegExp("\\" + opening, "g")) || []).length;
      var closes = (value.match(new RegExp("\\" + closing, "g")) || []).length;
      if (closes <= opens) break;
      value = value.slice(0, -1);
    }
    return value;
  }

  function validatedLink(url) {
    if (!url || /[\\\u0000-\u001f]/.test(url)) return null;
    var external = /^https?:\/\//i.test(url);
    var rootRelative = /^\/(?!\/)/.test(url);
    if (!external && !rootRelative) return null;
    try {
      var parsed = new URL(url, window.location.origin);
      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
      if (rootRelative && parsed.origin !== window.location.origin) return null;
      return url;
    } catch (_err) {
      return null;
    }
  }

  function appendSafeText(container, text) {
    var source = text == null ? "" : String(text);
    var matcher = /(?:https?:\/\/|\/(?!\/))[^\s<>"']+/gi;
    var cursor = 0;
    var match;
    while ((match = matcher.exec(source))) {
      var raw = match[0];
      var candidate = linkPunctuation(raw);
      // The negative lookahead prevents a match at the first slash of a
      // protocol-relative URL; also reject a second-slash match on the next
      // regex position so `//host` stays plain text in its entirety.
      var protocolRelative = raw.charAt(0) === "/" && match.index > 0 && source.charAt(match.index - 1) === "/";
      var escapedSlash = raw.charAt(0) === "/" && match.index > 0 && source.charAt(match.index - 1) === "\\";
      var prefixedScheme = raw.charAt(0) === "/" && /[A-Za-z][A-Za-z0-9+.-]*:$/.test(source.slice(0, match.index));
      var rootInMarkup = raw.charAt(0) === "/" && match.index > 0 && /[<>"'=]/.test(source.charAt(match.index - 1));
      // Units, zone names and ratios (KM/h, crvena/I, 3/4) are not paths.
      // Test the prefix by Unicode code point, including combining marks.
      var rootInWord = raw.charAt(0) === "/" && /[\p{L}\p{M}\p{N}_]$/u.test(source.slice(0, match.index));
      var href = protocolRelative || escapedSlash || prefixedScheme || rootInMarkup || rootInWord ? null : validatedLink(candidate);
      var end = match.index + (href ? candidate.length : raw.length);
      if (match.index > cursor) container.appendChild(document.createTextNode(source.slice(cursor, match.index)));
      if (href) {
        var anchor = el("a", null, { href: href, target: "_blank", rel: "noopener noreferrer" });
        anchor.textContent = candidate;
        container.appendChild(anchor);
      } else {
        container.appendChild(document.createTextNode(raw));
      }
      cursor = end;
      matcher.lastIndex = end;
    }
    if (cursor < source.length) container.appendChild(document.createTextNode(source.slice(cursor)));
  }

  // ---- transcript rendering ----------------------------------------------
  function scrollToEnd() { body.scrollTop = body.scrollHeight; }

  function addBubble(text, outgoing) {
    var row = el("div", "mi-chat__row " + (outgoing ? "is-out" : "is-in"));
    var msg = el("div", "mi-chat__bubble-msg");
    appendSafeText(msg, text);
    row.appendChild(msg);
    body.appendChild(row);
    scrollToEnd();
    return row;
  }

  function validFeedback(feedback) {
    return feedback && feedback.id && feedback.url && feedback.token;
  }

  // Thumbs on every answer; on a turn the bot could not resolve the server
  // also sets offer_capture and ONE consent button appears below them. The
  // click posts value "share_question" through the same signed token, so
  // nothing is kept without the citizen asking for it.
  function addFeedback(row, feedback, offerCapture) {
    if (!validFeedback(feedback)) return;

    var wrap = el("div", "mi-chat__feedback", { "aria-label": FEEDBACK.label || "Rate this answer" });
    var disclosure = el("p", "mi-chat__feedback-disclosure");
    disclosure.textContent = FEEDBACK.retention_disclosure || "Feedback is optional. Clicking any button allows your question and this answer to be saved for private review, without linking them to your account.";
    var status = el("span", "mi-chat__feedback-status", { role: "status", "aria-live": "polite" });
    var up = feedbackButton("helpful", FEEDBACK.helpful || "Helpful", ICON_THUMBS_UP);
    var down = feedbackButton("not_helpful", FEEDBACK.not_helpful || "Not helpful", ICON_THUMBS_DOWN);

    up.addEventListener("click", function () { submitFeedback(feedback, "helpful", wrap, status); });
    down.addEventListener("click", function () { submitFeedback(feedback, "not_helpful", wrap, status); });

    wrap.appendChild(disclosure);
    wrap.appendChild(up);
    wrap.appendChild(down);
    if (offerCapture === true) {
      var share = el("button", "mi-chat__feedback-button mi-chat__feedback-button--share", {
        type: "button",
        "aria-pressed": "false",
        "data-value": "share_question"
      });
      share.textContent = FEEDBACK.share_question || "Save question for review";
      share.addEventListener("click", function () { submitFeedback(feedback, "share_question", wrap, status); });
      wrap.appendChild(share);
    }
    wrap.appendChild(status);
    row.appendChild(wrap);
    scrollToEnd();
  }

  function feedbackButton(value, label, icon) {
    var button = el("button", "mi-chat__feedback-button", {
      type: "button",
      "aria-label": label,
      "aria-pressed": "false",
      "data-value": value
    });
    button.appendChild(svg(icon));
    button.appendChild(document.createTextNode(label));
    return button;
  }

  function submitFeedback(feedback, value, wrap, status) {
    var buttons = Array.prototype.slice.call(wrap.querySelectorAll(".mi-chat__feedback-button"));
    var selected = buttons.find(function (button) { return button.getAttribute("data-value") === value; });
    if (!selected || selected.disabled) return;
    buttons.forEach(function (button) { button.disabled = true; });
    status.textContent = "";

    timedFetch(feedback.url, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-Requested-With": "XMLHttpRequest",
        "X-CSRF-Token": csrfToken()
      },
      body: JSON.stringify({ reply_id: feedback.id, token: feedback.token, value: value })
    }, FEEDBACK_TIMEOUT_MS, function (res) {
        if (res.status === 422) {
          var unavailable = new Error("feedback unavailable");
          unavailable.feedbackUnavailable = true;
          throw unavailable;
        }
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json().then(function (body) {
          if (!body || body.status !== "ok") throw new Error("feedback save failed");
          return body;
        });
      })
      .then(function () {
        var shared = value === "share_question";
        buttons.forEach(function (button) {
          var own = button.getAttribute("data-value") === value;
          button.setAttribute("aria-pressed", String(own));
          // The other thumb updates this reply's existing session rating.
          // Saving the question is redundant once either thumb has saved it.
          button.disabled = own || button.getAttribute("data-value") === "share_question";
        });
        status.textContent = shared
          ? (FEEDBACK.shared || "Sačuvano. Hvala!")
          : (FEEDBACK.thanks || "Thanks for the feedback.");
      })
      .catch(function (error) {
        var unavailable = !!(error && error.feedbackUnavailable);
        buttons.forEach(function (button) { button.disabled = unavailable; });
        status.textContent = unavailable
          ? (FEEDBACK.unavailable || "This rating has expired or is unavailable. You can rate a new answer.")
          : (FEEDBACK.error || "Feedback was not saved. Please try again.");
      });
  }

  // A timeout only bounds this browser's wait. It is deliberately not treated
  // as proof that the server did not save an effect; retries remain explicit.
  function timedFetch(url, options, timeoutMs, transform) {
    var controller = null;
    if (window.AbortController) controller = new AbortController();
    var requestOptions = Object.assign({}, options);
    if (controller) requestOptions.signal = controller.signal;
    var timer;
    var request = Promise.resolve().then(function () { return fetch(url, requestOptions); })
      .then(function (response) { return transform ? transform(response) : response; });
    var timeout = new Promise(function (_resolve, reject) {
      timer = window.setTimeout(function () {
        if (controller) controller.abort();
        reject(new Error("request timeout"));
      }, timeoutMs);
    });
    return Promise.race([request, timeout]).then(function (result) {
      window.clearTimeout(timer);
      return result;
    }, function (error) {
      window.clearTimeout(timer);
      throw error;
    });
  }

  function addSticker(url) {
    if (!url) return;
    var wrap = el("div", "mi-chat__sticker");
    var img = el("img", null, { src: url, alt: "", loading: "lazy" });
    wrap.appendChild(img);
    body.appendChild(wrap);
    scrollToEnd();
  }

  // Quick-reply chips. Each chip either navigates to a page (when it carries a
  // target — `url` from the server contract, or `href` from the client-built
  // default menu) or sends a canned message. Server-sent civic-shortcut chips
  // are { label, url }; the client default menu uses { label, href|send }.
  function addQuickReplies(items) {
    if (!items || !items.length) return;
    var wrap = el("div", "mi-chat__quick");
    items.forEach(function (item) {
      var label = typeof item === "string" ? item : item.label;
      var target = item && (item.url || item.href);
      var payload = (item && item.send) || label;
      var chip = el("button", "mi-chat__chip", { type: "button" });
      chip.textContent = label;
      // Expose the configured action for accessibility/browser diagnostics.
      // The handler uses these same captured values, not mutable attributes.
      chip.setAttribute("data-mi-chat-action", target ? "navigate" : "send");
      chip.setAttribute("data-mi-chat-value", target || payload);
      chip.addEventListener("click", function () {
        if (target) {
          close();
          window.location.assign(target);
          return;
        }
        submit(payload);
      });
      wrap.appendChild(chip);
    });
    body.appendChild(wrap);
    lastQuickWrap = wrap;
    scrollToEnd();
  }

  function replaceQuickReplies(items) {
    if (!items || !items.length) return;
    if (lastQuickWrap) { lastQuickWrap.remove(); lastQuickWrap = null; }
    addQuickReplies(items);
  }

  var typingNode = null;
  function showTyping() {
    if (typingNode) return;
    typingNode = el("div", "mi-chat__typing", { "aria-hidden": "true" });
    typingNode.appendChild(el("span"));
    typingNode.appendChild(el("span"));
    typingNode.appendChild(el("span"));
    body.appendChild(typingNode);
    scrollToEnd();
  }
  function hideTyping() {
    if (typingNode) { typingNode.remove(); typingNode = null; }
  }

  // ---- network ------------------------------------------------------------
  function csrfToken() {
    var m = document.querySelector('meta[name="csrf-token"]');
    return m ? m.getAttribute("content") : "";
  }

  function foldedText(text) {
    return String(text || "")
      .toLowerCase()
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "");
  }

  function locationRequested(text) {
    var folded = foldedText(text);
    // Mentioning location while refusing it must not request or reuse GPS.
    if (/(?:^|[\s,])(?:bez|without|без|nemoj(?:te)?|немој(?:те)?|ne|не|do not|don't|dont)\s+[^.!?;\n]{0,60}(?:lokacij[a-z]*|локациј[\u0400-\u04FF]*|location)(?:$|[^A-Za-z\u0400-\u04FF])/.test(folded)) return false;
    var words = " " + folded.replace(/[^A-Za-z0-9\u0400-\u04FF]+/g, " ") + " ";
    return [
      "odavde", "ovdje", "ovde", "ova lokacija", "ovoj lokaciji", "ovu lokaciju",
      "trenutna lokacija", "trenutne lokacije", "trenutnoj lokaciji", "moja lokacija", "moje lokacije", "mojoj lokaciji", "moju lokaciju", "tu", "from here", "here", "my location",
      "одавде", "овдје", "овде", "ова локација", "овој локацији", "ову локацију",
      "моја локација", "моје локације", "мојој локацији", "моју локацију", "тренутна локација", "тренутне локације", "тренутној локацији"
    ].some(function (term) { return words.indexOf(" " + term + " ") !== -1; });
  }

  function freshLocation() {
    if (!lastLocation || !lastLocation.at) return null;
    if (Date.now() - lastLocation.at > LOC_TTL_MS) return null;
    return validLocation(lastLocation) ? lastLocation : null;
  }

  function finiteBounded(value, min, max) {
    if (value === null || value === undefined || String(value).trim() === "") return null;
    var number = Number(value);
    return isFinite(number) && number >= min && number <= max ? number : null;
  }

  function validLocation(location) {
    if (!location) return false;
    return finiteBounded(location.latitude, -90, 90) !== null &&
      finiteBounded(location.longitude, -180, 180) !== null &&
      finiteBounded(location.accuracy, 0, MAX_LOCATION_ACCURACY_METERS) !== null &&
      location.consent === true && location.provenance === "browser_geolocation";
  }

  function syncLocationButton() {
    if (!locateBtn) return;
    locateBtn.classList.toggle("is-active", !!freshLocation());
  }

  function requestBrowserLocation() {
    return new Promise(function (resolve, reject) {
      if (!navigator.geolocation) {
        reject(new Error("geolocation unavailable"));
        return;
      }
      navigator.geolocation.getCurrentPosition(function (pos) {
        var location = {
          latitude: finiteBounded(pos.coords.latitude, -90, 90),
          longitude: finiteBounded(pos.coords.longitude, -180, 180),
          accuracy: finiteBounded(pos.coords.accuracy, 0, MAX_LOCATION_ACCURACY_METERS),
          purpose: "current_location",
          consent: true,
          provenance: "browser_geolocation",
          at: Date.now()
        };
        if (!validLocation(location)) {
          reject(new Error("invalid geolocation"));
          return;
        }
        lastLocation = location;
        syncLocationButton();
        resolve(lastLocation);
      }, reject, {
        enableHighAccuracy: true,
        timeout: LOCATION_TIMEOUT_MS,
        maximumAge: LOC_TTL_MS
      });
    });
  }

  function locationForMessage(text) {
    if (!locationRequested(text)) {
      lastLocation = null;
      syncLocationButton();
      return Promise.resolve(null);
    }
    var cached = freshLocation();
    lastLocation = null;
    syncLocationButton();
    if (cached) return Promise.resolve(cached);
    return requestBrowserLocation().catch(function () { return null; });
  }

  function submitPayload(text, location) {
    var payload = { message: text };
    if (location) {
      payload.location = {
        latitude: location.latitude,
        longitude: location.longitude,
        accuracy: location.accuracy,
        purpose: location.purpose,
        consent: location.consent,
        provenance: location.provenance
      };
    }
    return payload;
  }

  function submit(text) {
    text = (text || "").trim();
    if (!text || sending) return;

    addBubble(text, true);
    field.value = "";
    autoGrow();
    sending = true;
    sendBtn.disabled = true;
    showTyping();

    var requestController = window.AbortController ? new AbortController() : null;
    var requestExpired = false;
    var requestGeneration = ++turnGeneration;
    var turnTimeout = locationRequested(text) ? LOCATION_TIMEOUT_MS + SERVER_TIMEOUT_MS : SERVER_TIMEOUT_MS;
    var rejectDeadline;
    var deadline = new Promise(function (_resolve, reject) { rejectDeadline = reject; });
    var requestTimer = window.setTimeout(function () {
      requestExpired = true;
      if (requestController) requestController.abort();
      rejectDeadline(new Error("request timeout"));
    }, turnTimeout);

    var chatRequest = locationForMessage(text)
      .then(function (location) {
        if (requestExpired) throw new Error("request timeout");
        var options = {
          method: "POST",
          credentials: "same-origin",
          headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
            "X-Requested-With": "XMLHttpRequest",
            "X-CSRF-Token": csrfToken()
          },
          body: JSON.stringify(submitPayload(text, location))
        };
        if (requestController) options.signal = requestController.signal;
        return fetch(ENDPOINT, options);
      })
      .then(function (res) {
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json();
      });
    Promise.race([chatRequest, deadline])
      .then(function (data) {
        if (requestExpired || requestGeneration !== turnGeneration) return;
        hideTyping();
        var replyRow = addBubble(data.reply || T.error || "", false);
        addFeedback(replyRow, data.feedback, data.offer_capture);
        if (data.sticker_url) addSticker(data.sticker_url);
        replaceQuickReplies(data.quick_replies);
      })
      .catch(function () {
        if (requestGeneration !== turnGeneration) return;
        hideTyping();
        if (!field.value) {
          field.value = text;
          autoGrow();
        }
        addBubble(T.error || "Sorry, something went wrong.", false);
      })
      .then(function () {
        if (requestGeneration !== turnGeneration) return;
        window.clearTimeout(requestTimer);
        sending = false;
        sendBtn.disabled = false;
        syncLocationButton();
        field.focus();
      });
  }

  function prepareLocation() {
    if (sending) return;
    locateBtn.disabled = true;
    requestBrowserLocation()
      .then(function () {
        addBubble(T.location_ready || "Location is ready for the next question.", false);
      })
      .catch(function () {
        addBubble(T.location_error || "I cannot get the location. You can type an address or nearest stop instead.", false);
      })
      .then(function () {
        locateBtn.disabled = false;
        syncLocationButton();
        field.focus();
      });
  }

  // ---- greeting + quick-action menu --------------------------------------
  function greet() {
    if (greeted) return;
    greeted = true;
    if (T.greeting) addBubble(T.greeting, false);
    var quick = QUICK.length ? QUICK : defaultQuick();
    addQuickReplies(quick);
  }

  // Default quick-action menu when the host did not supply one. Report/idea
  // link to the relevant pages; budget/donate send a canned question so the
  // brain answers inline.
  function defaultQuick() {
    var q = (T.quick) || {};
    var out = [];
    var reportUrl = CFG.reportUrl || publicPath("prijave/new");
    var donateUrl = CFG.donateUrl || publicPath("donacije");
    if (q.report && reportUrl) out.push({ label: q.report, href: reportUrl });
    if (q.idea && CFG.ideaUrl) out.push({ label: q.idea, href: CFG.ideaUrl });
    if (q.budget) out.push({ label: q.budget, send: q.budget });
    if (q.donate && donateUrl) out.push({ label: q.donate, href: donateUrl });
    return out;
  }

  function publicPath(path) {
    var base = String(CFG.publicBasePath || CFG.publicMountPath || "").replace(/\/+$/, "");
    if (!base) return null;
    return base + "/" + String(path || "").replace(/^\/+/, "");
  }

  // ---- open / close + focus management -----------------------------------
  function focusables() {
    return Array.prototype.slice.call(
      panel.querySelectorAll('button, [href], textarea, input, [tabindex]:not([tabindex="-1"])')
    ).filter(function (n) { return !n.disabled && n.offsetParent !== null; });
  }

  function open() {
    if (root.classList.contains("is-open")) return;
    lastFocused = document.activeElement;
    root.classList.add("is-open");
    bubble.setAttribute("aria-expanded", "true");
    greet();
    // Focus the input after the panel paints.
    window.requestAnimationFrame(function () { field.focus(); });
  }

  function close() {
    if (!root.classList.contains("is-open")) return;
    root.classList.remove("is-open");
    bubble.setAttribute("aria-expanded", "false");
    if (lastFocused && lastFocused.focus) lastFocused.focus();
    else bubble.focus();
  }

  function onKeydown(e) {
    if (!root.classList.contains("is-open")) return;
    if (e.key === "Escape") { e.preventDefault(); close(); return; }
    if (e.key !== "Tab") return;
    // Focus trap.
    var items = focusables();
    if (!items.length) return;
    var first = items[0];
    var last = items[items.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault(); last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault(); first.focus();
    }
  }

  // ---- textarea auto-grow + Enter-to-send --------------------------------
  function autoGrow() {
    field.style.height = "auto";
    field.style.height = Math.min(field.scrollHeight, 96) + "px";
  }

  // ---- Decidim cookie banner spacing -------------------------------------
  function consentBannerVisible(banner) {
    return !!(banner && !banner.hidden && banner.getClientRects().length);
  }

  function updateConsentOffset() {
    if (!root) return;

    var banner = document.getElementById("dc-dialog-wrapper");
    var visible = consentBannerVisible(banner);
    root.classList.toggle("mi-chat--consent-open", visible);

    if (visible) {
      root.style.setProperty("--mi-consent-offset", Math.ceil(banner.getBoundingClientRect().height) + "px");
    } else {
      root.style.removeProperty("--mi-consent-offset");
    }
  }

  function watchConsentBanner() {
    var banner = document.getElementById("dc-dialog-wrapper");
    if (!banner) return;

    if ("MutationObserver" in window) {
      var observer = new MutationObserver(updateConsentOffset);
      observer.observe(banner, { attributes: true, attributeFilter: ["hidden", "class", "style"] });
      consentWatchers.push(observer);
    }

    if ("ResizeObserver" in window) {
      var resizeObserver = new ResizeObserver(updateConsentOffset);
      resizeObserver.observe(banner);
      consentWatchers.push(resizeObserver);
    }

    window.addEventListener("resize", updateConsentOffset);
    document.addEventListener("dataconsent", updateConsentOffset);
    updateConsentOffset();
    window.setTimeout(updateConsentOffset, 0);
  }

  // ---- build --------------------------------------------------------------
  function build() {
    root = el("div", "mi-chat");
    root.id = "mi-chat";

    // Bubble launcher
    bubble = el("button", "mi-chat__bubble", {
      type: "button",
      "aria-label": T.aria_open || T.bubble_label || "Chat",
      "aria-haspopup": "dialog",
      "aria-expanded": "false",
      "aria-controls": "mi-chat-panel"
    });
    var bIcon = el("span", "mi-chat__bubble-icon");
    bIcon.appendChild(svg(ICON_HEART));
    bubble.appendChild(bIcon);
    if (T.bubble_label) {
      var bLabel = el("span", "mi-chat__bubble-label");
      bLabel.textContent = T.bubble_label;
      bubble.appendChild(bLabel);
    }
    bubble.addEventListener("click", open);

    // Panel
    panel = el("div", "mi-chat__panel", {
      id: "mi-chat-panel",
      role: "dialog",
      "aria-modal": "false",
      "aria-label": T.header_title || "Platform assistant"
    });

    // Header
    var header = el("div", "mi-chat__header");
    var avatar = el("div", "mi-chat__avatar");
    if (CFG.avatarUrl) {
      var aImg = el("img", null, { src: CFG.avatarUrl, alt: "" });
      avatar.appendChild(aImg);
    } else {
      avatar.appendChild(svg(ICON_HEART));
    }
    var id = el("div", "mi-chat__id");
    var name = el("div", "mi-chat__name");
    name.textContent = T.header_title || "Platform assistant";
    var status = el("div", "mi-chat__status");
    status.textContent = T.header_status || "online";
    id.appendChild(name);
    id.appendChild(status);
    var closeBtn = el("button", "mi-chat__close", {
      type: "button",
      "aria-label": T.aria_close || "Close"
    });
    closeBtn.appendChild(svg(ICON_CLOSE));
    closeBtn.addEventListener("click", close);
    header.appendChild(avatar);
    header.appendChild(id);
    header.appendChild(closeBtn);

    // Body
    body = el("div", "mi-chat__body", { role: "log", "aria-live": "polite", "aria-atomic": "false" });

    // Input bar
    var inputbar = el("div", "mi-chat__inputbar");
    field = el("textarea", "mi-chat__field", {
      rows: "1",
      placeholder: T.input_placeholder || "",
      "aria-label": T.input_placeholder || "Message",
      autocomplete: "off"
    });
    field.addEventListener("input", autoGrow);
    field.addEventListener("keydown", function (e) {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        submit(field.value);
      }
    });
    sendBtn = el("button", "mi-chat__send", {
      type: "button",
      "aria-label": T.aria_send || "Send"
    });
    sendBtn.appendChild(svg(ICON_SEND));
    sendBtn.addEventListener("click", function () { submit(field.value); });
    locateBtn = el("button", "mi-chat__locate", {
      type: "button",
      "aria-label": T.aria_location || "Use current location"
    });
    locateBtn.appendChild(svg(ICON_LOCATION));
    locateBtn.addEventListener("click", prepareLocation);
    inputbar.appendChild(field);
    inputbar.appendChild(locateBtn);
    inputbar.appendChild(sendBtn);

    panel.appendChild(header);
    panel.appendChild(body);
    panel.appendChild(inputbar);

    root.appendChild(bubble);
    root.appendChild(panel);
    document.body.appendChild(root);

    watchConsentBanner();
    document.addEventListener("keydown", onKeydown);
    function prefill(draft) {
      field.value = String(draft || "").slice(0, 1000);
      window.MI_CHAT_PENDING_DRAFT = null;
      autoGrow();
      field.focus();
    }
    window.MI_CHAT_WIDGET = { open: open, close: close, prefill: prefill };
    if (window.MI_CHAT_PENDING_DRAFT) prefill(window.MI_CHAT_PENDING_DRAFT);
  }

  function init() {
    // Never mount twice (e.g. Turbo-style re-inits).
    if (document.getElementById("mi-chat")) return;
    build();
    if (CFG.autoOpen) window.requestAnimationFrame(open);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
