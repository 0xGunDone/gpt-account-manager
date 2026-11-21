const { chromium } = require("playwright-core");
const { generateTOTP } = require("./totp");

const productionOrigins = new Set([
  "https://chatgpt.com",
  "https://auth.openai.com",
]);

class BrowserFlowError extends Error {}
class HumanChallengeError extends BrowserFlowError {}
class ManualRecoveryError extends BrowserFlowError {
  constructor(stage) {
    super("Continue 2FA recovery in the original authenticated app session");
    this.code = "manual_recovery_required";
    this.stage = stage;
  }
}

const safeBrowserDiagnostics = new Set([
  "Authenticated subscription data is unavailable",
  "Authenticator code field is ambiguous",
  "Authenticator confirmation is unavailable",
  "Authenticator control is unavailable",
  "Authenticator dialog is ambiguous",
  "Authenticator is already enabled",
  "Authenticator removal dialog is unavailable",
  "Authenticator setup dialog is unavailable",
  "Authenticator state did not change",
  "Authenticator state is unavailable",
  "Automatic login timed out",
  "OpenAI login callback failed",
  "Browser control is ambiguous",
  "Browser field is ambiguous",
  "Clean login did not prove the pending authenticator",
  "New authenticator secret is unavailable",
  "Pending authenticator secret is missing",
  "Signed-in account does not match selected account",
  "Unexpected browser origin",
]);

function safeFailureMessage(error) {
  if (error instanceof BrowserFlowError && safeBrowserDiagnostics.has(error.message)) {
    return error.message;
  }
  return "External Chrome automation failed";
}

async function launchFreshChrome({ headless = false } = {}) {
  const browser = await chromium.launch({ channel: "chrome", headless });
  const context = await browser.newContext();
  const page = await context.newPage();
  return {
    browser,
    context,
    page,
    close: async () => {
      await context.close().catch(() => {});
      await browser.close().catch(() => {});
    },
  };
}

function allowedOriginSet(extraOrigins = []) {
  return new Set([...productionOrigins, ...extraOrigins]);
}

function ensureAllowedURL(urlString, extraOrigins = []) {
  const url = new URL(urlString);
  if (!allowedOriginSet(extraOrigins).has(url.origin)) {
    throw new BrowserFlowError("Unexpected browser origin");
  }
}

async function uniqueVisible(page, selectors) {
  for (const selector of selectors) {
    const matches = [];
    for (const frame of page.frames()) {
      const locator = frame.locator(selector);
      for (let index = 0; index < await locator.count(); index += 1) {
        const candidate = locator.nth(index);
        if (await candidate.isVisible().catch(() => false)) matches.push({ frame, locator: candidate });
      }
    }
    if (matches.length > 1) throw new BrowserFlowError("Browser field is ambiguous");
    if (matches.length === 1) return matches[0];
  }
  return null;
}

async function preferredVisibleButton(page, names) {
  const visible = [];
  for (const frame of page.frames()) {
    const locator = frame.getByRole("button", { name: names, exact: true });
    for (let index = 0; index < await locator.count(); index += 1) {
      const candidate = locator.nth(index);
      if (await candidate.isVisible().catch(() => false)) visible.push(candidate);
    }
  }
  return visible.at(-1) ?? null;
}

async function submitField(page, field, value) {
  await field.locator.fill(value);
  const submit = await uniqueButtonInFrame(
    field.frame,
    /^(continue|продолжить|confirm|подтвердить)$/i,
  );
  if (submit) await submit.click();
  else await field.locator.press("Enter");
}

async function uniqueButtonInFrame(frame, names) {
  const locator = frame.getByRole("button", { name: names, exact: true });
  const visible = [];
  for (let index = 0; index < await locator.count(); index += 1) {
    const candidate = locator.nth(index);
    if (await candidate.isVisible().catch(() => false)) visible.push(candidate);
  }
  if (visible.length > 1) throw new BrowserFlowError("Browser control is ambiguous");
  return visible[0] ?? null;
}

async function readSession(page) {
  return page.evaluate(async () => {
    try {
      const response = await fetch("/api/auth/session", { credentials: "include" });
      if (!response.ok) return null;
      const session = await response.json();
      return session?.user?.email ? session : null;
    } catch {
      return null;
    }
  }).catch(() => null);
}

async function hasHumanChallenge(page) {
  for (const frame of page.frames()) {
    const text = await frame.locator("body").innerText().catch(() => "");
    if (/verify (you are|that you are) human|captcha|провер.{0,12}что вы человек/i.test(text)) {
      return true;
    }
  }
  return false;
}

