const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const http = require("node:http");
const { once } = require("node:events");
const path = require("node:path");
const test = require("node:test");

const {
  BrowserFlowError,
  checkSubscription,
  launchFreshChrome,
  rotateAuthenticator,
  safeFailureMessage,
  signIn,
} = require("../src/openai-flow");
const { generateTOTP } = require("../src/totp");

function startFixture({ activeUntil = "2026-09-30T00:00:00Z", requireBearer = false } = {}) {
  let authenticated = false;
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    if (url.pathname === "/") {
      response.setHeader("content-type", "text/html; charset=utf-8");
      response.end(authenticated ? `
        <html lang="en-US"><body>
          <section>
            <span>until Sep 30, 2026</span>
            <button>Your current plan</button>
          </section>
        </body></html>
      ` : `
        <button class="login" onclick="location.href='/email'">Log in</button>
        <button class="login" onclick="location.href='/email'">Log in</button>
      `);
      return;
    }
    if (url.pathname === "/email") {
      response.setHeader("content-type", "text/html; charset=utf-8");
      response.end(`
        <button type="button">Log in</button>
        <button type="button">Log in</button>
        <form action="/password">
          <input type="email" name="username">
          <button type="submit">Continue</button>
        </form>
      `);
      return;
    }
    if (url.pathname === "/password") {
      response.setHeader("content-type", "text/html; charset=utf-8");
      response.end(`
        <form action="/mfa-challenge/test">
          <input type="password">
          <button type="submit">Continue</button>
        </form>
      `);
      return;
    }
    if (url.pathname === "/mfa-challenge/test") {
      response.setHeader("content-type", "text/html; charset=utf-8");
      response.end(`
        <iframe title="MFA" src="/mfa-frame"></iframe>
      `);
      return;
    }
    if (url.pathname === "/mfa-frame") {
      response.setHeader("content-type", "text/html; charset=utf-8");
      response.end(`
        <form action="/authenticated">
          <label>One-time code<input name="code" inputmode="numeric"></label>
          <button type="submit">Continue</button>
        </form>
      `);
      return;
    }
    if (url.pathname === "/authenticated") {
      authenticated = true;
      response.statusCode = 302;
      response.setHeader("location", "/");
      response.end();
      return;
    }
    if (url.pathname === "/api/auth/session") {
      response.setHeader("content-type", "application/json");
      response.end(authenticated
        ? JSON.stringify({ user: { email: "user@example.com" }, accessToken: "fixture-access-token",
          account: { id: "acc-1", planType: "plus" } })
        : "{}");
      return;
    }
    if (url.pathname === "/backend-api/subscriptions") {
      response.setHeader("content-type", "application/json");
      if (requireBearer && request.headers.authorization !== "Bearer fixture-access-token") {
        response.writeHead(401);
        response.end(JSON.stringify({ detail: "Not authenticated" }));
        return;
      }
      response.end(JSON.stringify({
        account_id: "acc-1",
        plan_type: "plus",
        active_until: activeUntil,
        will_renew: true,
      }));
      return;
    }
    response.statusCode = 404;
    response.end("not found");
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      resolve({
        baseURL: `http://127.0.0.1:${address.port}`,
        close: () => new Promise((done) => server.close(done)),
      });
    });
  });
}

test("generates the RFC 6238 SHA-1 vector", () => {
  assert.equal(generateTOTP("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", 59), "287082");
});

test("exposes only allow-listed browser diagnostics", () => {
  assert.equal(
    safeFailureMessage(new BrowserFlowError("Automatic login timed out")),
    "Automatic login timed out",
  );
  assert.equal(
    safeFailureMessage(new BrowserFlowError("private-password")),
    "External Chrome automation failed",
  );
  assert.equal(
    safeFailureMessage(new Error("private-password")),
    "External Chrome automation failed",
  );
});

test("fresh Chrome submits OTP inside a child frame and reads subscription", async () => {
  const fixture = await startFixture();
  const runtime = await launchFreshChrome({ headless: true });
  try {
    const proof = await signIn(runtime.page, {
      email: "user@example.com",
      password: "private-password",
    }, "JBSWY3DPEHPK3PXP", {
      homeURL: fixture.baseURL,
      allowedOrigins: [fixture.baseURL],
    });

    assert.equal(proof.signedInEmail, "user@example.com");
    assert.equal(proof.proof.passwordSubmitted, true);
    assert.equal(proof.proof.pendingOTPSubmitted, true);
    assert.equal(proof.proof.authenticatedImmediatelyAfterPendingOTP, true);

    const subscription = await checkSubscription(runtime.page, {
      homeURL: fixture.baseURL,
      pricingURL: `${fixture.baseURL}/#pricing`,
    });
    assert.deepEqual(subscription, {
      signedInEmail: "user@example.com",
      planLabel: "plus",
      activeUntil: "2026-09-30T00:00:00Z",
      activeUntilText: null,
      locale: null,
      willRenew: true,
    });
  } finally {
    await runtime.close();
    await fixture.close();
  }
});

