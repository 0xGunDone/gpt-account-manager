const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const http = require("node:http");
const { once } = require("node:events");
const path = require("node:path");
const readline = require("node:readline");
const test = require("node:test");

const {
  ManualRecoveryError,
  rotateAuthenticator,
} = require("../src/openai-flow");
const { generateTOTP } = require("../src/totp");

const oldSecret = "JBSWY3DPEHPK3PXP";
const newSecret = "KRUGS4ZANFZSAYJA";

function cookieValue(request, name) {
  const match = String(request.headers.cookie || "")
    .split(";")
    .map((part) => part.trim().split("="))
    .find(([key]) => key === name);
  return match?.[1] ?? null;
}

function startRotationFixture({ enabled = true, activeSecret = oldSecret,
  authenticatorLabel = "Authenticator app", genericRemoval = false,
  removalFactor = "totp", removalPath = "", removalInFrame = false,
  backupPrompt = null } = {}) {
  const sessions = new Set();
  const state = {
    enabled,
    activeSecret,
    disableCount: 0,
    enableCount: 0,
    successfulLogins: 0,
    backupPending: Boolean(backupPrompt && enabled && activeSecret === newSecret),
    backupDismissCount: 0,
  };
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    const authenticated = sessions.has(cookieValue(request, "session"));
    const html = (body) => {
      response.setHeader("content-type", "text/html; charset=utf-8");
      response.end(`<html lang="en-US"><body>${body}</body></html>`);
    };
    const redirect = (location) => {
      response.statusCode = 302;
      response.setHeader("location", location);
      response.end();
    };

    if (url.pathname === "/") {
      html(authenticated
        ? "<main>Signed in</main>"
        : "<button onclick=\"location.href='/email'\">Log in</button>");
      return;
    }
    if (url.pathname === "/email") {
      html(`<form action="/password"><input type="email" name="username"><button>Continue</button></form>`);
      return;
    }
    if (url.pathname === "/password") {
      if (state.enabled) {
        html(`<form action="/mfa-challenge/test"><input type="password"><button>Continue</button></form>`);
      } else {
        html(`<form action="/authenticated"><input type="password"><button>Continue</button></form>`);
      }
      return;
    }
    if (url.pathname === "/mfa-challenge/test") {
      html(`<iframe title="MFA" src="/mfa-frame"></iframe>`);
      return;
    }
    if (url.pathname === "/mfa-frame") {
      html(`<form action="/authenticated"><input name="code" inputmode="numeric"><button>Continue</button></form>`);
      return;
    }
    if (url.pathname === "/authenticated") {
      const accepted = !state.enabled || url.searchParams.get("code") === generateTOTP(state.activeSecret);
      if (!accepted) {
        response.statusCode = 401;
        html("Invalid code");
        return;
      }
      const session = `s${sessions.size + 1}`;
      sessions.add(session);
      state.successfulLogins += 1;
      response.setHeader("set-cookie", `session=${session}; Path=/; HttpOnly; SameSite=Lax`);
      redirect("/");
      return;
    }
    if (url.pathname === "/api/auth/session") {
      response.setHeader("content-type", "application/json");
      response.end(authenticated
        ? JSON.stringify({
          user: { email: "user@example.com" },
          account: { id: "acc-1", planType: "plus" },
        })
        : "{}");
      return;
    }
    if (url.pathname === "/backend-api/subscriptions") {
      response.setHeader("content-type", "application/json");
      response.end(authenticated
        ? JSON.stringify({
          account_id: "acc-1",
          plan_type: "plus",
          active_until: "2026-09-30T00:00:00Z",
          will_renew: true,
        })
        : "{}");
      return;
    }
    if (url.pathname === "/security") {
      if (!authenticated) {
        redirect("/");
        return;
      }
      html(`
        <button id="auth-switch" role="switch" aria-label="${authenticatorLabel}"
          aria-checked="${state.enabled}" ${state.backupPending && backupPrompt?.hideSwitch ? "hidden" : ""}>${authenticatorLabel}</button>
        <div id="remove-dialog" ${removalInFrame ? '' : 'role="dialog"'} hidden>
          ${removalInFrame ? '<iframe src="/remove-frame"></iframe>' : `
          <h2>${genericRemoval ? "Удалить способ аутентификации?" : "Remove authenticator app"}</h2>
          <form action="/disable">
            <input name="code" autocomplete="one-time-code">
            <button>Remove</button>
          </form>`}
        </div>
        <div id="setup-dialog" role="dialog" hidden>
          <h2>Connect your authenticator app</h2>
          <button id="problems" type="button">Problems scanning?</button>
          <code id="secret" hidden>${newSecret}</code>
          <form action="/enable">
            <input name="code" autocomplete="one-time-code">
            <button>Continue</button>
          </form>
        </div>
        ${backupPrompt && state.backupPending ? backupPrompt.inFrame ? '<iframe src="/backup-frame"></iframe>' : `<${backupPrompt.fullPage ? 'main' : 'div role="dialog"'} id="backup-dialog" hidden>
          ${backupPrompt.unrelatedSibling ? '<section>' : ''}<h2>${backupPrompt.heading ?? "Authenticator app added"}</h2>${backupPrompt.unrelatedSibling ? '</section></main><main>' : ''}
          <p>${backupPrompt.body ?? "Now, set up text messages as a backup MFA method. This will ensure you can still log into your account if you lose access to your authenticator app."}</p>
          <button>Add backup method</button>
          <button id="skip-backup" ${backupPrompt.disabled ? "disabled" : ""}>${backupPrompt.label ?? "Not now"}</button>
          ${backupPrompt.duplicate ? '<button>Not now</button>' : ''}
        </${backupPrompt.fullPage ? 'main' : 'div'}>` : ""}
        <script>
          const control = document.querySelector('#auth-switch');
          control.addEventListener('click', () => {
            if (${genericRemoval} && control.getAttribute('aria-checked') === 'true') {
              history.replaceState(null, '', '${removalPath}?action=disable&factor=${removalFactor}&factor_id=fixture');
            }
            document.querySelector(control.getAttribute('aria-checked') === 'true'
              ? '#remove-dialog' : '#setup-dialog').hidden = false;
          });
          document.querySelector('#problems').addEventListener('click', () => {
            document.querySelector('#secret').hidden = false;
          });
          let backup = document.querySelector('#backup-dialog');
          if (backup) {
            const promptContents = Array.from(backup.children);
            if (${Boolean(backupPrompt?.directBody)}) {
              backup.replaceWith(...promptContents);
              backup = document.body;
            }
            setTimeout(() => {
              ${backupPrompt?.path ? `history.replaceState(null, '', '${backupPrompt.path}');` : ''}
              backup.hidden = false;
            }, ${backupPrompt?.delayMs ?? 0});
            document.querySelector('#skip-backup').addEventListener('click', async () => {
              await fetch('/skip-backup');
              if (${Boolean(backupPrompt?.directBody)}) promptContents.forEach((element) => element.remove());
              else backup.hidden = true;
              control.hidden = false;
            });
          }
        </script>
      `);
      return;
    }
    if (url.pathname === "/remove-frame") {
      html(`<div role="dialog"><h2>Удалить способ аутентификации?</h2>
        <form action="/disable" target="_top"><input name="code" autocomplete="one-time-code">
        <button>Remove</button></form></div>`);
      return;
    }
    if (url.pathname === "/backup-frame") {
      html(`<div role="dialog"><h2>Authenticator app added</h2>
        <p>Now, set up text messages as a backup MFA method.</p>
        <button onclick="fetch('/skip-backup')">Not now</button></div>`);
      return;
    }
    if (url.pathname === "/disable") {
      if (!authenticated || url.searchParams.get("code") !== generateTOTP(state.activeSecret)) {
        response.statusCode = 401;
        html("Invalid code");
        return;
      }
      state.enabled = false;
      state.disableCount += 1;
      redirect("/security");
      return;
    }
    if (url.pathname === "/enable") {
      if (!authenticated || url.searchParams.get("code") !== generateTOTP(newSecret)) {
        response.statusCode = 401;
        html("Invalid code");
        return;
      }
      state.enabled = true;
      state.activeSecret = newSecret;
      state.enableCount += 1;
      state.backupPending = Boolean(backupPrompt);
      redirect("/security");
      return;
    }
    if (url.pathname === "/skip-backup") {
      state.backupDismissCount += 1;
      state.backupPending = false;
      response.end("ok");
      return;
    }
    response.statusCode = 404;
    response.end("not found");
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const baseURL = `http://127.0.0.1:${address.port}`;
      resolve({
        baseURL,
        securityURL: `${baseURL}/security`,
        state,
        close: () => new Promise((done) => server.close(done)),
      });
    });
  });
}

