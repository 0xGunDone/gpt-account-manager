const assert = require("node:assert/strict");
const { PassThrough } = require("node:stream");
const test = require("node:test");

const {
  ProtocolError,
  ProtocolReader,
  emitEvent,
  validateRequest,
} = require("../src/protocol");

const validRequest = {
  operation: "rotate",
  email: "user@example.com",
  password: "private-password",
  currentSecret: "JBSWY3DPEHPK3PXP",
  pendingSecret: null,
  rotationStage: null,
};

test("validates complete check and rotation requests", () => {
  assert.deepEqual(validateRequest(validRequest), validRequest);
  assert.equal(validateRequest({ ...validRequest, operation: "check" }).operation, "check");
});

test("rejects unknown operations and malformed credentials", () => {
  assert.throws(
    () => validateRequest({ ...validRequest, operation: "delete" }),
    ProtocolError,
  );
  assert.throws(
    () => validateRequest({ ...validRequest, currentSecret: "" }),
    ProtocolError,
  );
});

test("accepts the confirmed old-method-disabled rotation stage", () => {
  const request = validateRequest({
    ...validRequest,
    rotationStage: "oldMethodDisabled",
  });

  assert.equal(request.rotationStage, "oldMethodDisabled");
  assert.throws(
    () => validateRequest({ ...validRequest, rotationStage: "unknown-stage" }),
    ProtocolError,
  );
});

test("emits only the explicitly supplied safe event fields", () => {
  const output = new PassThrough();
  let written = "";
  output.setEncoding("utf8");
  output.on("data", (chunk) => { written += chunk; });

  emitEvent(output, {
    type: "result",
    status: "failure",
    message: "OpenAI page changed",
    password: validRequest.password,
    currentSecret: validRequest.currentSecret,
  });

  assert.deepEqual(JSON.parse(written), {
    type: "result",
    status: "failure",
    message: "OpenAI page changed",
  });
  assert.equal(written.includes(validRequest.password), false);
  assert.equal(written.includes(validRequest.currentSecret), false);
});

test("checkpoint acknowledgement must match the emitted id", async () => {
  const input = new PassThrough();
  const reader = new ProtocolReader(input);
  input.end('{"type":"ack","id":"cp-1"}\n');

  await reader.awaitCheckpointAck("cp-1");
});

test("mismatched checkpoint acknowledgement is rejected", async () => {
  const input = new PassThrough();
  const reader = new ProtocolReader(input);
  input.end('{"type":"ack","id":"wrong"}\n');

  await assert.rejects(reader.awaitCheckpointAck("cp-1"), ProtocolError);
});