test("worker dispatches a check request without echoing credentials", async () => {
  const fixture = await startFixture();
  const workerPath = path.join(__dirname, "..", "src", "worker.js");
  const child = spawn(process.execPath, [workerPath], {
    env: {
      ...process.env,
      GPTAM_HEADLESS: "1",
      GPTAM_HOME_URL: fixture.baseURL,
      GPTAM_ALLOWED_ORIGIN: fixture.baseURL,
      GPTAM_PRICING_URL: `${fixture.baseURL}/#pricing`,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const request = {
    operation: "check",
    email: "user@example.com",
    password: "private-password",
    currentSecret: "JBSWY3DPEHPK3PXP",
    pendingSecret: null,
    rotationStage: null,
  };
  child.stdin.end(`${JSON.stringify(request)}\n`);

  const [exitCode] = await once(child, "close");
  await fixture.close();

  assert.equal(exitCode, 0, stderr);
  const result = JSON.parse(stdout.trim());
  assert.equal(result.type, "result");
  assert.equal(result.status, "success");
  assert.equal(result.signedInEmail, "user@example.com");
  assert.equal(stdout.includes(request.password), false);
  assert.equal(stdout.includes(request.currentSecret), false);
});

test("subscription reads the exact date from the authenticated endpoint", async () => {
  const fixture = await startFixture({ requireBearer: true });
  const runtime = await launchFreshChrome({ headless: true });
  try {
    await runtime.page.goto(`${fixture.baseURL}/authenticated`);
    const subscription = await checkSubscription(runtime.page, { pricingURL: `${fixture.baseURL}/#pricing` });
    assert.equal(subscription.activeUntil, "2026-09-30T00:00:00Z");
    assert.equal(subscription.willRenew, true);
    assert.equal(subscription.activeUntilText, null);
  } finally {
    await runtime.close();
    await fixture.close();
  }
});

test("subscription falls back to the visible current-plan card date", async () => {
  const fixture = await startFixture({ activeUntil: null });
  const runtime = await launchFreshChrome({ headless: true });
  try {
    await signIn(runtime.page, {
      email: "user@example.com",
      password: "private-password",
    }, "JBSWY3DPEHPK3PXP", {
      homeURL: fixture.baseURL,
      allowedOrigins: [fixture.baseURL],
    });

    const subscription = await checkSubscription(runtime.page, {
      pricingURL: `${fixture.baseURL}/#pricing`,
    });

    assert.equal(subscription.activeUntil, null);
    assert.equal(subscription.activeUntilText, "until Sep 30, 2026");
    assert.equal(subscription.locale, "en-US");
  } finally {
    await runtime.close();
    await fixture.close();
  }
});

test("clean rotation returns subscription from its verified login", async () => {
  const fixture = await startFixture();
  try {
    const result = await rotateAuthenticator({
      email: "user@example.com",
      password: "private-password",
      currentSecret: "JBSWY3DPEHPK3PXP",
      pendingSecret: "KRUGS4ZANFZSAYJA",
      rotationStage: "awaitingCleanLogin",
    }, async () => {}, {
      headless: true,
      homeURL: fixture.baseURL,
      allowedOrigins: [fixture.baseURL],
      pricingURL: `${fixture.baseURL}/#pricing`,
    });

    assert.deepEqual(result, {
      signedInEmail: "user@example.com",
      planLabel: "plus",
      activeUntil: "2026-09-30T00:00:00Z",
      activeUntilText: null,
      locale: null,
      willRenew: true,
      proof: {
        passwordSubmitted: true,
        pendingOTPSubmitted: true,
        authenticatedImmediatelyAfterPendingOTP: true,
      },
    });
  } finally {
    await fixture.close();
  }
});

test("authentication callback errors stop login before the full timeout", async () => {
  const fixture = await startFixture();
  const runtime = await launchFreshChrome({ headless: true });
  try {
    await assert.rejects(
      signIn(runtime.page, {
        email: "user@example.com",
        password: "private-password",
      }, "JBSWY3DPEHPK3PXP", {
        homeURL: `${fixture.baseURL}/auth/error?error=undefined`,
        allowedOrigins: [fixture.baseURL],
        timeoutMs: 100,
      }),
      (error) => error instanceof BrowserFlowError
        && error.message === "OpenAI login callback failed",
    );
  } finally {
    await runtime.close();
    await fixture.close();
  }
});