function request(overrides = {}) {
  return {
    operation: "rotate",
    email: "user@example.com",
    password: "private-password",
    currentSecret: oldSecret,
    pendingSecret: null,
    rotationStage: null,
    ...overrides,
  };
}

test("rotates authenticator and proves the new secret in a second clean Chrome", async (t) => {
  for (const genericRemoval of [false, true]) await t.test(`generic removal: ${genericRemoval}`, async () => {
    const fixture = await startRotationFixture({ authenticatorLabel: "Приложение для аутентификации", genericRemoval });
    const checkpoints = [];
    try {
      const result = await rotateAuthenticator(
        request(),
        async (checkpoint) => { checkpoints.push(checkpoint); },
        {
          headless: true,
          homeURL: fixture.baseURL,
          securityURL: fixture.securityURL,
          allowedOrigins: [fixture.baseURL],
        },
      );

      assert.deepEqual(checkpoints, [
        { checkpoint: "removalStarted" },
        { checkpoint: "oldMethodDisabled" },
        { checkpoint: "secretCaptured", secret: newSecret },
        { checkpoint: "setupConfirmed" },
      ]);
      assert.equal(fixture.state.disableCount, 1);
      assert.equal(fixture.state.enableCount, 1);
      assert.equal(fixture.state.activeSecret, newSecret);
      assert.equal(fixture.state.successfulLogins, 2);
      assert.deepEqual(result.proof, {
        passwordSubmitted: true,
        pendingOTPSubmitted: true,
        authenticatedImmediatelyAfterPendingOTP: true,
      });
      assert.equal(result.planLabel, "plus");
      assert.equal(result.activeUntil, "2026-09-30T00:00:00Z");
      assert.equal(result.willRenew, true);
    } finally {
      await fixture.close();
    }
  });
});

