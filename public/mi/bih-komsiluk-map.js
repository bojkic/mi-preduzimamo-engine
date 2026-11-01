/* Komšiluk picker map + address-suggest logic.
 *
 * Two hosts share this file:
 *   - the signed-in picker (komsiluk/edit): Leaflet is on the page already; a
 *     polygon click builds a PATCH confirm form, the address helper fills the
 *     hidden confirm form.
 *   - the one-step registration (/registracija): the map element carries
 *     data-target-select (the id of the komšiluk <select>) and sits inside a
 *     [data-mi-komsiluk-finder] container. The map is the default way to
 *     choose: Leaflet is injected on load (data-leaflet-css / data-leaflet-js)
 *     when the container is a plain element, or on first open when it is a
 *     <details>. The select is a hidden fallback ([data-mi-komsiluk-fallback])
 *     that is shown again only when the map cannot be built. Both helpers
 *     only ever SET that select — no form, no PATCH, nothing stored.
 */
(function () {
  "use strict";

  function ready(fn) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", fn, { once: true });
    } else {
      fn();
    }
  }

  function escapeHtml(value) {
    return String(value == null ? "" : value).replace(/[&<>"']/g, function (ch) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch];
    });
  }

  function show(node, visible) {
    if (!node) return;
    node.style.display = visible ? "" : "none";
  }

  function csrfToken() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.content : null;
  }

  /* The <select> both helpers write into (registration page only). */
  function targetSelectFor(el) {
    var id = el && el.dataset && el.dataset.targetSelect;
    if (!id) return null;
    return document.getElementById(id);
  }

  function setSelectValue(select, id) {
    if (!select) return false;
    select.value = String(id);
    var matched = select.value === String(id);
    select.dispatchEvent(new Event("change", { bubbles: true }));
    return matched;
  }

  /* "Izabrani komšiluk: …" line on the registration page, kept in step with
   * the select whichever helper set it. */
  function bindChosenLine(select) {
    if (!select || select.dataset.chosenBound === "true") return;
    select.dataset.chosenBound = "true";
    var out = document.querySelector("[data-mi-komsiluk-chosen-name]");
    if (!out) return;
    var render = function () {
      var option = select.options[select.selectedIndex];
      var text = select.value && option ? option.text : "";
      out.textContent = text || out.dataset.none || "";
      out.classList.toggle("is-chosen", !!text);
    };
    select.addEventListener("change", render);
    render();
  }

  /* When the map cannot be built the hidden select is the way to choose. */
  function showFallback(el) {
    var fallback = document.querySelector("[data-mi-komsiluk-fallback]");
    if (fallback) fallback.hidden = false;
    var frame = el && el.closest(".mi-map-frame");
    if (frame) frame.classList.add("is-unavailable");
  }

  /* The select is display:none while the map works, so `required` cannot be
   * on it (an unfocusable required control blocks submit silently). Check
   * the choice here instead and point at the map. */
  function bindSubmitGuard(select, el) {
    var form = select && select.form;
    if (!form || form.dataset.komsilukGuard === "true") return;
    form.dataset.komsilukGuard = "true";
    form.addEventListener("submit", function (event) {
      if (select.value) return;
      event.preventDefault();
      var fallback = document.querySelector("[data-mi-komsiluk-fallback]");
      if (fallback && !fallback.hidden) { select.focus(); return; }
      statusSetter(el)("required", "statusRequired");
      var frame = el.closest(".mi-map-frame") || el;
      frame.scrollIntoView({ block: "center", behavior: "smooth" });
    });
  }

  /* The live map (once built) exposes select(id, pan) so the address flow can
   * highlight the polygon it found. null until Leaflet has drawn the areas. */
  var mapApi = null;

  /* ─── Leaflet lazy loader ──────────────────────────────────────────────── */

  var leafletPromise = null;

  function loadLeaflet(el) {
    if (typeof L !== "undefined") return Promise.resolve();
    if (leafletPromise) return leafletPromise;

    leafletPromise = new Promise(function (resolve, reject) {
      if (!el.dataset.leafletJs) {
        reject(new Error("leaflet not on page"));
        return;
      }
      if (el.dataset.leafletCss && !document.querySelector('link[href="' + el.dataset.leafletCss + '"]')) {
        var link = document.createElement("link");
        link.rel = "stylesheet";
        link.href = el.dataset.leafletCss;
        document.head.appendChild(link);
      }
      var script = document.createElement("script");
      script.src = el.dataset.leafletJs;
      script.async = true;
      script.onload = function () {
        if (typeof L === "undefined") reject(new Error("leaflet failed"));
        else resolve();
      };
      script.onerror = function () { reject(new Error("leaflet failed")); };
      document.head.appendChild(script);
    });
    return leafletPromise;
  }

  /* ─── Map-click picker ─────────────────────────────────────────────────── */

  function statusSetter(el) {
    var status = document.getElementById(el.dataset.statusId || "bih-komsiluk-map-status");
    return function (state, key, text) {
      if (!status) return;
      status.dataset.state = state;
      status.textContent = text != null ? text : (el.dataset[key] || status.textContent);
    };
  }

  function buildMap(el) {
    if (el.dataset.initialized === "true") return;
    el.dataset.initialized = "true";

    var setStatus = statusSetter(el);

    var targetSelect = targetSelectFor(el);

    if (typeof L === "undefined") {
      setStatus("unavailable", "statusUnavailable");
      if (targetSelect) showFallback(el);
      return;
    }

    var map = L.map(el).setView(
      [parseFloat(el.dataset.centerLat), parseFloat(el.dataset.centerLng)],
      parseInt(el.dataset.zoom, 10)
    );

    L.tileLayer(el.dataset.tileUrl, {
      maxZoom: 19,
      attribution: el.dataset.tileAttribution
    }).addTo(map);

    /* The container may have been display:none (inside a closed <details>)
     * when Leaflet measured it; re-measure once it is actually visible. */
    var refresh = function () { setTimeout(function () { map.invalidateSize(); }, 0); };
    refresh();
    var finder = el.closest("[data-mi-komsiluk-finder]");
    if (finder && finder.tagName === "DETAILS") {
      finder.addEventListener("toggle", function () { if (finder.open) refresh(); });
    }

    var selectedLayer = null;
    var confirmBar = null;
    var layersById = {};

    function clearSelection() {
      if (selectedLayer) {
        selectedLayer.setStyle({ fillOpacity: 0.15, weight: 2, color: "#2563eb" });
        selectedLayer = null;
      }
      if (confirmBar) {
        confirmBar.remove();
        confirmBar = null;
      }
    }

    function highlight(layer) {
      clearSelection();
      selectedLayer = layer;
      layer.setStyle({ fillOpacity: 0.45, weight: 3, color: "#1d4ed8" });
    }

    /* Registration page: the click IS the choice — set the select, say so. */
    function pickIntoSelect(layer, id, name) {
      highlight(layer);
      setSelectValue(targetSelect, id);
      var template = el.dataset.statusSelected || "%{name}";
      setStatus("selected", null, template.replace("%{name}", name));
    }

    /* Picker page: the click opens a confirm form that PATCHes the choice. */
    function openConfirmBar(layer, id, name) {
      highlight(layer);

      var bar = document.createElement("form");
      bar.action = el.parentElement.dataset && el.parentElement.dataset.updateUrl
        ? el.parentElement.dataset.updateUrl
        : window.location.pathname;
      bar.method = "post";
      bar.style.cssText = "position:absolute;bottom:12px;left:50%;transform:translateX(-50%);z-index:999;background:#fff;border:1.5px solid #2563eb;border-radius:8px;padding:0.6rem 1rem;display:flex;gap:0.6rem;align-items:center;box-shadow:0 2px 8px rgba(0,0,0,.18);";

      var token = csrfToken();
      if (token) {
        var csrfInput = document.createElement("input");
        csrfInput.type = "hidden";
        csrfInput.name = "authenticity_token";
        csrfInput.value = token;
        bar.appendChild(csrfInput);
      }

      var methodInput = document.createElement("input");
      methodInput.type = "hidden";
      methodInput.name = "_method";
      methodInput.value = "patch";
      bar.appendChild(methodInput);

      var kidInput = document.createElement("input");
      kidInput.type = "hidden";
      kidInput.name = "komsiluk_id";
      kidInput.value = String(id);
      bar.appendChild(kidInput);

      var srcInput = document.createElement("input");
      srcInput.type = "hidden";
      srcInput.name = "source";
      srcInput.value = "map";
      bar.appendChild(srcInput);

      var nameSpan = document.createElement("strong");
      nameSpan.textContent = name;
      bar.appendChild(nameSpan);

      var btn = document.createElement("button");
      btn.type = "submit";
      btn.textContent = escapeHtml(el.dataset.labelConfirm || "Odaberi");
      btn.style.cssText = "background:#2563eb;color:#fff;border:none;border-radius:6px;padding:0.4rem 0.9rem;cursor:pointer;font-weight:700;";
      bar.appendChild(btn);

      var cancelBtn = document.createElement("button");
      cancelBtn.type = "button";
      cancelBtn.textContent = "✕";
      cancelBtn.style.cssText = "background:none;border:none;cursor:pointer;color:#6b7280;font-size:1rem;";
      cancelBtn.onclick = clearSelection;
      bar.appendChild(cancelBtn);

      /* Position relative to the map container */
      var mapContainer = el.parentElement;
      mapContainer.style.position = "relative";
      mapContainer.appendChild(bar);
      confirmBar = bar;
    }

    fetch(el.dataset.areasUrl, { headers: { Accept: "application/json" } })
      .then(function (r) {
        if (!r.ok) throw new Error("areas unavailable");
        return r.json();
      })
      .then(function (data) {
        var features = (data && data.features) || [];
        if (features.length === 0) {
          setStatus("empty", "statusEmpty");
          if (targetSelect) showFallback(el);
          return;
        }

        L.geoJSON(data, {
          style: {
            color: "#2563eb",
            weight: 2,
            fillColor: "#93c5fd",
            fillOpacity: 0.15
          },
          onEachFeature: function (feature, layer) {
            var name = (feature.properties && feature.properties.name) || "";
            var id = feature.properties && feature.properties.id;
            layersById[String(id)] = { layer: layer, name: name };
            layer.bindTooltip(escapeHtml(name), { sticky: true });
            layer.on("click", function () {
              if (targetSelect) pickIntoSelect(layer, id, name);
              else openConfirmBar(layer, id, name);
            });
          }
        }).addTo(map);
        setStatus("ready", "statusReady");
        /* A re-render after a validation error: show the choice already made. */
        if (targetSelect && targetSelect.value && layersById[targetSelect.value]) {
          highlight(layersById[targetSelect.value].layer);
        }

        mapApi = {
          focus: function (lat, lon) {
            clearSelection();
            map.setView([lat, lon], 16);
            el.scrollIntoView({ block: "center", behavior: "smooth" });
          },
          select: function (id, pan) {
            var entry = layersById[String(id)];
            if (!entry) return false;
            highlight(entry.layer);
            if (pan && entry.layer.getBounds) map.fitBounds(entry.layer.getBounds(), { maxZoom: 15 });
            if (targetSelect) {
              var template = el.dataset.statusSelected || "%{name}";
              setStatus("selected", null, template.replace("%{name}", entry.name));
            }
            return true;
          }
        };
      })
      .catch(function () {
        setStatus("unavailable", "statusUnavailable");
        if (targetSelect) showFallback(el);
      });
  }

  function initMap() {
    var el = document.getElementById("bih-komsiluk-map");
    if (!el || el.dataset.initialized === "true") return;

    var targetSelect = targetSelectFor(el);
    if (targetSelect) {
      bindChosenLine(targetSelect);
      bindSubmitGuard(targetSelect, el);
    }

    var finder = el.closest("[data-mi-komsiluk-finder]");
    if (el.dataset.leafletJs) {
      if (el.dataset.lazyBound === "true") return;
      el.dataset.lazyBound = "true";
      var build = function () {
        loadLeaflet(el).then(
          function () { buildMap(el); },
          function () {
            statusSetter(el)("unavailable", "statusUnavailable");
            el.dataset.initialized = "true";
            if (targetSelect) showFallback(el);
          }
        );
      };
      if (finder && finder.tagName === "DETAILS") {
        /* Lazy: nothing is fetched until the citizen opens the finder. */
        var onOpen = function () {
          if (!finder.open) return;
          finder.removeEventListener("toggle", onOpen);
          build();
        };
        finder.addEventListener("toggle", onOpen);
        if (finder.open) onOpen();
      } else {
        /* The map is the default control: build it right away. */
        build();
      }
      return;
    }

    buildMap(el);
  }

  /* ─── Address suggest ──────────────────────────────────────────────────── */

  function initAddressSuggest() {
    var input = document.getElementById("bih-address-input");
    var searchBtn = document.getElementById("bih-address-search");
    var resultDiv = document.getElementById("bih-address-result");
    var suggestedName = document.getElementById("bih-suggested-name");
    var komsilukIdInput = document.getElementById("bih-address-komsiluk-id");
    var latInput = document.getElementById("bih-address-lat");
    var lonInput = document.getElementById("bih-address-lon");
    var noMatchDiv = document.getElementById("bih-address-no-match");
    var unavailableDiv = document.getElementById("bih-address-unavailable");
    var searchingDiv = document.getElementById("bih-address-searching");
    var candidatesDiv = document.getElementById("bih-address-candidates");
    var candidateList = document.getElementById("bih-address-candidate-list");
    var mapHint = document.getElementById("bih-address-map-hint");
    var requestSequence = 0;
    var chosenCandidateId = null;

    if (!input || !searchBtn || searchBtn.dataset.bound === "true") return;
    searchBtn.dataset.bound = "true";

    var finder = document.querySelector("[data-mi-komsiluk-finder]");
    var mapEl = document.getElementById("bih-komsiluk-map");
    var targetSelect = targetSelectFor(finder) || targetSelectFor(mapEl);

    var suggestUrl = searchBtn.dataset.suggestUrl ||
      (finder && finder.dataset.suggestUrl) ||
      (mapEl && mapEl.dataset.suggestUrl) ||
      (window.location.pathname.replace(/\/$/, "") + "/suggest");

    function clearCandidateChoice() {
      if (targetSelect && chosenCandidateId && targetSelect.value === chosenCandidateId) setSelectValue(targetSelect, "");
      chosenCandidateId = null;
      if (komsilukIdInput) komsilukIdInput.value = "";
      if (latInput) latInput.value = "";
      if (lonInput) lonInput.value = "";
      show(resultDiv, false);
    }

    function chooseCandidate(candidate) {
      clearCandidateChoice();
      if (candidate.requires_map_confirmation) {
        show(mapHint, true);
        if (mapApi) mapApi.focus(candidate.lat, candidate.lon);
        else if (mapEl) showFallback(mapEl);
        return;
      }
      show(mapHint, false);
      if (suggestedName) suggestedName.textContent = candidate.komsiluk_name || "";
      if (komsilukIdInput) komsilukIdInput.value = String(candidate.komsiluk_id || "");
      if (latInput) latInput.value = candidate.lat == null ? "" : String(candidate.lat);
      if (lonInput) lonInput.value = candidate.lon == null ? "" : String(candidate.lon);
      var confirmForm = document.getElementById("bih-address-confirm-form");
      var sourceInput = confirmForm && confirmForm.querySelector('[name="source"]');
      if (sourceInput) sourceInput.value = candidate.source === "provider" ? "address" : "dropdown";
      if (targetSelect) setSelectValue(targetSelect, candidate.komsiluk_id);
      chosenCandidateId = String(candidate.komsiluk_id);
      if (mapApi) mapApi.select(candidate.komsiluk_id, true);
      show(resultDiv, true);
    }

    function renderCandidates(candidates) {
      if (!candidateList || !candidatesDiv) return;
      candidateList.replaceChildren();
      candidates.forEach(function (candidate) {
        var item = document.createElement("li");
        item.style.cssText = "margin:0 0 0.75rem;padding:0.5rem;border:1px solid #cbd5e1;border-radius:6px";
        var label = document.createElement("p");
        label.textContent = candidate.label;
        item.appendChild(label);
        var precision = document.createElement("p");
        precision.textContent = candidatesDiv.getAttribute("data-precision-" + candidate.precision) || "";
        item.appendChild(precision);
        var button = document.createElement("button");
        button.type = "button";
        button.className = "mi-btn mi-btn--primary mi-btn--sm";
        button.textContent = candidate.requires_map_confirmation ? candidatesDiv.dataset.mapLabel : candidatesDiv.dataset.chooseLabel;
        button.addEventListener("click", function () { chooseCandidate(candidate); });
        item.appendChild(button);
        candidateList.appendChild(item);
      });
      show(candidatesDiv, candidates.length > 0);
    }

    function doSearch() {
      var address = input.value.trim();
      if (!address) return;
      var sequence = ++requestSequence;
      clearCandidateChoice();
      renderCandidates([]);
      show(mapHint, false);
      searchBtn.disabled = true;

      show(resultDiv, false);
      show(noMatchDiv, false);
      show(unavailableDiv, false);
      show(searchingDiv, true);

      var token = csrfToken();
      var body = new URLSearchParams({ address: address, purpose: "membership" });
      if (token) body.append("authenticity_token", token);
      var headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json",
        "X-Requested-With": "XMLHttpRequest"
      };
      if (token) headers["X-CSRF-Token"] = token;

      fetch(suggestUrl, { method: "POST", headers: headers, body: body.toString(), credentials: "same-origin" })
        .then(function (r) {
          if (!r.ok) throw new Error("search unavailable");
          return r.json();
        })
        .then(function (data) {
          if (sequence !== requestSequence) return;
          show(searchingDiv, false);
          searchBtn.disabled = false;
          var candidates = Array.isArray(data.candidates) ? data.candidates : [];
          renderCandidates(candidates);
          show(noMatchDiv, candidates.length === 0);
          show(unavailableDiv, false);
        })
        .catch(function () {
          if (sequence !== requestSequence) return;
          show(searchingDiv, false);
          searchBtn.disabled = false;
          show(noMatchDiv, false);
          show(unavailableDiv, true);
        });
    }

    input.addEventListener("input", function () {
      requestSequence += 1;
      clearCandidateChoice();
      renderCandidates([]);
      show(mapHint, false);
      show(searchingDiv, false);
      searchBtn.disabled = false;
    });
    searchBtn.addEventListener("click", doSearch);
    input.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { e.preventDefault(); doSearch(); }
    });
  }

  /* NOTE: MZ→komšiluk cascade dropdown was removed when komšiluci were decoupled
   * from MZ (geo-decoupling). The dropdown picker now shows a flat komšiluk list
   * populated server-side; no client-side cascade is needed. */

  function init() {
    initMap();
    initAddressSuggest();
  }

  ready(init);
  document.addEventListener("turbo:load", init);
})();

