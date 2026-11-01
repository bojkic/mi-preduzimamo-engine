/* Private board composition: a bounded per-tab text draft, never an upload. */
(function () {
  "use strict";
  function init() {
    const board = document.querySelector("[data-board-draft-scope]");
    if (!board || board.dataset.boardReady) return;
    board.dataset.boardReady = "1";
    const filters = board.querySelector("[data-board-filters]");
    if (filters && filters.dataset.boardFilterActive !== "1" && window.matchMedia("(max-width:767px)").matches) {
      filters.open = false;
    }
    const prefix = "mi:board:draft:" + board.dataset.boardDraftScope + ":";
    const ttl = 2 * 60 * 60 * 1000;
    function remove(key) { try { sessionStorage.removeItem(key); } catch (_) {} }
    try {
      Object.keys(sessionStorage).filter(function (key) { return key.indexOf("mi:board:draft:") === 0; }).forEach(function (key) {
        const draft = JSON.parse(sessionStorage.getItem(key) || "null");
        if (!draft || !draft.at || Date.now() - draft.at > ttl) remove(key);
      });
    } catch (_) { /* Storage can be unavailable in private browsing. */ }
    if (board.dataset.boardDraftClear) {
      remove(prefix + "new");
      remove(prefix + board.dataset.boardDraftClear);
    }
    const composer = document.getElementById("komsiluk-compose");
    document.querySelectorAll("[data-board-compose]").forEach(function (link) {
      link.addEventListener("click", function (event) {
        if (!composer) return;
        event.preventDefault(); composer.open = true; composer.scrollIntoView({ block: "start" });
        const target = composer.querySelector("input:not([type=hidden]), select, a");
        if (target) target.focus({ preventScroll: true });
      });
    });
    const form = board.querySelector("[data-board-form]");
    if (!form) return;
    const key = prefix + form.dataset.draftKey;
    const fields = Array.from(form.querySelectorAll("[data-board-field]"));
    const status = form.querySelector("[data-board-draft-status]");
    const revision = (form.querySelector("[name='komsiluk_post[content_revision]']") || {}).value || "new";
    if (!form.querySelector("[data-board-errors]")) {
      try {
        const saved = JSON.parse(sessionStorage.getItem(key) || "null");
        if (saved && saved.revision === revision && saved.at > Date.now() - ttl && saved.values) {
          fields.forEach(function (field) {
            if (!Object.prototype.hasOwnProperty.call(saved.values, field.name)) return;
            if (field.type === "checkbox") field.checked = saved.values[field.name] === true;
            else field.value = String(saved.values[field.name]).slice(0, Math.max(field.maxLength || 0, 1000));
          });
          if (composer) composer.open = true;
          if (status) status.textContent = form.dataset.draftSaved;
        }
      } catch (_) { remove(key); }
    }
    function feedback() {
      fields.forEach(function (field) {
        const counter = field.dataset.countTarget && document.getElementById(field.dataset.countTarget);
        if (counter) counter.textContent = Array.from(field.value).length + " / " + field.maxLength;
      });
      const category = document.getElementById("komsiluk_post_category");
      const expiry = document.getElementById("komsiluk_post_expires_at");
      if (category && expiry) expiry.required = category.value === "activity";
    }
    function save() {
      const values = {};
      fields.forEach(function (field) { values[field.name] = field.type === "checkbox" ? field.checked : field.value; });
      try {
        const data = JSON.stringify({ at: Date.now(), revision: revision, values: values });
        if (data.length <= 12000) { sessionStorage.setItem(key, data); if (status) status.textContent = form.dataset.draftSaved; }
      } catch (_) { /* Submission remains usable without browser storage. */ }
      feedback();
    }
    form.addEventListener("input", save);
    form.addEventListener("change", save);
    form.addEventListener("submit", save);
    const discard = form.querySelector("[data-board-discard]");
    if (discard) discard.addEventListener("click", function () { remove(key); if (form.dataset.discardUrl) window.location.assign(form.dataset.discardUrl); else { form.reset(); feedback(); } });
    const errors = form.querySelector("[data-board-errors]");
    if (errors) errors.focus();
    feedback();
  }
  document.addEventListener("DOMContentLoaded", init);
  document.addEventListener("turbo:load", init);
  if (document.readyState !== "loading") init();
}());
