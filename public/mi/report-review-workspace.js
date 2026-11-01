/* Conditional fields for the private report review workspace. */
(function () {
  "use strict";
  function init() {
    var form = document.getElementById("report-decision-form");
    if (!form || form.dataset.ready) return;
    form.dataset.ready = "1";
    var action = form.querySelector("#decision_action");
    var submit = form.querySelector("[data-decision-submit]");
    ["address", "location_kind", "latitude", "longitude", "location_end_latitude", "location_end_longitude"].forEach(function (name) {
      var field = form.querySelector('[name="decision[' + name + ']"]');
      if (field) field.addEventListener("change", function () {
        form.querySelector('[name="decision[edit_location]"]').checked = true;
      });
    });
    var candidates = form.querySelector("#duplicate-candidates");
    var candidateRequest = 0;
    function loadCandidates() {
      if (!candidates) return;
      var request = ++candidateRequest;
      var query = form.querySelector("#duplicate-search").value;
      candidates.setAttribute("aria-busy", "true");
      fetch(candidates.dataset.url + "?q=" + encodeURIComponent(query), {credentials: "same-origin", headers: {"X-Requested-With": "XMLHttpRequest"}})
        .then(function (response) { if (!response.ok || response.redirected) throw new Error("unavailable"); return response.text(); })
        .then(function (html) { if (request === candidateRequest) candidates.innerHTML = html; })
        .catch(function () { if (request === candidateRequest) candidates.textContent = candidates.dataset.error; })
        .finally(function () { if (request === candidateRequest) candidates.removeAttribute("aria-busy"); });
    }
    if (candidates) {
      form.querySelector("#duplicate-search-button").addEventListener("click", loadCandidates);
      form.querySelector("#duplicate-search").addEventListener("keydown", function (event) {
        if (event.key === "Enter") { event.preventDefault(); loadCandidates(); }
      });
      candidates.addEventListener("click", function (event) {
        var button = event.target.closest("[data-select-duplicate]");
        if (!button) return;
        var reference = form.querySelector('[name="decision[duplicate_reference]"]');
        reference.value = button.dataset.selectDuplicate;
        reference.focus();
      });
    }
    function refresh() {
      var value = action.value;
      if (value === "duplicate" && candidates && !candidates.dataset.loaded) {
        candidates.dataset.loaded = "1";
        loadCandidates();
      }
      form.querySelectorAll("[data-actions]").forEach(function (section) {
        var visible = section.dataset.actions.split(" ").indexOf(value) !== -1;
        section.hidden = !visible;
        section.querySelectorAll("input,select,textarea").forEach(function (control) { control.disabled = !visible; });
      });
      var collection = form.querySelector('[name="decision[report_collection_id]"]');
      var fresh = form.querySelector("[data-new-collection]");
      if (fresh && collection) {
        fresh.hidden = Boolean(collection.value);
        fresh.querySelectorAll("textarea").forEach(function (field) { field.disabled = value !== "plan" || fresh.hidden; });
      }
      var send = ["send", "supplement", "followup"].indexOf(value) !== -1;
      var needsConfirmation = !send && ["claim", "assign", "note"].indexOf(value) === -1;
      form.querySelector("[data-confirmation]").hidden = !needsConfirmation;
      var confirmation = form.querySelector('[name="confirm_decision"]');
      confirmation.required = needsConfirmation;
      confirmation.disabled = !needsConfirmation;
      form.querySelector("[data-private-note]").hidden = value !== "note";
      submit.value = send ? submit.dataset.sendLabel : submit.dataset.saveLabel;
      submit.dataset.disableWith = submit.value;
    }
    action.addEventListener("change", function () {
      refresh();
      // The message box sits below the classification section; bring it into view.
      if (["ask", "message", "supplement", "followup", "service_response"].indexOf(action.value) === -1) return;
      var body = form.querySelector('[name="decision[body]"]:not([disabled])');
      if (body) { body.scrollIntoView({block: "center"}); body.focus({preventScroll: true}); }
    });
    var collection = form.querySelector('[name="decision[report_collection_id]"]');
    if (collection) collection.addEventListener("change", refresh);
    refresh();
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init, {once: true}); else init();
})();
