// wc-datepicker exposes labels, but delegates month/day names to browser ICU.
// Keep route locales unchanged and supply Bosnian names where ICU is incomplete.
const copy = {
  sr: ["Izaberi datum", "Izaberi mjesec", "Izaberi godinu", "Prethodni mjesec", "Sljedeći mjesec", "Prethodna godina", "Sljedeća godina", "Prikaži danas", "Obriši vrijednost"],
  "sr-Cyrl": ["Изабери датум", "Изабери мјесец", "Изабери годину", "Претходни мјесец", "Сљедећи мјесец", "Претходна година", "Сљедећа година", "Прикажи данас", "Обриши вриједност"],
  bs: ["Odaberi datum", "Odaberi mjesec", "Odaberi godinu", "Prethodni mjesec", "Sljedeći mjesec", "Prethodna godina", "Sljedeća godina", "Prikaži danas", "Obriši vrijednost"],
  hr: ["Odaberi datum", "Odaberi mjesec", "Odaberi godinu", "Prethodni mjesec", "Sljedeći mjesec", "Prethodna godina", "Sljedeća godina", "Prikaži danas", "Očisti vrijednost"]
};
const keys = ["picker", "monthSelect", "yearSelect", "previousMonthButton", "nextMonthButton", "previousYearButton", "nextYearButton", "todayButton", "clearButton"];
const english = ["Choose date", "Select month", "Select year", "Previous month", "Next month", "Previous year", "Next year", "Show today", "Clear value"];
const months = ["januar", "februar", "mart", "april", "maj", "juni", "juli", "august", "septembar", "oktobar", "novembar", "decembar"];
const weekdays = [["ned", "nedjelja"], ["pon", "ponedjeljak"], ["uto", "utorak"], ["sri", "srijeda"], ["čet", "četvrtak"], ["pet", "petak"], ["sub", "subota"]];
const states = new WeakMap();
const text = (node, value) => {
  if (!node || node.textContent === value) return;
  // Keep Stencil's existing text node so its virtual DOM retains a valid ref.
  if (node.firstChild?.nodeType === 3 && node.childNodes.length === 1) node.firstChild.data = value;
  else node.textContent = value;
};

const bosnianNames = (calendar) => {
  // This component renders scoped light DOM. Correct only presentation, never
  // input values, selected dates, event handlers, navigation or the global Intl.
  calendar.querySelectorAll("select[name='month'] option").forEach((option) => {
    const name = months[Number(option.value) - 1];
    if (name) text(option, name);
  });
  const first = Number(calendar.firstDayOfWeek || 0);
  calendar.querySelectorAll("th[scope='col']").forEach((heading, index) => {
    const day = weekdays[((first + index) % 7 + 7) % 7];
    if (heading.getAttribute("abbr") !== day[1]) heading.setAttribute("abbr", day[1]);
    text(heading.querySelector("span"), day[0]);
  });
  calendar.querySelectorAll("[data-date]").forEach((cell) => {
    const date = /^(\d{4})-(\d{2})-(\d{2})$/.exec(cell.getAttribute("data-date"));
    if (date && months[Number(date[2]) - 1]) {
      text(cell.querySelector(".visually-hidden"), `${Number(date[3])}. ${months[Number(date[2]) - 1]}`);
    }
  });
  const month = Number(calendar.querySelector("select[name='month']")?.value);
  const year = calendar.querySelector("input[name='year']")?.value;
  if (months[month - 1] && /^\d{1,4}$/.test(year || "")) {
    text(calendar.querySelector(".wc-datepicker__header > .visually-hidden"), `${months[month - 1]} ${year}.`);
  }
};

const labels = (calendar, locale) => {
  const previous = states.get(calendar);
  if (previous?.locale === locale) return;
  const state = { locale };
  states.set(calendar, state);
  const apply = () => {
    if (states.get(calendar) !== state) return;
    if (calendar.isConnected === false) {
      states.delete(calendar);
      return;
    }
    const existing = calendar.labels || {};
    const translated = { ...existing };
    keys.forEach((key, index) => {
      const value = existing[key];
      if (!value || value === english[index] || value === copy[previous?.locale]?.[index]) translated[key] = copy[locale][index];
    });
    calendar.labels = translated;
    if (locale === "bs") bosnianNames(calendar);
  };
  // Wait for Stencil's property accessors; an early own property can shadow them.
  const ready = () => typeof calendar.componentOnReady === "function" ? calendar.componentOnReady().then(apply) : apply();
  if (typeof customElements !== "undefined") customElements.whenDefined("wc-datepicker").then(ready);
  else ready();
};

export const localizeCalendars = (root, locale) => {
  if (!root) return;
  const calendars = new Set();
  if (root.matches?.("wc-datepicker")) calendars.add(root);
  const parent = root.parentElement?.closest?.("wc-datepicker");
  if (parent) calendars.add(parent);
  root.querySelectorAll?.("wc-datepicker").forEach((calendar) => calendars.add(calendar));
  calendars.forEach((calendar) => {
    let chosen = calendar.getAttribute("locale") || locale;
    if (chosen === "sr" && locale === "sr") {
      calendar.setAttribute("locale", "sr-Latn");
      chosen = "sr-Latn";
    }
    const language = chosen === "sr-Latn" ? "sr" : chosen;
    if (!copy[language]) return;
    labels(calendar, language);
    if (language === "bs") bosnianNames(calendar);
  });
};

let observer;
const initialize = () => {
  observer?.disconnect();
  const locale = document.documentElement.lang;
  localizeCalendars(document, locale);
  if (!copy[locale] || !document.body) return;
  observer = new MutationObserver((changes) => {
    const roots = new Set();
    changes.forEach((change) => {
      roots.add(change.target);
      change.addedNodes.forEach((node) => roots.add(node));
    });
    roots.forEach((node) => localizeCalendars(node, locale));
  });
  observer.observe(document.body, { childList: true, characterData: true, subtree: true });
};

document.addEventListener("DOMContentLoaded", initialize);
document.addEventListener("turbo:load", initialize);
if (document.readyState !== "loading") initialize();