test("generic removal dialog is limited to the TOTP security page", async (t) => {
  for (const context of [{ removalFactor: "sms" }, { removalPath: "/billing" }, { removalInFrame: true }]) {
    await t.test(JSON.stringify(context), async () => {
      const fixture = await startRotationFixture({ genericRemoval: true, ...context });
      try {
        await assert.rejects(rotateAuthenticator(request(), async () => {}, {
          headless: true, homeURL: fixture.baseURL, securityURL: fixture.securityURL,
          allowedOrigins: [fixture.baseURL],
        }), /Authenticator removal dialog is unavailable/);
        assert.equal(fixture.state.disableCount, 0);
        assert.equal(fixture.state.enabled, true);
      } finally {
        await fixture.close();
      }
    });
  }
});

test("dismisses the optional text-message backup prompt after setup and resume", async (t) => {
  for (const context of [
    { backupPrompt: {} },
    { backupPrompt: { fullPage: true } },
    { backupPrompt: { directBody: true } },
    { backupPrompt: { label: "Не сейчас", delayMs: 450 } },
    { backupPrompt: { heading: "Приложение-аутентификатор добавлено", label: "Не сейчас",
      body: "Теперь настройте текстовые сообщения в качестве резервного метода MFA." } },
    { enabled: false, backupPrompt: {} },
    { activeSecret: newSecret, backupPrompt: { delayMs: 450 }, resume: true },
    { activeSecret: newSecret, backupPrompt: { delayMs: 450, hideSwitch: true }, resume: true },
  ]) await t.test(JSON.stringify(context), async () => {
    const fixture = await startRotationFixture(context);
    const checkpoints = [];
    try {
      await rotateAuthenticator(request(context.resume ? {
        pendingSecret: newSecret, rotationStage: "pendingSecretCaptured",
      } : {}), async (checkpoint) => {
        if (checkpoint.checkpoint === "setupConfirmed") {
          assert.equal(fixture.state.backupPending, false, "backup prompt must close before confirmation");
        }
        checkpoints.push(checkpoint);
      }, {
        headless: true, homeURL: fixture.baseURL, securityURL: fixture.securityURL,
        allowedOrigins: [fixture.baseURL],
      });
      assert.equal(fixture.state.backupDismissCount, 1);
      assert.equal(fixture.state.enabled, true);
      assert.equal(fixture.state.enableCount, context.resume ? 0 : 1);
      assert.equal(fixture.state.disableCount, context.resume || context.enabled === false ? 0 : 1);
      assert.equal(checkpoints.filter((value) => value.checkpoint === "setupConfirmed").length, 1);
    } finally {
      await fixture.close();
    }
  });
});

