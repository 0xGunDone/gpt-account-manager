const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const resources = path.join(__dirname, "../Resources");
const home = "https://chatgpt.com/";
const security = "https://chatgpt.com/settings/security";
const login = "https://chatgpt.com/auth/login";
const email = "selected@example.test";
const requestId = "12345678-1234-1234-1234-123456789ABC";

function request(issuedAt = Date.now() / 1000) {
  return {
    name: "openPasskeySettings",
    userInfo: { email, issuedAt, requestId },
  };
}

function startup({ hostAccess = true, sessionEmail = email, securityEmail = sessionEmail, accepted = true,
  documentChangedAt, redirectAt, privateWindow = false, movedTab = false } = {}) {
  let listener;
  const steps = [];
  const location = { href: home };
  const window = {};
  window.top = window;
  const tab = () => ({ id: 20, windowId: 10, incognito: privateWindow, active: true,
    status: "complete", url: location.href });
  const browser = {
    runtime: {
      connectNative(id) {
        assert.equal(id, "local.wemakecode.gptaccountmanager");
        steps.push("connect");
        return { onMessage: { addListener(handle) { listener = handle; } } };
      },
      async sendNativeMessage(id, message) {
        assert.equal(id, "local.wemakecode.gptaccountmanager");
        assert.deepEqual({ ...message }, { type: "claim", requestId });
        steps.push("claim");
        return { accepted };
      },
    },
    permissions: { async contains({ origins }) {
      assert.equal(origins.join(), "https://chatgpt.com/*");
      return hostAccess;
    } },
    windows: {
      async create({ incognito, focused, url }) {
        assert.equal(url, home);
        assert.equal(incognito, false);
        assert.equal(focused, false);
        steps.push("open");
        return { id: 10, incognito: privateWindow, tabs: [tab()] };
      },
      async update(id, { focused }) {
        assert.equal(id, 10);
        assert.equal(focused, true);
        steps.push("focus");
      },
    },
    tabs: {
      async get(id) {
        assert.equal(id, 20);
        return movedTab ? { ...tab(), windowId: 30 } : tab();
      },
      async update(id, { url }) {
        assert.equal(id, 20);
        assert.ok(url === login || url === security);
        steps.push(url);
        location.href = url === redirectAt ? "https://example.test/" : url;
      },
      async remove(id) { assert.equal(id, 20); steps.push("close"); },
    },
    scripting: {
      async executeScript({ target, func, args, world }) {
        assert.equal(target.tabId, 20);
        assert.equal(world, "ISOLATED");
        const documentId = `document ${location.href}`;
        if (target.documentIds) {
          assert.equal(target.documentIds.join(), documentId);
          if (location.href === documentChangedAt) return [];
        } else {
          assert.equal(target.frameIds.join(), "0");
        }
        if (args.length === 1) steps.push(documentId);
        return [{ frameId: 0, documentId, result: await func(...args) }];
      },
    },
    browserAction: {
      async setTitle({ title }) { steps.push(title); },
      async setBadgeText({ text }) { steps.push(`badge ${text}`); },
    },
  };
  vm.runInNewContext(fs.readFileSync(path.join(resources, "background.js"), "utf8"), {
    browser, window, location, AbortSignal, setTimeout,
    async fetch(url, settings) {
      assert.equal(url, "https://chatgpt.com/api/auth/session");
      assert.equal(settings.credentials, "include");
      assert.equal(settings.redirect, "error");
      assert.equal(settings.mode, "same-origin");
      assert.equal(settings.cache, "no-store");
      steps.push(`verify ${location.href}`);
      const actualEmail = location.href === home ? sessionEmail : securityEmail;
      return { status: 200, ok: true, async json() { return { user: { email: actualEmail } }; } };
    },
  });
  return { send: listener, steps };
}

test("native port verifies the account and document on both pages before focusing the ordinary window", async () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(resources, "manifest.json"), "utf8"));
  assert.equal(manifest.manifest_version, 2);
  assert.equal(manifest.background.persistent, true);
  assert.deepEqual(manifest.permissions, ["nativeMessaging", "scripting", "https://chatgpt.com/*"]);
  const { send, steps } = startup();
  const message = request();
  await Promise.all([send(message), send(message)]);
  await send(message);
  assert.deepEqual(steps, [
    "connect", "claim", "open", `verify ${home}`, `document ${home}`, security,
    `verify ${security}`, `document ${security}`, "focus",
    "Настройки безопасности ChatGPT открыты в обычном окне Safari.", "badge ",
  ]);
});

test("stale, unauthorized and duplicate native requests do not open a window", async () => {
  const stale = startup();
  await stale.send(request(Date.now() / 1000 - 60));
  assert.equal(stale.steps.includes("open"), false);
  assert.equal(stale.steps.includes("claim"), false);

  const unauthorized = startup({ hostAccess: false });
  await unauthorized.send(request());
  assert.equal(unauthorized.steps.includes("open"), false);
  assert.equal(unauthorized.steps.includes("claim"), false);
  assert.equal(unauthorized.steps.at(-1), "badge !");

  const otherProfile = startup({ accepted: false });
  await otherProfile.send(request());
  assert.deepEqual(otherProfile.steps, ["connect", "claim"]);
});

test("missing Safari session opens the fixed login page for manual sign-in", async () => {
  const { send, steps } = startup({ sessionEmail: null });
  await send(request());
  assert.deepEqual(steps, [
    "connect", "claim", "open", `verify ${home}`, `document ${home}`, login, `document ${login}`, "focus",
    "Войдите в ChatGPT в Safari под выбранным аккаунтом и повторите в GPT Account Manager.", "badge !",
  ]);
});

test("wrong account closes the created tab without focusing settings or login", async () => {
  const { send, steps } = startup({ sessionEmail: "other@example.test" });
  await send(request());
  assert.deepEqual(steps, [
    "connect", "claim", "open", `verify ${home}`, `document ${home}`, "close",
    "В Safari открыт другой аккаунт ChatGPT. Переключитесь на выбранный аккаунт и повторите.", "badge !",
  ]);
});

test("changed account, target or document stops navigation or focus", async () => {
  for (const failure of [
    { securityEmail: "other@example.test" },
    { movedTab: true },
    { documentChangedAt: home },
    { documentChangedAt: security },
    { sessionEmail: null, documentChangedAt: home },
    { sessionEmail: null, redirectAt: login },
    { redirectAt: security },
  ]) {
    const { send, steps } = startup(failure);
    await send(request());
    assert.equal(steps.includes("close"), true, JSON.stringify(failure));
    assert.equal(steps.includes("focus"), false, JSON.stringify(failure));
    if (failure.documentChangedAt === home || failure.movedTab) {
      assert.equal(steps.includes(login) || steps.includes(security), false);
    }
    assert.equal(steps.at(-1), "badge !");
  }

  const privateMode = startup({ privateWindow: true });
  await privateMode.send(request());
  assert.deepEqual(privateMode.steps.slice(0, 3), ["connect", "claim", "open"]);
  assert.equal(privateMode.steps.at(-1), "badge !");
  assert.equal(privateMode.steps.length, 5);
});
