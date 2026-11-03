// Keep route/I18n locale sr while requesting Latin month/day names from Intl.
export const localizeCalendars = (root, locale) => {
  if (locale !== "sr") return;
  const calendars = [];
  if (root.matches?.("wc-datepicker")) calendars.push(root);
  root.querySelectorAll?.("wc-datepicker").forEach((calendar) => calendars.push(calendar));
  calendars.forEach((calendar) => {
    if (calendar.getAttribute("locale") === "sr") calendar.setAttribute("locale", "sr-Latn");
  });
};

let observer;
const initialize = () => {
  observer?.disconnect();
  const locale = document.documentElement.lang;
  localizeCalendars(document, locale);
  if (locale !== "sr" || !document.body) return;
  observer = new MutationObserver((changes) => {
    changes.forEach((change) => change.addedNodes.forEach((node) => localizeCalendars(node, locale)));
  });
  observer.observe(document.body, { childList: true, subtree: true });
};

document.addEventListener("DOMContentLoaded", initialize);
document.addEventListener("turbo:load", initialize);
if (document.readyState !== "loading") initialize();