test("backup dismissal requires the known main-frame security prompt and one enabled button", async (t) => {
  for (const backupPrompt of [
    { heading: "Account updated" },
    { body: "Delete this account permanently?" },
    { fullPage: true, unrelatedSibling: true },
    { path: "/billing" },
    { inFrame: true },
    { duplicate: true },
    { disabled: true },
  ]) await t.test(JSON.stringify(backupPrompt), async () => {
    const fixture = await startRotationFixture({ activeSecret: newSecret, backupPrompt });
    const action = () => rotateAuthenticator(request({
      pendingSecret: newSecret, rotationStage: "pendingSecretCaptured",
    }), async () => {}, {
      headless: true, homeURL: fixture.baseURL, securityURL: fixture.securityURL,
      allowedOrigins: [fixture.baseURL],
    });
    try {
      if (backupPrompt.duplicate || backupPrompt.disabled) {
        await assert.rejects(action, /Browser control is ambiguous|Authenticator confirmation is unavailable/);
      } else {
        await action();
      }
      assert.equal(fixture.state.backupDismissCount, 0);
      assert.equal(fixture.state.enableCount, 0);
      assert.equal(fixture.state.disableCount, 0);
    } finally {
      await fixture.close();
    }
  });
});

test("awaiting clean login does not repeat security changes", async () => {
  const fixture = await startRotationFixture({ enabled: true, activeSecret: newSecret });
  const checkpoints = [];
  try {
    const result = await rotateAuthenticator(
      request({
        pendingSecret: newSecret,
        rotationStage: "awaitingCleanLogin",
      }),
      async (checkpoint) => { checkpoints.push(checkpoint); },
      {
        headless: true,
        homeURL: fixture.baseURL,
        securityURL: fixture.securityURL,
        allowedOrigins: [fixture.baseURL],
      },
    );

    assert.equal(result.signedInEmail, "user@example.com");
    assert.deepEqual(checkpoints, []);
    assert.equal(fixture.state.disableCount, 0);
    assert.equal(fixture.state.enableCount, 0);
    assert.equal(fixture.state.successfulLogins, 1);
  } finally {
    await fixture.close();
  }
});