async function signIn(page, account, secret, options = {}) {
  const homeURL = options.homeURL ?? "https://chatgpt.com/";
  const extraOrigins = options.allowedOrigins ?? [];
  await page.goto(homeURL, { waitUntil: "domcontentloaded" });
  ensureAllowedURL(page.url(), extraOrigins);

  let passwordSubmitted = false;
  let otpSubmitted = false;
  const deadline = Date.now() + (options.timeoutMs ?? 60_000);
  while (Date.now() < deadline) {
    ensureAllowedURL(page.url(), extraOrigins);
    if (new URL(page.url()).pathname.toLowerCase() === "/auth/error") {
      throw new BrowserFlowError("OpenAI login callback failed");
    }
    const session = await readSession(page);
    if (session?.user?.email) {
      if (session.user.email.toLowerCase() !== account.email.toLowerCase()) {
        throw new BrowserFlowError("Signed-in account does not match selected account");
      }
      return {
        signedInEmail: session.user.email,
        proof: {
          passwordSubmitted,
          pendingOTPSubmitted: otpSubmitted,
          authenticatedImmediatelyAfterPendingOTP: otpSubmitted,
        },
      };
    }
    if (await hasHumanChallenge(page)) throw new HumanChallengeError("Human verification required");

    const email = await uniqueVisible(page, ["input[type='email']", "input[name='username']"]);
    if (email) {
      await submitField(page, email, account.email);
      await page.waitForTimeout(150);
      continue;
    }

    const password = await uniqueVisible(page, ["input[type='password']"]);
    if (password) {
      await submitField(page, password, account.password);
      passwordSubmitted = true;
      await page.waitForTimeout(150);
      continue;
    }

    const otpSelectors = [
      "input[autocomplete='one-time-code']",
      "input[name*='otp' i]",
      "input[name='code']",
      "input[id='code']",
      "input[inputmode='numeric']",
    ];
    if (/\/mfa-challenge\//i.test(new URL(page.url()).pathname)) {
      otpSelectors.push("input:not([type='hidden'])");
    }
    const otp = await uniqueVisible(page, otpSelectors);
    if (otp) {
      await submitField(page, otp, generateTOTP(secret));
      otpSubmitted = true;
      await page.waitForTimeout(150);
      continue;
    }

    const login = await preferredVisibleButton(page, /^(log in|войти)$/i);
    if (login) {
      await login.click();
      await page.waitForTimeout(150);
      continue;
    }
    await page.waitForTimeout(150);
  }
  throw new BrowserFlowError("Automatic login timed out");
}

async function checkSubscription(page, options = {}) {
  const details = await page.evaluate(async () => {
    const response = await fetch("/api/auth/session", { credentials: "include" });
    if (!response.ok) return null;
    const session = await response.json();
    const email = session?.user?.email;
    if (!email) return null;
    let auth = {};
    const token = session?.accessToken;
    if (token) {
      try {
        const part = token.split(".")[1];
        const padded = part.replace(/-/g, "+").replace(/_/g, "/")
          + "=".repeat((4 - part.length % 4) % 4);
        auth = JSON.parse(atob(padded))["https://api.openai.com/auth"] || {};
      } catch {}
    }
    const accountID = auth.chatgpt_account_id || session?.account?.id
      || session?.user?.account_id || null;
    let subscription = null;
    if (accountID) {
      const subscriptionResponse = await fetch(
        `/backend-api/subscriptions?account_id=${encodeURIComponent(accountID)}`,
        { credentials: "include", headers: token ? { Authorization: `Bearer ${token}` } : {} },
      );
      if (subscriptionResponse.ok) {
        const payload = await subscriptionResponse.json();
        subscription = Array.isArray(payload)
          ? payload.find((item) => String(item?.account_id || item?.accountId || "") === String(accountID))
          : (payload?.subscription || payload);
      }
    }
    return {
      signedInEmail: email,
      planLabel: subscription?.plan_type || auth.chatgpt_plan_type
        || session?.account?.planType || "unknown",
      activeUntil: subscription?.active_until || null,
      willRenew: typeof subscription?.will_renew === "boolean" ? subscription.will_renew : null,
    };
  });
  if (!details) throw new BrowserFlowError("Authenticated subscription data is unavailable");

  let activeUntilText = null;
  let locale = null;
  if (!details.activeUntil) {
    const pricingURL = options.pricingURL ?? "https://chatgpt.com/#pricing";
    await page.goto(pricingURL, { waitUntil: "domcontentloaded" });
    const pricing = await page.evaluate(() => {
      const normalize = (value) => String(value || "").replace(/\s+/g, " ").trim().toLowerCase();
      const visible = (element) => element.getClientRects().length > 0
        && getComputedStyle(element).display !== "none"
        && getComputedStyle(element).visibility !== "hidden";
      const controls = [...document.querySelectorAll("button,[role='button']")]
        .filter(visible)
        .filter((element) => ["your current plan", "ваш текущий план"]
          .includes(normalize(element.innerText || element.getAttribute("aria-label"))));
      if (controls.length !== 1) return null;
      const pattern = /^(?:до|until|through|expires(?:\s+on)?|renews(?:\s+on)?)\s+.*\d{4}\s*(?:г\.?)?$/iu;
      for (let scope = controls[0].parentElement; scope && scope !== document.body; scope = scope.parentElement) {
        const candidates = [...scope.querySelectorAll("*")]
          .filter(visible)
          .map((element) => element.textContent.replace(/\s+/g, " ").trim())
          .filter((text) => pattern.test(text));
        const unique = [...new Set(candidates)];
        if (unique.length === 1) {
          return { activeUntilText: unique[0], locale: document.documentElement.lang || "en-US" };
        }
        if (unique.length > 1) return null;
      }
      return null;
    });
    activeUntilText = pricing?.activeUntilText ?? null;
    locale = pricing?.locale ?? null;
  }
  return {
    ...details,
    activeUntilText,
    locale,
  };
}

