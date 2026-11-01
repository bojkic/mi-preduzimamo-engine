const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const assetPath = process.env.MILICA_WIDGET_ASSET || path.join(__dirname, "../../public/mi/mi-chat.js");
const source = fs.readFileSync(assetPath, "utf8");

// Exercise the packaged feedback functions, including click handlers and the
// request/result boundary. No network or DOM package is used.
function feedbackWidget(offerCapture, response = { ok: true, status: 200, body: { status: "ok" } }, feedback = { id: "reply-id", token: "signed-token", url: "/chat/feedback" }) {
  function node(tag, className, attributes = {}) {
    return {
      tag, className, attributes, children: [], events: {}, textContent: "", disabled: false,
      appendChild(child) { this.children.push(child); return child; },
      setAttribute(key, value) { this.attributes[key] = value; },
      getAttribute(key) { return this.attributes[key]; },
      addEventListener(name, callback) { this.events[name] = callback; },
      querySelectorAll(selector) {
        return this.children.flatMap((child) => [child, ...child.querySelectorAll(selector)])
          .filter((child) => String(child.className).split(" ").includes(selector.slice(1)));
      }
    };
  }
  const calls = [];
  const context = {
    el: node, svg: () => node("svg"), document: { createTextNode: (text) => Object.assign(node("#text"), { textContent: text }) },
    FEEDBACK: { retention_disclosure: "Voluntary: keep question and answer for private review.", helpful: "Korisno", not_helpful: "Nije korisno", share_question: "Sačuvaj pitanje", shared: "Sačuvano za pregled.", thanks: "Hvala za ocjenu.", error: "Nije sačuvano.", unavailable: "Ocjena je istekla ili nije dostupna." },
    ICON_THUMBS_UP: "up", ICON_THUMBS_DOWN: "down", ICON_SEND: "send", FEEDBACK_TIMEOUT_MS: 10000,
    scrollToEnd() {}, csrfToken: () => "csrf-value",
    timedFetch(url, options, timeout, transform) {
      calls.push({ url, options, timeout });
      return Promise.resolve().then(() => transform({ ok: response.ok, status: response.status, json: () => Promise.resolve(response.body) }));
    }
  };
  const feedbackStart = source.indexOf("  function validFeedback(feedback) {");
  const feedbackEnd = source.indexOf("  // A timeout only bounds", feedbackStart);
  assert.ok(feedbackStart >= 0 && feedbackEnd > feedbackStart);
  vm.runInNewContext(source.slice(feedbackStart, feedbackEnd), context, { filename: assetPath, timeout: 1000 });
  const row = node("div");
  context.addFeedback(row, feedback, offerCapture);
  return { row, calls, wrap: row.children[0], context };
}

const flushFeedback = () => new Promise((resolve) => setImmediate(resolve));

test("feedback rendering discloses retention before any voluntary click and sends nothing", () => {
  [undefined, false, "true", 1, true].forEach((flag) => {
    const widget = feedbackWidget(flag);
    assert.equal(widget.calls.length, 0);
    assert.equal(widget.wrap.children[0].className, "mi-chat__feedback-disclosure");
    assert.match(widget.wrap.children[0].textContent, /question and answer/);
    const buttons = widget.wrap.querySelectorAll(".mi-chat__feedback-button");
    assert.deepEqual(buttons.map((button) => button.attributes["data-value"]), flag === true ? ["helpful", "not_helpful", "share_question"] : ["helpful", "not_helpful"]);
  });
  const invalid = feedbackWidget(true, undefined, { id: "reply-id", url: "/chat/feedback" });
  assert.equal(invalid.row.children.length, 0);
  assert.equal(invalid.calls.length, 0);
  assert.ok(/addFeedback\(replyRow, data\.feedback, data\.offer_capture(?: === true)?\)/.test(source), "actual reply wiring must pass capture eligibility");
});