test("ambiguous recovery stages fail before launching a fresh browser", async () => {
  for (const rotationStage of ["removingOldMethod", "oldMethodDisabled"]) {
    let launches = 0;
    await assert.rejects(
      rotateAuthenticator(
        request({ rotationStage }),
        async () => {},
        {
          launchBrowser: async () => {
            launches += 1;
            throw new Error("browser launched");
          },
        },
      ),
      (error) => error instanceof ManualRecoveryError
        && error.code === "manual_recovery_required"
        && error.stage === rotationStage,
    );
    assert.equal(launches, 0);
  }
});

test("pending-secret stage recognizes setup completed before its checkpoint", async () => {
  const fixture = await startRotationFixture({ enabled: true, activeSecret: newSecret });
  const checkpoints = [];
  try {
    await rotateAuthenticator(
      request({
        pendingSecret: newSecret,
        rotationStage: "pendingSecretCaptured",
      }),
      async (checkpoint) => { checkpoints.push(checkpoint); },
      {
        headless: true,
        homeURL: fixture.baseURL,
        securityURL: fixture.securityURL,
        allowedOrigins: [fixture.baseURL],
      },
    );

    assert.deepEqual(checkpoints, [{ checkpoint: "setupConfirmed" }]);
    assert.equal(fixture.state.disableCount, 0);
    assert.equal(fixture.state.enableCount, 0);
    assert.equal(fixture.state.successfulLogins, 2);
  } finally {
    await fixture.close();
  }
});

test("worker waits for every persisted checkpoint acknowledgement", async () => {
  const fixture = await startRotationFixture();
  const child = spawn(process.execPath, [path.join(__dirname, "..", "src", "worker.js")], {
    env: {
      ...process.env,
      GPTAM_HEADLESS: "1",
      GPTAM_HOME_URL: fixture.baseURL,
      GPTAM_SECURITY_URL: fixture.securityURL,
      GPTAM_ALLOWED_ORIGIN: fixture.baseURL,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const events = [];
  const lines = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
  const consume = (async () => {
    for await (const line of lines) {
      const event = JSON.parse(line);
      events.push(event);
      if (event.type === "checkpoint") {
        child.stdin.write(`${JSON.stringify({ type: "ack", id: event.id })}\n`);
      }
    }
  })();
  const workerRequest = request();
  child.stdin.write(`${JSON.stringify(workerRequest)}\n`);

  const [exitCode] = await once(child, "close");
  await consume;
  await fixture.close();

  assert.equal(exitCode, 0, stderr);
  assert.deepEqual(
    events.filter((event) => event.type === "checkpoint").map((event) => event.checkpoint),
    ["removalStarted", "oldMethodDisabled", "secretCaptured", "setupConfirmed"],
  );
  const result = events.find((event) => event.type === "result");
    assert.equal(result.status, "success");
    assert.equal(result.signedInEmail, "user@example.com");
    assert.equal(result.planLabel, "plus");
    assert.equal(result.activeUntil, "2026-09-30T00:00:00Z");
    assert.equal(result.willRenew, true);
  const output = JSON.stringify(events);
  assert.equal(output.includes(workerRequest.password), false);
  assert.equal(output.includes(workerRequest.currentSecret), false);
});

test("worker maps ambiguous recovery to a non-retryable manual result", async () => {
  const child = spawn(process.execPath, [path.join(__dirname, "..", "src", "worker.js")], {
    env: { ...process.env, GPTAM_HEADLESS: "1" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  child.stdin.end(`${JSON.stringify(request({ rotationStage: "oldMethodDisabled" }))}\n`);

  const [exitCode] = await once(child, "close");

  assert.equal(exitCode, 0, stderr);
  const events = stdout.trim().split("\n").map((line) => JSON.parse(line));
  assert.equal(events.some((event) => event.type === "checkpoint"), false);
  const result = events.find((event) => event.type === "result");
  assert.equal(result.status, "manual");
  assert.equal(result.stage, "oldMethodDisabled");
  assert.match(result.message, /original authenticated app session/i);
});
