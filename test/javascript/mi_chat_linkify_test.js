const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const assetPath = path.join(__dirname, "../../public/mi/mi-chat.js");
const source = fs.readFileSync(assetPath, "utf8");
const start = source.indexOf("  function linkPunctuation(url) {");
const end = source.indexOf("  // ---- transcript rendering", start);
assert.ok(start >= 0 && end > start, "packaged link renderer must be present");

// Run the packaged renderer without booting the widget, Rails or a browser.
function render(text) {
  const nodes = [];
  const context = {
    URL,
    window: { location: { origin: "https://example.test" } },
    document: { createTextNode: (value) => ({ tag: "#text", textContent: value }) },
    el: (tag, _className, attributes) => ({ tag, attributes, textContent: "" })
  };
  vm.runInNewContext(source.slice(start, end), context, { filename: assetPath, timeout: 1000 });
  context.appendSafeText({ appendChild: (node) => nodes.push(node) }, text);
  return {
    text: nodes.map((node) => node.textContent).join(""),
    anchors: nodes.filter((node) => node.tag === "a")
  };
}

test("packaged chat keeps units, zones and ratios as plain text", () => {
  const text = "Cijena 1,50 KM/h; crvena/I zona; omjer 3/4; ulica/broj.";
  const result = render(text);
  assert.equal(result.text, text);
  assert.equal(result.anchors.length, 0);
});

test("root-relative links cannot begin inside Unicode words or identifiers", () => {
  [
    "a/h", "Ж/h", "c\u030C/h", "\u0301/h", "2/h", "_/h",
    "\u{10400}/h", "\u{1D165}/h", "\u{1D7D9}/h"
  ].forEach((text) => {
    const result = render(text);
    assert.equal(result.text, text);
    assert.equal(result.anchors.length, 0, text);
  });
});

test("separated root-relative and absolute links remain usable", () => {
  [
    ["/registracija", ["/registracija"]],
    ["Obrazac: (/biceriseno/prijave/new).", ["/biceriseno/prijave/new"]],
    ["Cijena KM/h; obrazac /registracija.", ["/registracija"]],
    ["Nalog:\n/registracija i https://example.test/help?q=1#answer.",
      ["/registracija", "https://example.test/help?q=1#answer"]]
  ].forEach(([text, expected]) => {
    const result = render(text);
    assert.equal(result.text, text);
    assert.deepEqual(result.anchors.map((anchor) => anchor.attributes.href), expected);
    result.anchors.forEach((anchor) => {
      assert.equal(anchor.attributes.target, "_blank");
      assert.equal(anchor.attributes.rel, "noopener noreferrer");
    });
  });
});

test("existing unsafe-link guards remain intact", () => {
  [
    "//evil.example/path", "\\/registracija", "javascript:/registracija",
    "<img src=/unsafe onerror=alert(1)>", "</script>",
    "https://evil.example\\@example.test/path", "https://example.test/\u0001bad"
  ].forEach((text) => {
    const result = render(text);
    assert.equal(result.text, text);
    assert.equal(result.anchors.length, 0, text);
  });
});
