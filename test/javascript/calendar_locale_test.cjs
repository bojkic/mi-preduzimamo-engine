const assert = require("node:assert/strict");
const { test } = require("node:test");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "../../app/packs/src/decidim/bih/calendar_locale.js"), "utf8").replace("export const localizeCalendars", "globalThis.localizeCalendars");
const calendar = (locale) => ({ value: locale, matches: () => true, querySelectorAll: () => [], getAttribute() { return this.value; }, setAttribute(_name, value) { this.value = value; } });
const environment = () => {
  const listeners = {}, observers = [], nodes = [];
  const document = { readyState: "loading", documentElement: { lang: "sr" }, body: {}, addEventListener(name, callback) { listeners[name] = callback; }, querySelectorAll() { return nodes; } };
  class Observer {
    constructor(callback) { this.callback = callback; this.active = false; observers.push(this); }
    observe(_root, options) { this.active = true; assert.deepEqual(JSON.parse(JSON.stringify(options)), { childList: true, subtree: true }); }
    disconnect() { this.active = false; }
  }
  const context = { document, MutationObserver: Observer };
  vm.runInNewContext(source, context);
  return { context, document, listeners, observers, nodes };
};
test("Latin Serbian calendar requests Latin Intl names without changing route language", () => {
  const env = environment(), target = calendar("sr");
  env.context.localizeCalendars(target, "sr");
  assert.equal(target.value, "sr-Latn");
  assert.equal(env.document.documentElement.lang, "sr");
  assert.doesNotMatch(new Intl.DateTimeFormat(target.value, { month: "long", timeZone: "UTC" }).format(new Date("2026-12-15T00:00:00Z")), /[Ѐ-ӿ]/);
});
test("Cyrillic, Bosnian, Croatian and explicitly selected locales remain unchanged", () => {
  const env = environment();
  for (const locale of ["sr-Cyrl", "bs", "hr"]) {
    const target = calendar(locale); env.context.localizeCalendars(target, locale); assert.equal(target.value, locale);
  }
  const explicit = calendar("hr"); env.context.localizeCalendars(explicit, "sr"); assert.equal(explicit.value, "hr");
  assert.doesNotThrow(() => env.context.localizeCalendars({}, "sr"));
});
test("Late Stimulus widgets are localized and Turbo does not accumulate observers", () => {
  const env = environment();
  const first = calendar("sr"); env.nodes.push(first); env.listeners.DOMContentLoaded();
  assert.equal(first.value, "sr-Latn");
  const late = calendar("sr"); env.observers[0].callback([{ addedNodes: [late, {}] }]); assert.equal(late.value, "sr-Latn");
  env.listeners["turbo:load"](); assert.equal(env.observers.filter((item) => item.active).length, 1);
  env.document.documentElement.lang = "sr-Cyrl"; env.listeners["turbo:load"](); assert.equal(env.observers.filter((item) => item.active).length, 0);
});
