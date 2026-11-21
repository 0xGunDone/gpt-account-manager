"use strict";

const homeURL = "https://chatgpt.com/";
const securityURL = "https://chatgpt.com/settings/security";
const loginURL = "https://chatgpt.com/auth/login";
const hostPermission = { origins: ["https://chatgpt.com/*"] };
const handoffLifetime = 45_000;
const nativeApp = "local.wemakecode.gptaccountmanager";

const statusText = {
  ready: "Настройки безопасности ChatGPT открыты в обычном окне Safari.",
  hostAccess: "Разрешите GPT Account Manager доступ к chatgpt.com в настройках Safari и повторите.",
  noSession: "Войдите в ChatGPT в Safari под выбранным аккаунтом и повторите в GPT Account Manager.",
  wrongAccount: "В Safari открыт другой аккаунт ChatGPT. Переключитесь на выбранный аккаунт и повторите.",
  expired: "Запрос на открытие настроек устарел. Повторите в GPT Account Manager.",
  unavailable: "Не удалось проверить вход в Safari. Повторите в GPT Account Manager.",
};

class HandoffError extends Error {}

function checkDeadline(deadline) {
  if (Date.now() >= deadline) throw new HandoffError("expired");
}

async function targetState(target, expectedURL, loading) {
  const tab = await browser.tabs.get(target.tabId);
  if (tab.id !== target.tabId || tab.incognito !== false || tab.windowId !== target.windowId ||
      (tab.url !== expectedURL && !(loading && (!tab.url || tab.url === "about:blank" || tab.url === homeURL)))) {
    throw new HandoffError("unavailable");
  }
  return tab.url === expectedURL && tab.status === "complete" && tab.active === true;
}

async function waitForTarget(target, expectedURL, deadline) {
  const loadDeadline = Math.min(deadline, Date.now() + 12_000);
  while (Date.now() < loadDeadline) {
    if (await targetState(target, expectedURL, true)) return;
    await new Promise(resolve => setTimeout(resolve, 125));
  }
  checkDeadline(deadline);
  throw new HandoffError("unavailable");
}

async function checkTarget(target, expectedURL, deadline) {
  if (!await targetState(target, expectedURL, false)) throw new HandoffError("unavailable");
  checkDeadline(deadline);
}

async function checkDocument(target, expectedURL, deadline, documentId) {
  const frame = documentId ? { documentIds: [documentId] } : { frameIds: [0] };
  const results = await browser.scripting.executeScript({
    target: { tabId: target.tabId, ...frame },
    world: "ISOLATED",
    args: [expectedURL],
    func: url => window === window.top && location.href === url,
  });
  const [proof] = results;
  if (results.length !== 1 || proof.frameId !== 0 || proof.error || !proof.documentId ||
      (documentId && proof.documentId !== documentId) || proof.result !== true) {
    throw new HandoffError("unavailable");
  }
  await checkTarget(target, expectedURL, deadline);
}

async function checkSession(target, expectedURL, email, deadline) {
  await checkTarget(target, expectedURL, deadline);
  const results = await browser.scripting.executeScript({
    target: { tabId: target.tabId, frameIds: [0] },
    world: "ISOLATED",
    args: [expectedURL, email],
    func: async (url, expectedEmail) => {
      if (window !== window.top || location.href !== url) return "unavailable";
      try {
        const response = await fetch("https://chatgpt.com/api/auth/session", {
          credentials: "include", cache: "no-store", redirect: "error", mode: "same-origin",
          signal: AbortSignal.timeout(5_000),
        });
        if (response.status === 401 || response.status === 403) return "noSession";
        if (!response.ok) return "unavailable";
        const actualEmail = (await response.json())?.user?.email;
        if (location.href !== url) return "unavailable";
        if (typeof actualEmail !== "string" || !actualEmail) return "noSession";
        return actualEmail.toLowerCase() === expectedEmail ? "ready" : "wrongAccount";
      } catch {
        return "unavailable";
      }
    },
  });
  const [proof] = results;
  if (results.length !== 1 || proof.frameId !== 0 || proof.error || !proof.documentId ||
      !["ready", "noSession", "wrongAccount"].includes(proof.result)) {
    throw new HandoffError("unavailable");
  }
  await checkDocument(target, expectedURL, deadline, proof.documentId);
  return proof.result;
}

async function openPasskeySettings(email, requestId, deadline) {
  if (!await browser.permissions.contains(hostPermission)) throw new HandoffError("hostAccess");
  checkDeadline(deadline);
  // Safari may dispatch the same request to more than one profile.
  const claim = await browser.runtime.sendNativeMessage(nativeApp, { type: "claim", requestId });
  if (claim?.accepted !== true) return;

  checkDeadline(deadline);
  const window = await browser.windows.create({ incognito: false, focused: false, url: homeURL });
  const tab = window?.tabs?.[0];
  if (window?.incognito !== false || window.tabs?.length !== 1 || tab?.incognito !== false ||
      !Number.isSafeInteger(window.id) || !Number.isSafeInteger(tab.id) || tab.windowId !== window.id) {
    throw new HandoffError("unavailable");
  }

  const target = { windowId: window.id, tabId: tab.id };
  try {
    await waitForTarget(target, homeURL, deadline);
    const session = await checkSession(target, homeURL, email, deadline);
    if (session === "wrongAccount") throw new HandoffError(session);
    const nextURL = session === "ready" ? securityURL : loginURL;
    await browser.tabs.update(target.tabId, { url: nextURL });
    await waitForTarget(target, nextURL, deadline);
    if (nextURL === securityURL) {
      const securitySession = await checkSession(target, securityURL, email, deadline);
      if (securitySession !== "ready") throw new HandoffError(securitySession);
    } else {
      await checkDocument(target, loginURL, deadline);
    }
    await browser.windows.update(target.windowId, { focused: true });
    return session;
  } catch (error) {
    await browser.tabs.remove(target.tabId).catch(() => {});
    throw error;
  }
}

async function showStatus(status) {
  const title = Object.hasOwn(statusText, status) ? statusText[status] : statusText.unavailable;
  await Promise.allSettled([
    browser.browserAction.setTitle({ title }),
    browser.browserAction.setBadgeText({ text: status === "ready" ? "" : "!" }),
  ]);
}

let opening = false;
let lastIssuedAt = 0;

const nativePort = browser.runtime.connectNative(nativeApp);
nativePort.onMessage.addListener(async message => {
  if (opening || message?.name !== "openPasskeySettings") return;
  const { email, issuedAt, requestId } = message.userInfo ?? {};
  if (!Number.isFinite(issuedAt) || issuedAt <= lastIssuedAt || issuedAt * 1000 > Date.now() + 1000 ||
      typeof requestId !== "string" || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/iu.test(requestId) ||
      typeof email !== "string" || !email.trim()) return;

  opening = true;
  lastIssuedAt = issuedAt;
  try {
    const deadline = issuedAt * 1000 + handoffLifetime;
    checkDeadline(deadline);
    const status = await openPasskeySettings(email.toLowerCase(), requestId, deadline);
    if (status) await showStatus(status);
  } catch (error) {
    await showStatus(error instanceof HandoffError ? error.message : "unavailable");
  } finally {
    opening = false;
  }
});