async function authenticatorSwitch(page) {
  const matches = [];
  for (const frame of page.frames()) {
    const locator = frame.getByRole("switch", {
      name: /^(authenticator app|приложение-аутентификатор|приложение для аутентификации)$/i,
      exact: true,
    });
    for (let index = 0; index < await locator.count(); index += 1) {
      const candidate = locator.nth(index);
      if (await candidate.isVisible().catch(() => false)) matches.push(candidate);
    }
  }
  if (matches.length !== 1) throw new BrowserFlowError("Authenticator control is unavailable");
  const state = await matches[0].getAttribute("aria-checked");
  if (state !== "true" && state !== "false") {
    throw new BrowserFlowError("Authenticator state is unavailable");
  }
  return { locator: matches[0], enabled: state === "true" };
}

async function visibleDialog(page, headingPattern, frames = page.frames()) {
  const matches = [];
  for (const frame of frames) {
    const dialogs = frame.getByRole("dialog");
    for (let index = 0; index < await dialogs.count(); index += 1) {
      const candidate = dialogs.nth(index);
      if (!await candidate.isVisible().catch(() => false)) continue;
      const text = await candidate.innerText().catch(() => "");
      if (headingPattern.test(text)) matches.push(candidate);
    }
  }
  if (matches.length > 1) throw new BrowserFlowError("Authenticator dialog is ambiguous");
  return matches[0] ?? null;
}

async function waitForAuthenticatorState(page, expected, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const control = await authenticatorSwitch(page).catch(() => null);
    if (control?.enabled === expected) return control;
    await page.waitForTimeout(150);
  }
  throw new BrowserFlowError("Authenticator state did not change");
}

async function optionalBackupPrompt(page, securityURL) {
  const location = new URL(page.url());
  const expected = new URL(securityURL);
  if (location.origin !== expected.origin || !(
    (location.pathname === expected.pathname && location.hash.toLowerCase() === expected.hash.toLowerCase())
    || (expected.origin === "https://chatgpt.com" && location.pathname === "/settings/security")
  )) return null;

  const headings = page.mainFrame().getByRole("heading", {
    name: /^(authenticator app added|приложение[- ]аутентификатор добавлено|приложение для аутентификации добавлено)$/i,
    exact: true,
  });
  const visible = [];
  for (let index = 0; index < await headings.count(); index += 1) {
    const heading = headings.nth(index);
    if (await heading.isVisible().catch(() => false)) visible.push(heading);
  }
  if (visible.length > 1) throw new BrowserFlowError("Authenticator dialog is ambiguous");
  if (!visible.length) return null;

  let container = visible[0].locator("xpath=..");
  for (let depth = 0; depth < 12; depth += 1) {
    const tag = await container.evaluate((element) => element.tagName);
    if (tag === "HTML" || (tag === "BODY" && depth > 0)) break;
    const text = await container.innerText();
    if (/(?:text messages|sms|смс|текстов.{0,16}сообщени)/i.test(text)
      && /(?:backup (?:mfa|authentication) method|резервн.{0,40}(?:способ|метод).{0,40}(?:mfa|аутентификаци))/i.test(text)
      && await container.getByRole("button", { name: /^(not now|не сейчас)$/i, exact: true }).count()) {
      return container;
    }
    container = container.locator("xpath=..");
  }
  return null;
}

