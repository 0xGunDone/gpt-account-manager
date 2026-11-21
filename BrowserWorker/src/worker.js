const { ProtocolReader, emitEvent } = require("./protocol");
const {
  HumanChallengeError,
  ManualRecoveryError,
  checkSubscription,
  launchFreshChrome,
  rotateAuthenticator,
  safeFailureMessage,
  signIn,
} = require("./openai-flow");

async function main() {
  const reader = new ProtocolReader(process.stdin);
  let runtime = null;
  try {
    const request = await reader.readRequest();
    const homeURL = process.env.GPTAM_HOME_URL || "https://chatgpt.com/";
    const allowedOrigins = process.env.GPTAM_ALLOWED_ORIGIN
      ? [process.env.GPTAM_ALLOWED_ORIGIN]
      : [];
    const options = {
      headless: process.env.GPTAM_HEADLESS === "1",
      homeURL,
      allowedOrigins,
      securityURL: process.env.GPTAM_SECURITY_URL || "https://chatgpt.com/#settings/Security",
      pricingURL: process.env.GPTAM_PRICING_URL || "https://chatgpt.com/#pricing",
    };

    if (request.operation === "check") {
      runtime = await launchFreshChrome({ headless: options.headless });
      await signIn(runtime.page, request, request.currentSecret, options);
      const subscription = await checkSubscription(runtime.page, options);
      emitEvent(process.stdout, {
        type: "result",
        status: "success",
        ...subscription,
      });
    } else {
      let checkpointNumber = 0;
      const result = await rotateAuthenticator(
        request,
        async (checkpoint) => {
          checkpointNumber += 1;
          const id = `cp-${checkpointNumber}`;
          emitEvent(process.stdout, {
            type: "checkpoint",
            id,
            ...checkpoint,
          });
          await reader.awaitCheckpointAck(id);
        },
        options,
      );
      emitEvent(process.stdout, {
        type: "result",
        status: "success",
        signedInEmail: result.signedInEmail,
        planLabel: result.planLabel,
        activeUntil: result.activeUntil,
        activeUntilText: result.activeUntilText,
        locale: result.locale,
        willRenew: result.willRenew,
        proof: result.proof,
      });
    }
  } catch (error) {
    if (error instanceof ManualRecoveryError) {
      emitEvent(process.stdout, {
        type: "result",
        status: "manual",
        stage: error.stage,
        message: error.message,
      });
    } else if (error instanceof HumanChallengeError) {
      emitEvent(process.stdout, {
        type: "result",
        status: "manual",
        message: "Complete the human verification in Google Chrome, then continue",
      });
    } else {
      emitEvent(process.stdout, {
        type: "result",
        status: "failure",
        message: safeFailureMessage(error),
      });
    }
  } finally {
    if (runtime) await runtime.close();
    reader.close();
  }
}

main().catch(() => {
  process.exitCode = 1;
});
