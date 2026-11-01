const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const source = fs.readFileSync(
  path.join(__dirname, "../../public/mi/mi-install.js"),
  "utf8"
);

test("packaged install asset carries the authenticated landing contract", () => {
  [
    "history.replaceState",
    "beforeinstallprompt",
    "sessionStorage",
    "manualText",
    "webviewText",
    "MutationObserver",
    "mi-install-go"
  ].forEach((marker) => assert.match(source, new RegExp(marker.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))));
  assert.match(source, /Instaliraj aplikaciju platforme/);
  assert.doesNotMatch(source, /Instaliraj MI/);
  assert.doesNotMatch(source, /Dodaj MI/);
});