async function confirmAuthenticatorSetup(page, securityURL) {
  const deadline = Date.now() + 15_000;
  let enabledSince = null;
  let dismissed = false;
  while (Date.now() < deadline) {
    const prompt = await optionalBackupPrompt(page, securityURL);
    if (prompt) {
      if (!dismissed) {
        const button = await uniqueButtonInFrame(prompt, /^(not now|не сейчас)$/i);
        if (!button || !await button.isEnabled()) {
          throw new BrowserFlowError("Authenticator confirmation is unavailable");
        }
        await button.click();
        dismissed = true;
      }
    } else {
      const control = await authenticatorSwitch(page).catch(() => null);
      if (control?.enabled) {
        enabledSince ??= Date.now();
        // Allow the optional follow-up to render after the switch changes.
        if (dismissed || Date.now() - enabledSince >= 1_500) return;
      } else {
        enabledSince = null;
      }
    }
    await page.waitForTimeout(150);
  }
  throw new BrowserFlowError("Authenticator state did not change");
}

async function submitDialogOTP(dialog, secret, buttonPattern) {
  const fields = dialog.locator([
    "input[autocomplete='one-time-code']",
    "input[name*='otp' i]",
    "input[name='code']",
    "input[id='code']",
    "input[inputmode='numeric']",
  ].join(","));
  const visibleFields = [];
  for (let index = 0; index < await fields.count(); index += 1) {
    const candidate = fields.nth(index);
    if (await candidate.isVisible().catch(() => false)) visibleFields.push(candidate);
  }
  if (visibleFields.length > 1) throw new BrowserFlowError("Authenticator code field is ambiguous");
  if (visibleFields.length === 1) await visibleFields[0].fill(generateTOTP(secret));

  const buttons = dialog.getByRole("button", { name: buttonPattern, exact: true });
  const visibleButtons = [];
  for (let index = 0; index < await buttons.count(); index += 1) {
    const candidate = buttons.nth(index);
    if (await candidate.isVisible().catch(() => false)) visibleButtons.push(candidate);
  }
  if (visibleButtons.length !== 1) throw new BrowserFlowError("Authenticator confirmation is unavailable");
  await visibleButtons[0].click();
}

async function removeAuthenticator(page, request, checkpoint, emitCheckpoint, securityURL) {
  const control = await authenticatorSwitch(page);
  if (control.enabled) {
    if (emitCheckpoint) await checkpoint({ checkpoint: "removalStarted" });
    await control.locator.click();
    const location = new URL(page.url());
    const expected = new URL(securityURL);
    const isSecurityPage = location.origin === expected.origin && (
      (location.pathname === expected.pathname && location.hash.toLowerCase() === expected.hash.toLowerCase())
      || (expected.origin === "https://chatgpt.com" && location.pathname === "/settings/security")
    );
    const query = location.searchParams;
    const uniqueValue = (key) => query.getAll(key).length === 1 ? query.get(key) : null;
    const isTOTPRemoval = isSecurityPage && uniqueValue("action") === "disable"
      && uniqueValue("factor") === "totp" && Boolean(uniqueValue("factor_id"));
    const dialog = await visibleDialog(
      page,
      isTOTPRemoval
        ? /remove authenticator app|удалить приложение для аутентификации|remove authentication method\?|удалить способ аутентификации\?/i
        : /remove authenticator app|удалить приложение для аутентификации/i,
      isTOTPRemoval ? [page.mainFrame()] : page.frames(),
    );
    if (!dialog) throw new BrowserFlowError("Authenticator removal dialog is unavailable");
    await submitDialogOTP(
      dialog,
      request.currentSecret,
      /^(remove|delete|удалить|continue|продолжить|confirm|подтвердить)$/i,
    );
    await waitForAuthenticatorState(page, false);
  }
  if (emitCheckpoint) await checkpoint({ checkpoint: "oldMethodDisabled" });
}

