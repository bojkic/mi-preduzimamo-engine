/* Public reports map. Requires Leaflet as window.L. */
(function () {
  "use strict";

  function ready(fn) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", fn, { once: true });
    } else {
      fn();
    }
  }

  function parseJson(value, fallback) {
    try {
      return JSON.parse(value || "");
    } catch (_err) {
      return fallback;
    }
  }

  function escapeHtml(value) {
    return String(value == null ? "" : value).replace(/[&<>"']/g, function (ch) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch];
    });
  }

  function init() {
    var el = document.getElementById("bih-reports-map");
    if (!el || el.dataset.initialized === "true") return;
    el.dataset.initialized = "true";

    var status = document.getElementById(el.dataset.statusId || "bih-reports-map-status");
    var retry = document.getElementById(el.dataset.retryButtonId || "bih-reports-map-retry");

    function setStatus(state, message) {
      if (!status) return;
      status.dataset.state = state;
      status.hidden = false;
      status.textContent = message || "";
      if (retry) retry.hidden = state !== "unavailable";
    }

    if (retry) {
      retry.addEventListener("click", function () { window.location.reload(); });
    }

    if (typeof L === "undefined") {
      setStatus("unavailable", el.dataset.statusUnavailable);
      return;
    }

    setStatus("loading", el.dataset.statusLoading);

    var statusColors = parseJson(el.dataset.statusColors, {});
    var statusLabels = parseJson(el.dataset.statusLabels, {});
    var categoryLabels = parseJson(el.dataset.categoryLabels, {});
    var severityRadii = parseJson(el.dataset.severityRadii, {});
    var severityLabels = parseJson(el.dataset.severityLabels, {});
    var defaultColor = el.dataset.defaultColor || "#6b7280";
    var defaultRadius = parseFloat(el.dataset.defaultRadius || "7");

    var map = L.map(el).setView(
      [parseFloat(el.dataset.centerLat), parseFloat(el.dataset.centerLng)],
      parseInt(el.dataset.zoom, 10)
    );

    L.tileLayer(el.dataset.tileUrl, {
      maxZoom: parseInt(el.dataset.tileMaxZoom || "19", 10),
      attribution: el.dataset.tileAttribution
    }).addTo(map);

    function severityRadius(severity) {
      var r = severityRadii[severity];
      return typeof r === "number" && r > 0 ? r : defaultRadius;
    }

    function popupHtml(props) {
      var status = statusLabels[props.status] || props.status;
      var category = props.category ? (categoryLabels[props.category] || props.category) : null;
      var severity = props.severity ? (severityLabels[props.severity] || props.severity) : null;
      var html = "<strong>" + escapeHtml(el.dataset.labelReference) + ":</strong> " + escapeHtml(props.reference) + "<br>";
      if (category) {
        html += "<strong>" + escapeHtml(el.dataset.labelCategory) + ":</strong> " + escapeHtml(category) + "<br>";
      }
      html += "<strong>" + escapeHtml(el.dataset.labelStatus) + ":</strong> " + escapeHtml(status);
      if (props.resolved_recently === true && el.dataset.labelResolvedRecently) {
        html += ' <span style="display:inline-block;background:#dcfce7;color:#15803d;border-radius:999px;padding:0 .45rem;font-size:.72rem;font-weight:600;">' +
          escapeHtml(el.dataset.labelResolvedRecently) + "</span>";
      }
      html += "<br>";
      if (severity && el.dataset.labelSeverity) {
        html += "<strong>" + escapeHtml(el.dataset.labelSeverity) + ":</strong> " + escapeHtml(severity) + "<br>";
      }
      if (props.status_url) {
        html += '<a href="' + encodeURI(props.status_url) + '">' + escapeHtml(el.dataset.labelDetails) + "</a>";
      }
      return html;
    }

    // Distinct styling for the "recently resolved" layer: a thicker gold ring
    // and a celebratory accent fill so the city's recent wins stand out.
    var resolvedRingColor = el.dataset.resolvedRingColor || "#15803d";
    var resolvedFillColor = el.dataset.resolvedFillColor || "#22c55e";

    function isResolvedRecently(props) {
      return props && props.resolved_recently === true;
    }

    function baseMarker(feature, latlng) {
      // Status drives colour, severity drives size: two independent channels so
      // urgency is legible without relying on colour alone.
      var color = statusColors[feature.properties.status] || defaultColor;
      return L.circleMarker(latlng, {
        radius: severityRadius(feature.properties.severity),
        fillColor: color,
        color: "#ffffff",
        weight: 1.5,
        opacity: 1,
        fillOpacity: 0.9
      });
    }

    function resolvedMarker(feature, latlng) {
      return L.circleMarker(latlng, {
        radius: severityRadius(feature.properties.severity) + 1,
        fillColor: resolvedFillColor,
        color: resolvedRingColor,
        weight: 3,
        opacity: 1,
        fillOpacity: 0.95
      });
    }

    function bindPopup(feature, lyr) {
      lyr.bindPopup(popupHtml(feature.properties));
    }

    fetch(el.dataset.geojsonUrl, { headers: { Accept: "application/json" } })
      .then(function (response) {
        if (!response.ok) throw new Error("reports map unavailable");
        return response.json();
      })
      .then(function (data) {
        var allFeatures = (data && data.features) || [];
        var resolvedFeatures = allFeatures.filter(function (f) { return isResolvedRecently(f.properties); });
        var otherFeatures = allFeatures.filter(function (f) { return !isResolvedRecently(f.properties); });

        var baseLayer = L.geoJSON(
          { type: "FeatureCollection", features: otherFeatures },
          { pointToLayer: baseMarker, onEachFeature: bindPopup }
        ).addTo(map);

        var resolvedLayer = L.geoJSON(
          { type: "FeatureCollection", features: resolvedFeatures },
          { pointToLayer: resolvedMarker, onEachFeature: bindPopup }
        ).addTo(map);

        // Toggle for the recently-resolved layer when there is anything to show.
        if (resolvedFeatures.length > 0 && el.dataset.layerResolved) {
          var overlays = {};
          overlays[el.dataset.layerReports || "Reports"] = baseLayer;
          overlays[el.dataset.layerResolved] = resolvedLayer;
          L.control.layers(null, overlays, { collapsed: false }).addTo(map);
        }

        if (allFeatures.length > 0) {
          var bounds = baseLayer.getBounds();
          if (resolvedFeatures.length > 0) {
            bounds = bounds.isValid() ? bounds.extend(resolvedLayer.getBounds()) : resolvedLayer.getBounds();
          }
          if (bounds.isValid()) {
            map.fitBounds(bounds, { padding: [30, 30], maxZoom: parseInt(el.dataset.fitMaxZoom || "16", 10) });
          }
          setStatus("ready", el.dataset.statusReady);
        } else {
          setStatus("empty", el.dataset.statusEmpty);
        }
      })
      .catch(function () {
        setStatus("unavailable", el.dataset.statusUnavailable);
      });
  }

  ready(init);
  document.addEventListener("turbo:load", init);
})();
