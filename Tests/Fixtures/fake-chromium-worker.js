const readline = require("node:readline");

const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
const iterator = lines[Symbol.asyncIterator]();

async function read() {
  const next = await iterator.next();
  if (next.done) throw new Error("input ended");
  return JSON.parse(next.value);
}

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

async function checkpoint(id, value) {
  emit({ type: "checkpoint", id, ...value });
  const ack = await read();
  if (ack.type !== "ack" || ack.id !== id) throw new Error("bad ack");
}

async function main() {
  const request = await read();
  if (process.argv.slice(2).some((argument) => [
    request.email,
    request.password,
    request.currentSecret,
  ].some((secret) => argument.includes(secret)))) {
    throw new Error("credential leaked through argv");
  }
  if (request.email === "hang@example.com") {
    setInterval(() => {}, 1_000);
    return;
  }
  if (request.operation === "check") {
    emit({
      type: "result",
      status: "success",
      signedInEmail: request.email,
      planLabel: "plus",
      activeUntil: "2026-09-30T00:00:00Z",
      willRenew: true,
    });
    lines.close();
    return;
  }
  await checkpoint("cp-1", { checkpoint: "removalStarted" });
  await checkpoint("cp-2", { checkpoint: "oldMethodDisabled" });
  await checkpoint("cp-3", {
    checkpoint: "secretCaptured",
    secret: "KRUGS4ZANFZSAYJA",
  });
  await checkpoint("cp-4", { checkpoint: "setupConfirmed" });
  emit({
    type: "result",
    status: "success",
    signedInEmail: request.email,
    proof: {
      passwordSubmitted: true,
      pendingOTPSubmitted: true,
      authenticatedImmediatelyAfterPendingOTP: true,
    },
  });
  lines.close();
}

main().catch(() => { process.exitCode = 1; });
