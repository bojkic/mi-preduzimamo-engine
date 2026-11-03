const assert = require("node:assert/strict");
const { test } = require("node:test");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "../../app/packs/src/decidim/bih/calendar_locale.js"), "utf8").replace("export const localizeCalendars", "globalThis.localizeCalendars");
const calendar = (locale) => ({
  value: locale, labels: {}, matches: () => true, querySelectorAll: () => [], querySelector: () => null,
  getAttribute() { return this.value; }, setAttribute(_name, value) { this.value = value; }
});
const environment = (extra = {}) => {
  const listeners = {}, observers = [], nodes = [];
  const document = { readyState: "loading", documentElement: { lang: "sr" }, body: {}, addEventListener(name, callback) { listeners[name] = callback; }, querySelectorAll() { return nodes; } };
  class Observer {
    constructor(callback) { this.callback = callback; this.active = false; observers.push(this); }
    observe(_root, options) { this.active = true; assert.deepEqual(JSON.parse(JSON.stringify(options)), { childList: true, characterData: true, subtree: true }); }
    disconnect() { this.active = false; }
  }
  const context = { document, MutationObserver: Observer, ...extra };
  vm.runInNewContext(source, context);
  return { context, document, listeners, observers, nodes };
};
test("Latin Serbian calendar requests Latin Intl names without changing route language", () => {
  const env = environment(), target = calendar("sr");
  env.context.localizeCalendars(target, "sr");
  assert.equal(target.value, "sr-Latn");
  assert.equal(target.labels.picker, "Izaberi datum");
  assert.equal(env.document.documentElement.lang, "sr");
  assert.doesNotMatch(new Intl.DateTimeFormat(target.value, { month: "long", timeZone: "UTC" }).format(new Date("2026-12-15T00:00:00Z")), /[Ѐ-ӿ]/);
});
test("all four languages receive internal labels while explicit locales and custom copy survive", () => {
  const env = environment();
  const expected = { sr: "Prethodni mjesec", "sr-Cyrl": "Претходни мјесец", bs: "Prethodni mjesec", hr: "Prethodni mjesec" };
  for (const locale of Object.keys(expected)) {
    const target = calendar(locale); env.context.localizeCalendars(target, locale);
    assert.equal(target.labels.previousMonthButton, expected[locale]);
    assert.equal(Object.keys(target.labels).length, 9);
    assert.doesNotMatch(Object.values(target.labels).join(" "), /Choose|Select|Previous|Next|Show|Clear/);
  }
  const explicit = calendar("hr"); explicit.labels.picker = "Posebni datum";
  env.context.localizeCalendars(explicit, "sr");
  assert.equal(explicit.value, "hr"); assert.equal(explicit.labels.picker, "Posebni datum");
  assert.doesNotThrow(() => env.context.localizeCalendars({}, "sr"));
});
test("late widgets and all supported Turbo locales keep just one observer", () => {
  const env = environment();
  const first = calendar("sr"); env.nodes.push(first); env.listeners.DOMContentLoaded();
  assert.equal(first.value, "sr-Latn");
  const late = calendar("sr"); env.observers[0].callback([{ addedNodes: [late, {}] }]); assert.equal(late.value, "sr-Latn");
  for (const locale of ["sr", "sr-Cyrl", "bs", "hr"]) {
    env.document.documentElement.lang = locale; env.listeners["turbo:load"]();
    assert.equal(env.observers.filter((item) => item.active).length, 1);
  }
  env.document.documentElement.lang = "en"; env.listeners["turbo:load"]();
  assert.equal(env.observers.filter((item) => item.active).length, 0);
});
const bosnianCalendar = () => {
  const target = calendar("bs"); let writes = 0;
  const text = (initial) => ({ get textContent() { return initial; }, set textContent(value) { initial = value; writes++; } });
  const options = Array.from({ length: 12 }, (_, index) => Object.assign(text(`M${index + 1}`), { value: String(index + 1) }));
  const headings = Array.from({ length: 7 }, () => {
    const span = text("Sun"); let abbr = "Sunday";
    return { span, getAttribute: () => abbr, setAttribute(_name, value) { abbr = value; writes++; }, querySelector: () => span };
  });
  const hidden = text("M12 15"), title = text("M12 2026");
  const cell = { getAttribute: () => "2026-12-15", querySelector: () => hidden };
  target.month = { value: "12" }; target.year = { value: "2026" };
  target.querySelectorAll = (selector) => ({ "select[name='month'] option": options, "th[scope='col']": headings, "[data-date]": [cell] }[selector] || []);
  target.querySelector = (selector) => ({ "select[name='month']": target.month, "input[name='year']": target.year, ".wc-datepicker__header > .visually-hidden": title }[selector] || null);
  return { target, options, headings, hidden, title, writes: () => writes };
};
test("Bosnian visible and accessible names do not depend on browser ICU; dates remain intact", () => {
  const env = environment(), fixture = bosnianCalendar();
  env.context.localizeCalendars(fixture.target, "bs");
  assert.equal(fixture.options.map((item) => item.textContent).join(","), "januar,februar,mart,april,maj,juni,juli,august,septembar,oktobar,novembar,decembar");
  assert.equal(fixture.headings.map((item) => item.span.textContent).join(","), "ned,pon,uto,sri,čet,pet,sub");
  assert.equal(fixture.headings[3].getAttribute("abbr"), "srijeda");
  assert.equal(fixture.hidden.textContent, "15. decembar");
  assert.equal(fixture.title.textContent, "decembar 2026.");
  assert.equal(fixture.target.month.value, "12"); assert.equal(fixture.target.year.value, "2026");
});
test("Bosnian redraw and Monday-first order are corrected without an observer write loop", () => {
  const env = environment(), fixture = bosnianCalendar(); fixture.target.firstDayOfWeek = 1;
  env.context.localizeCalendars(fixture.target, "bs");
  assert.equal(fixture.headings[0].span.textContent, "pon");
  fixture.options[11].textContent = "M12"; fixture.target.month.value = "1";
  const inside = { parentElement: { closest: () => fixture.target } };
  env.context.localizeCalendars(inside, "bs");
  assert.equal(fixture.options[11].textContent, "decembar"); assert.equal(fixture.title.textContent, "januar 2026.");
  const writes = fixture.writes();
  for (let index = 0; index < 10; index++) env.context.localizeCalendars(inside, "bs");
  assert.equal(fixture.writes(), writes);
});
test("Stencil labels wait for definition and hydration", async () => {
  let defined, hydrated;
  const definition = new Promise((resolve) => { defined = resolve; });
  const hydration = new Promise((resolve) => { hydrated = resolve; });
  const env = environment({ customElements: { whenDefined: () => definition } }), target = calendar("hr");
  target.componentOnReady = () => hydration;
  env.context.localizeCalendars(target, "hr"); assert.equal(Object.keys(target.labels).length, 0);
  defined(); await Promise.resolve(); assert.equal(Object.keys(target.labels).length, 0);
  hydrated(); await Promise.resolve(); await Promise.resolve();
  assert.equal(target.labels.picker, "Odaberi datum");
});
test("detached widgets can be initialized again when reconnected", async () => {
  const env = environment(), target = calendar("bs"); target.isConnected = false;
  env.context.localizeCalendars(target, "bs"); assert.equal(Object.keys(target.labels).length, 0);
  target.isConnected = true; env.context.localizeCalendars(target, "bs");
  assert.equal(target.labels.monthSelect, "Odaberi mjesec");
});

test("Bosnian corrections preserve existing renderer text-node references", () => {
  const env = environment(), fixture = bosnianCalendar();
  const firstChild = { nodeType: 3, data: "M1" };
  const option = fixture.options[0];
  Object.defineProperty(option, "textContent", { configurable: true, get: () => firstChild.data, set: () => assert.fail("must preserve renderer text node") });
  option.firstChild = firstChild; option.childNodes = [firstChild];
  env.context.localizeCalendars(fixture.target, "bs");
  assert.equal(option.firstChild, firstChild); assert.equal(firstChild.data, "januar");
});
