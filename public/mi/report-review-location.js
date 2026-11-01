/* Private operator location editor; uses the existing local Leaflet bundle. */
(function () {
  "use strict";
  function init() {
    var el = document.getElementById("report-case-location-map");
    var form = document.getElementById("report-decision-form");
    if (!el || !form || el.dataset.ready || !window.L) return;
    el.dataset.ready = "1";
    var map = L.map(el).setView([Number(el.dataset.centerLat), Number(el.dataset.centerLng)], 14);
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {maxZoom: 19, attribution: "© OpenStreetMap contributors"}).addTo(map);
    var markers = {}, line;
    function field(name) { return form.querySelector('[name="decision[' + name + ']"]'); }
    function names(end) { return end ? ["location_end_latitude", "location_end_longitude"] : ["latitude", "longitude"]; }
    function position(end) {
      var keys = names(end), lat = field(keys[0]).value, lng = field(keys[1]).value;
      if (!lat || !lng || !Number.isFinite(Number(lat)) || !Number.isFinite(Number(lng))) return null;
      return [Number(lat), Number(lng)];
    }
    function set(end, point) {
      form.querySelector('[name="decision[edit_location]"]').checked = true;
      var keys = names(end); field(keys[0]).value = point.lat.toFixed(6); field(keys[1]).value = point.lng.toFixed(6);
      if (end) field("location_kind").value = "segment";
      else if (field("location_kind").value === "description") field("location_kind").value = "point";
      draw();
    }
    function draw() {
      [false, true].forEach(function (end) {
        var key = end ? "end" : "start", pos = position(end);
        if (markers[key]) { map.removeLayer(markers[key]); delete markers[key]; }
        if (pos) {
          markers[key] = L.marker(pos, {draggable: true}).addTo(map);
          markers[key].on("dragend", function (e) { set(end, e.target.getLatLng()); });
        }
      });
      if (line) map.removeLayer(line);
      if (position(false) && position(true)) line = L.polyline([position(false), position(true)], {color: "#64748b"}).addTo(map);
    }
    map.on("click", function (e) { set(document.getElementById("report-location-target").value === "end", e.latlng); });
    names(false).concat(names(true)).forEach(function (name) { field(name).addEventListener("change", draw); });
    document.getElementById("report-location-clear").addEventListener("click", function () {
      form.querySelector('[name="decision[edit_location]"]').checked = true;
      names(false).concat(names(true)).forEach(function (name) { field(name).value = ""; });
      if (field("location_kind").value !== "segment") field("location_kind").value = "description";
      draw();
    });
    form.querySelectorAll("details").forEach(function (details) { details.addEventListener("toggle", function () { map.invalidateSize(); }); });
    draw();
    if (position(false) && position(true)) map.fitBounds([position(false), position(true)], {padding: [24,24]});
    else if (position(false)) map.setView(position(false), 16);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init, {once: true}); else init();
})();
