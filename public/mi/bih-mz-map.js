/* Mjesna zajednica (MZ) directory — single-boundary display map.
 * Read-only: fetches the MZ boundary GeoJSON Feature, draws the polygon,
 * fits the map to it, and drops a marker at the representative center.
 * Requires Leaflet as window.L. No citizen data is involved. */
(function () {
  "use strict";

  function ready(fn) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", fn, { once: true });
    } else {
      fn();
    }
  }

  function init() {
    var el = document.getElementById("bih-mz-map");
    if (!el || el.dataset.initialized === "true") return;
    el.dataset.initialized = "true";

    var status = document.getElementById(el.dataset.statusId || "bih-mz-map-status");
    var retry = document.getElementById(el.dataset.retryButtonId || "bih-mz-map-retry");

    function setStatus(state, message) {
      if (status) {
        status.dataset.state = state;
        status.textContent = message || "";
      }
      if (retry) retry.hidden = state !== "unavailable";
    }

    if (retry) retry.addEventListener("click", function () { window.location.reload(); });
    if (typeof L === "undefined") {
      setStatus("unavailable", el.dataset.statusUnavailable);
      return;
    }
    setStatus("loading", el.dataset.statusLoading);

    var centerLat = parseFloat(el.dataset.centerLat);
    var centerLng = parseFloat(el.dataset.centerLng);
    var zoom = parseInt(el.dataset.zoom || "14", 10);

    var map = L.map(el).setView([centerLat, centerLng], zoom);

    L.tileLayer(el.dataset.tileUrl, {
      maxZoom: 19,
      attribution: el.dataset.tileAttribution
    }).addTo(map);

    var boundaryUrl = el.dataset.boundaryUrl;
    if (!boundaryUrl) return;

    fetch(boundaryUrl, { headers: { Accept: "application/json" } })
      .then(function (r) {
        if (!r.ok) throw new Error("boundary unavailable");
        return r.json();
      })
      .then(function (feature) {
        if (!feature || !feature.geometry) throw new Error("boundary missing");

        var layer = L.geoJSON(feature, {
          style: {
            color: "#1c3d53",
            weight: 2.5,
            fillColor: "#7fb2cf",
            fillOpacity: 0.18
          }
        }).addTo(map);

        try {
          map.fitBounds(layer.getBounds(), { padding: [24, 24], maxZoom: 16 });
        } catch (e) {
          /* keep the centered default view if bounds are degenerate */
        }

        if (Number.isFinite(centerLat) && Number.isFinite(centerLng)) {
          L.marker([centerLat, centerLng]).addTo(map);
        }
        setStatus("ready", el.dataset.statusReady);
      })
      .catch(function () {
        setStatus("unavailable", el.dataset.statusUnavailable);
      });
  }

  ready(init);
  document.addEventListener("turbo:load", init);
})();