(function () {
  document.addEventListener("submit", function (event) {
    var choice = document.getElementById("mi-komsiluk-notifications");
    var form = event.target;
    if (!choice || !form || !form.querySelector('[name="komsiluk_id"]')) return;
    var fields = form.querySelectorAll('[name="komsiluk_notifications"]');
    fields.forEach(function (field) { if (field !== choice) field.remove(); });
    if (choice.form === form) return;
    var value = document.createElement("input");
    value.type = "hidden";
    value.name = "komsiluk_notifications";
    value.value = choice.checked ? "1" : "0";
    form.appendChild(value);
  }, true);
})();

(function () {
  function bindFilter() {
    var input = document.getElementById("mi-komsiluk-filter");
    var select = document.getElementById("bih-komsiluk-select");
    if (!input || !select || input.dataset.komsilukFilterBound) return;
    input.dataset.komsilukFilterBound = "true";
    var options = Array.from(select.options).map(function (option) { return option.cloneNode(true); });
    input.addEventListener("input", function () {
      var chosen = select.value;
      var term = input.value.trim().toLocaleLowerCase();
      select.replaceChildren.apply(select, options.filter(function (option) {
        return !option.value || option.value === chosen || option.text.toLocaleLowerCase().includes(term);
      }).map(function (option) { return option.cloneNode(true); }));
      select.value = chosen;
    });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", bindFilter);
  else bindFilter();
})();
