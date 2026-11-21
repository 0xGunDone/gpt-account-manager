const readline = require("node:readline");

class ProtocolError extends Error {}

const operations = new Set(["check", "rotate"]);
const rotationStages = new Set([
  null,
  "removingOldMethod",
  "oldMethodDisabled",
  "pendingSecretCaptured",
  "awaitingCleanLogin",
]);

function requiredString(value, field) {
  if (typeof value !== "string" || value.length === 0) {
    throw new ProtocolError(`Invalid ${field}`);
  }
  return value;
}

function validateRequest(value) {
  if (!value || typeof value !== "object" || !operations.has(value.operation)) {
    throw new ProtocolError("Invalid operation");
  }
  const request = {
    operation: value.operation,
    email: requiredString(value.email, "email"),
    password: requiredString(value.password, "password"),
    currentSecret: requiredString(value.currentSecret, "currentSecret"),
    pendingSecret: value.pendingSecret == null
      ? null
      : requiredString(value.pendingSecret, "pendingSecret"),
    rotationStage: value.rotationStage ?? null,
  };
  if (!rotationStages.has(request.rotationStage)) {
    throw new ProtocolError("Invalid rotationStage");
  }
  return request;
}

class ProtocolReader {
  constructor(input) {
    this.interface = readline.createInterface({ input, crlfDelay: Infinity });
    this.lines = this.interface[Symbol.asyncIterator]();
  }

  async nextObject() {
    const next = await this.lines.next();
    if (next.done) throw new ProtocolError("Unexpected end of input");
    try {
      return JSON.parse(next.value);
    } catch {
      throw new ProtocolError("Malformed JSON");
    }
  }

  async readRequest() {
    return validateRequest(await this.nextObject());
  }

  async awaitCheckpointAck(id) {
    const value = await this.nextObject();
    if (value?.type !== "ack" || value?.id !== id) {
      throw new ProtocolError("Checkpoint acknowledgement mismatch");
    }
  }

  close() {
    this.interface.close();
  }
}

const eventFields = new Set([
  "type",
  "id",
  "checkpoint",
  "secret",
  "status",
  "message",
  "stage",
  "signedInEmail",
  "planLabel",
  "activeUntil",
  "activeUntilText",
  "locale",
  "willRenew",
  "proof",
]);

function emitEvent(output, event) {
  const safe = {};
  for (const [key, value] of Object.entries(event)) {
    if (eventFields.has(key) && value !== undefined) safe[key] = value;
  }
  output.write(`${JSON.stringify(safe)}\n`);
}

module.exports = {
  ProtocolError,
  ProtocolReader,
  emitEvent,
  validateRequest,
};
