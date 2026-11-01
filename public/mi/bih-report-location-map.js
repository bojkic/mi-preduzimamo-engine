/* Report intake location picker. Requires Leaflet as window.L. */
(function () {
  "use strict";

  function ready(fn) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", fn, { once: true });
    } else {
      fn();
    }
  }

  function coordinate(value) {
    return parseFloat(value);
  }

  function validLatLng(lat, lng) {
    return Number.isFinite(lat) && Number.isFinite(lng) &&
      lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
  }

  function init() {
    var mapEl = document.getElementById("bih-report-location-map");
    if (!mapEl || mapEl.dataset.initialized === "true") return;

    var latInput = document.getElementById(mapEl.dataset.latitudeInputId || "report_latitude");
    var lngInput = document.getElementById(mapEl.dataset.longitudeInputId || "report_longitude");
    var geolocate = document.getElementById(mapEl.dataset.geolocateButtonId || "bih-report-geolocate");
    var status = document.getElementById(mapEl.dataset.statusId || "bih-report-location-status");

    if (!latInput || !lngInput || !status) return;
    mapEl.dataset.initialized = "true";

    if (typeof L === "undefined") {
      status.textContent = mapEl.dataset.statusUnavailable;
      return;
    }

    var center = [parseFloat(mapEl.dataset.centerLat), parseFloat(mapEl.dataset.centerLng)];
    var map = L.map(mapEl).setView(center, parseInt(mapEl.dataset.zoom, 10));
    var marker = null;

    L.tileLayer(mapEl.dataset.tileUrl, {
      maxZoom: parseInt(mapEl.dataset.tileMaxZoom || "19", 10),
      attribution: mapEl.dataset.tileAttribution
    }).addTo(map);

    function store(lat, lng) {
      latInput.value = lat.toFixed(6);
      lngInput.value = lng.toFixed(6);
      status.textContent = mapEl.dataset.statusSelected;
    }

    function setMarker(lat, lng, recenter) {
      if (!validLatLng(lat, lng)) return;

      var latLng = [lat, lng];
      if (marker) {
        marker.setLatLng(latLng);
      } else {
        marker = L.marker(latLng, { draggable: true }).addTo(map);
        marker.on("dragend", function () {
          var next = marker.getLatLng();
          store(next.lat, next.lng);
        });
      }

      store(lat, lng);
      if (recenter) {
        map.setView(latLng, Math.max(map.getZoom(), 16));
      }
    }

    map.on("click", function (event) {
      setMarker(event.latlng.lat, event.latlng.lng, false);
    });

    var initialLat = coordinate(latInput.value);
    var initialLng = coordinate(lngInput.value);
    if (validLatLng(initialLat, initialLng)) {
      setMarker(initialLat, initialLng, true);
    }

    if (!geolocate) return;
    geolocate.addEventListener("click", function () {
      if (!navigator.geolocation) {
        status.textContent = mapEl.dataset.statusUnavailable;
        return;
      }

      geolocate.disabled = true;
      status.textContent = mapEl.dataset.statusLocating;
      navigator.geolocation.getCurrentPosition(
        function (position) {
          geolocate.disabled = false;
          setMarker(position.coords.latitude, position.coords.longitude, true);
        },
        function () {
          geolocate.disabled = false;
          status.textContent = mapEl.dataset.statusError;
        },
        { enableHighAccuracy: true, timeout: 10000, maximumAge: 300000 }
      );
    });
  }

  ready(init);
  document.addEventListener("turbo:load", init);
})();