test("explicit capture click keeps signed token and only confirms a successful server save", async () => {
  const widget = feedbackWidget(true);
  const button = widget.wrap.querySelectorAll(".mi-chat__feedback-button")[2];
  button.events.click();
  assert.equal(widget.calls.length, 1);
  const request = widget.calls[0];
  assert.equal(request.url, "/chat/feedback");
  assert.equal(request.options.credentials, "same-origin");
  assert.equal(request.options.headers["X-CSRF-Token"], "csrf-value");
  assert.deepEqual(JSON.parse(request.options.body), { reply_id: "reply-id", token: "signed-token", value: "share_question" });
  const status = widget.wrap.children.at(-1);
  assert.equal(status.textContent, "");
  await flushFeedback();
  assert.equal(status.textContent, "Sačuvano za pregled.");
  assert.equal(button.attributes["aria-pressed"], "true");
  const ratings = widget.wrap.querySelectorAll(".mi-chat__feedback-button").slice(0, 2);
  ratings.forEach((rating) => assert.equal(rating.disabled, false));
  ratings[1].events.click();
  await flushFeedback();
  assert.equal(JSON.parse(widget.calls[1].options.body).value, "not_helpful");
  assert.equal(widget.wrap.children.at(-1).textContent, "Hvala za ocjenu.");
});

test("ratings stay ratings and never implicitly request unanswered-question capture", async () => {
  for (const value of ["helpful", "not_helpful"]) {
    const widget = feedbackWidget(true);
    const button = widget.wrap.querySelectorAll(".mi-chat__feedback-button").find((item) => item.attributes["data-value"] === value);
    button.events.click();
    await flushFeedback();
    assert.equal(widget.calls.length, 1);
    assert.equal(JSON.parse(widget.calls[0].options.body).value, value);
    assert.equal(widget.wrap.children.at(-1).textContent, "Hvala za ocjenu.");
  }
});

test("rejected and failed capture requests show no saved claim and allow an explicit retry", async () => {
  for (const response of [{ ok: false, status: 500 }, { ok: true, status: 200, body: { status: "error" } }]) {
    const widget = feedbackWidget(true, response);
    const buttons = widget.wrap.querySelectorAll(".mi-chat__feedback-button");
    buttons[2].events.click();
    await flushFeedback();
    assert.equal(widget.calls.length, 1);
    assert.equal(widget.wrap.children.at(-1).textContent, "Nije sačuvano.");
    buttons.forEach((button) => {
      assert.equal(button.disabled, false);
      assert.equal(button.attributes["aria-pressed"], "false");
    });
  }
});


test("expired or unavailable rating tokens show a clear final message without retry or saved claim", async () => {
  const widget = feedbackWidget(true, { ok: false, status: 422, body: { status: "invalid", reason: "feedback_unavailable" } });
  const buttons = widget.wrap.querySelectorAll(".mi-chat__feedback-button");
  buttons[0].events.click();
  await flushFeedback();
  assert.equal(widget.calls.length, 1);
  assert.equal(widget.wrap.children.at(-1).textContent, "Ocjena je istekla ili nije dostupna.");
  buttons.forEach((button) => {
    assert.equal(button.disabled, true);
    assert.equal(button.attributes["aria-pressed"], "false");
  });
});


test("the other thumb changes the same reply rating and duplicate in-flight dispatch is blocked", async () => {
  const widget = feedbackWidget(true);
  const [up, down, share] = widget.wrap.querySelectorAll(".mi-chat__feedback-button");
  up.events.click();
  down.events.click();
  up.events.click();
  assert.equal(widget.calls.length, 1, "even directly invoked handlers cannot dispatch while busy");
  await flushFeedback();
  assert.deepEqual([up.disabled, down.disabled, share.disabled], [true, false, true]);
  up.events.click();
  share.events.click();
  assert.equal(widget.calls.length, 1, "settled rating and redundant capture cannot be resubmitted");
  down.events.click();
  assert.deepEqual([up.disabled, down.disabled, share.disabled], [true, true, true]);
  await flushFeedback();
  assert.deepEqual([up.disabled, down.disabled, share.disabled], [false, true, true]);
  assert.equal(up.attributes["aria-pressed"], "false");
  assert.equal(down.attributes["aria-pressed"], "true");
  assert.deepEqual(widget.calls.map((call) => JSON.parse(call.options.body)), [
    { reply_id: "reply-id", token: "signed-token", value: "helpful" },
    { reply_id: "reply-id", token: "signed-token", value: "not_helpful" }
  ]);
  up.events.click();
  await flushFeedback();
  assert.equal(widget.calls.length, 3);
  assert.deepEqual([up.disabled, down.disabled, share.disabled], [true, false, true]);
});