async function revealAuthenticatorSecret(dialog) {
  const reveal = dialog.getByRole("button", {
    name: /^(problems scanning\?|проблемы со сканированием\?)$/i,
    exact: true,
  });
  const revealCount = await reveal.count();
  if (revealCount === 1 && await reveal.isVisible().catch(() => false)) await reveal.click();
  const candidates = new Set();
  const controls = dialog.locator("code, pre, input[readonly], [data-secret]");
  for (let index = 0; index < await controls.count(); index += 1) {
    const candidate = controls.nth(index);
    if (!await candidate.isVisible().catch(() => false)) continue;
    const raw = await candidate.inputValue().catch(async () => candidate.innerText().catch(() => ""));
    for (const match of String(raw).toUpperCase().matchAll(/\b[A-Z2-7]{16,}\b/g)) {
      candidates.add(match[0]);
    }
  }
  if (candidates.size === 0) {
    const text = await dialog.innerText();
    for (const match of text.toUpperCase().matchAll(/\b[A-Z2-7]{16,}\b/g)) {
      candidates.add(match[0]);
    }
  }
  if (candidates.size !== 1) throw new BrowserFlowError("New authenticator secret is unavailable");
  return [...candidates][0];
}

async function setupAuthenticator(page, checkpoint, securityURL) {
  const control = await authenticatorSwitch(page);
  if (control.enabled) throw new BrowserFlowError("Authenticator is already enabled");
  await control.locator.click();
  const dialog = await visibleDialog(
    page,
    /connect your authenticator app|подключите приложение для аутентификации/i,
  );
  if (!dialog) throw new BrowserFlowError("Authenticator setup dialog is unavailable");
  const secret = await revealAuthenticatorSecret(dialog);
  await checkpoint({ checkpoint: "secretCaptured", secret });
  await submitDialogOTP(
    dialog,
    secret,
    /^(continue|продолжить|confirm|подтвердить|verify|проверить)$/i,
  );
  await confirmAuthenticatorSetup(page, securityURL);
  await checkpoint({ checkpoint: "setupConfirmed" });
  return secret;
}

async function cleanLogin(request, secret, options) {
  const launchBrowser = options.launchBrowser ?? launchFreshChrome;
  const runtime = await launchBrowser({ headless: options.headless ?? false });
  try {
    const result = await signIn(runtime.page, request, secret, options);
    if (!result.proof.passwordSubmitted
      || !result.proof.pendingOTPSubmitted
      || !result.proof.authenticatedImmediatelyAfterPendingOTP) {
      throw new BrowserFlowError("Clean login did not prove the pending authenticator");
    }
    const subscription = await checkSubscription(runtime.page, options);
    return {
      ...subscription,
      proof: result.proof,
    };
  } finally {
    await runtime.close();
  }
}

async function rotateAuthenticator(request, checkpoint, options = {}) {
  if (["removingOldMethod", "oldMethodDisabled"].includes(request.rotationStage)) {
    throw new ManualRecoveryError(request.rotationStage);
  }
  if (request.rotationStage === "awaitingCleanLogin") {
    if (!request.pendingSecret) throw new BrowserFlowError("Pending authenticator secret is missing");
    return cleanLogin(request, request.pendingSecret, options);
  }

  let pendingSecret = request.pendingSecret;
  const launchBrowser = options.launchBrowser ?? launchFreshChrome;
  const runtime = await launchBrowser({ headless: options.headless ?? false });
  try {
    const loginSecret = request.rotationStage === "pendingSecretCaptured" && pendingSecret
      ? pendingSecret
      : request.currentSecret;
    await signIn(runtime.page, request, loginSecret, options);
    const securityURL = options.securityURL ?? "https://chatgpt.com/#settings/Security";
    await runtime.page.goto(securityURL, { waitUntil: "domcontentloaded" });
    ensureAllowedURL(runtime.page.url(), options.allowedOrigins ?? []);

    const resumingSetup = request.rotationStage === "pendingSecretCaptured";
    const state = await authenticatorSwitch(runtime.page).catch((error) => {
      if (resumingSetup) return null;
      throw error;
    });
    if (resumingSetup && state?.enabled !== false) {
      await confirmAuthenticatorSetup(runtime.page, securityURL);
      await checkpoint({ checkpoint: "setupConfirmed" });
    } else {
      await removeAuthenticator(
        runtime.page,
        request,
        checkpoint,
        request.rotationStage == null,
        securityURL,
      );
      pendingSecret = await setupAuthenticator(runtime.page, checkpoint, securityURL);
    }
  } finally {
    await runtime.close();
  }

  if (!pendingSecret) throw new BrowserFlowError("Pending authenticator secret is missing");
  return cleanLogin(request, pendingSecret, options);
}

module.exports = {
  BrowserFlowError,
  HumanChallengeError,
  ManualRecoveryError,
  checkSubscription,
  ensureAllowedURL,
  launchFreshChrome,
  rotateAuthenticator,
  safeFailureMessage,
  signIn,
};