test("an expired token also blocks direct handler retries", async () => {
  const widget = feedbackWidget(false, { ok: false, status: 422 });
  const [up, down] = widget.wrap.querySelectorAll(".mi-chat__feedback-button");
  up.events.click();
  await flushFeedback();
  down.events.click();
  up.events.click();
  assert.equal(widget.calls.length, 1);
});


// Opt-in real browser proof, also usable against the host asset through
// MILICA_WIDGET_ASSET and --test-name-pattern="real DOM" (other tests cover
// engine-specific capture/disclosure markup). Only local HTML and fake transport are used.
test("real DOM clicks can change a rating while disabled controls prevent duplicate requests", {
  skip: !process.env.MILICA_CHROME_BINARY
}, () => {
  const { spawnSync } = require("node:child_process");
  const os = require("node:os");
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "milica-feedback-dom-"));
  const functions = source.slice(source.indexOf("  function validFeedback(feedback) {"), source.indexOf("  // A timeout only bounds"));
  const script = `
    const FEEDBACK = {}, ICON_THUMBS_UP = "", ICON_THUMBS_DOWN = "", ICON_SEND = "", FEEDBACK_TIMEOUT_MS = 1000;
    function el(tag, className, attrs = {}) {
      const node = document.createElement(tag); node.className = className;
      Object.entries(attrs).forEach(([key, value]) => node.setAttribute(key, value)); return node;
    }
    function svg() { return document.createElement("span"); }
    function scrollToEnd() {}
    function csrfToken() { return "synthetic-csrf"; }
    const requests = [], pending = [];
    function timedFetch(url, options, timeout, transform) {
      requests.push(JSON.parse(options.body));
      return new Promise(resolve => pending.push(resolve)).then(code => transform({
        status: code, ok: code === 200, json: () => Promise.resolve({status: "ok"})
      }));
    }
    ${functions}
    function check(ok, message) { if (!ok) throw new Error(message); }
    async function settle(code) { pending.shift()(code); await new Promise(resolve => setTimeout(resolve, 0)); }
    (async function () {
      const row = document.createElement("div"); document.body.appendChild(row);
      addFeedback(row, {id: "reply-id", token: "signed-token", url: "/synthetic-feedback"}, true);
      const [up, down, share] = row.querySelectorAll("button");
      const captureCount = share ? 1 : 0;
      if (share) {
        share.click(); up.click(); check(requests.length === 1, "busy capture allowed duplicate");
        await settle(200);
        check(!up.disabled && !down.disabled && share.disabled, "share did not leave thumbs available");
      }
      up.click(); down.click(); up.click(); check(requests.length === captureCount + 1, "busy rating allowed duplicate");
      await settle(200);
      check(up.disabled && !down.disabled && (!share || share.disabled), "other thumb not enabled");
      down.click(); await settle(200);
      check(!up.disabled && down.disabled && (!share || share.disabled), "reverse thumb not enabled");
      check(up.getAttribute("aria-pressed") === "false" && down.getAttribute("aria-pressed") === "true", "selection not updated");
      check(requests.every(r => r.reply_id === "reply-id" && r.token === "signed-token"), "changed reply or token");
      check(requests.map(r => r.value).join(",") === (share ? "share_question," : "") + "helpful,not_helpful", "incorrect requests");
      up.click(); await settle(500);
      check(!up.disabled && !down.disabled, "transient failure prevented retry");
      up.click(); await settle(422);
      check(up.disabled && down.disabled && (!share || share.disabled), "expired controls stayed active");
      down.click(); check(requests.length === captureCount + 4, "expired token retried");
      document.body.setAttribute("data-feedback-result", "passed");
    })().catch(error => { document.body.setAttribute("data-feedback-result", "failed"); document.body.textContent = error.message; });
  `;
  try {
    const html = path.join(directory, "feedback.html");
    fs.writeFileSync(html, "<!doctype html><body><script>" + script + "</script></body>");
    const result = spawnSync(process.env.MILICA_CHROME_BINARY, [
      "--headless", "--no-sandbox", "--disable-gpu", "--disable-background-networking", "--no-first-run",
      "--user-data-dir=" + path.join(directory, "profile"), "--virtual-time-budget=3000", "--dump-dom", "file://" + html
    ], { encoding: "utf8", timeout: 20000 });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /<body data-feedback-result="passed">/, result.stdout);
  } finally {
    fs.rmSync(directory, {recursive: true, force: true});
  }
});
