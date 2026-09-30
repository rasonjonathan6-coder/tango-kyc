/**
 * Tests for the server-side FCM sender.
 *
 * Everything asserted here is a pure function, so it runs with no network, no
 * Firebase project and no real device:
 *
 *   * a service account is read only when fully configured;
 *   * the message carries a generic title/body and only the opaque ticket id;
 *   * a token FCM declares dead is classified as stale (so it is pruned) while
 *     a transient error is not (so a live device is never silently dropped).
 *
 * Run with:  deno test --allow-env supabase/functions/tests/push_test.ts
 */
import { assert, assertEquals } from "jsr:@std/assert@1.0.6";
import {
  buildFcmMessage,
  isStaleTokenError,
  loadServiceAccount,
  normalizePrivateKey,
  pushConfigured,
} from "../_shared/push.ts";

function envFrom(map: Record<string, string>): (key: string) => string | undefined {
  return (key) => map[key];
}

Deno.test("push is unconfigured when no Firebase secret is present", () => {
  assert(!pushConfigured(envFrom({})));
  assertEquals(loadServiceAccount(envFrom({})), null);
});

Deno.test("a full service-account JSON configures push", () => {
  const account = loadServiceAccount(
    envFrom({
      FIREBASE_SERVICE_ACCOUNT: JSON.stringify({
        project_id: "tango-kyc",
        client_email: "sender@tango-kyc.iam.gserviceaccount.com",
        private_key: "-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----",
      }),
    }),
  );
  assert(account);
  assertEquals(account!.projectId, "tango-kyc");
  assertEquals(account!.clientEmail, "sender@tango-kyc.iam.gserviceaccount.com");
  // Escaped newlines must be restored for the key to import.
  assert(account!.privateKey.includes("\n"));
});

Deno.test("discrete variables also configure push", () => {
  const account = loadServiceAccount(
    envFrom({
      FIREBASE_PROJECT_ID: "tango-kyc",
      FIREBASE_CLIENT_EMAIL: "sender@tango-kyc.iam.gserviceaccount.com",
      FIREBASE_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----",
    }),
  );
  assert(account);
  assertEquals(account!.projectId, "tango-kyc");
});

Deno.test("a partial configuration is not accepted", () => {
  assert(!pushConfigured(envFrom({ FIREBASE_PROJECT_ID: "tango-kyc" })));
  assert(!pushConfigured(envFrom({ FIREBASE_SERVICE_ACCOUNT: "{not json" })));
});

Deno.test("normalizePrivateKey leaves a real PEM untouched", () => {
  const real = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----";
  assertEquals(normalizePrivateKey(real), real);
});

Deno.test("the FCM message carries only the title, body and opaque ticket id", () => {
  const body = buildFcmMessage("device-token", {
    title: "Nouvelle réponse à votre demande",
    body: "Vous avez reçu une nouvelle réponse concernant votre demande KYC.",
    ticketId: "11111111-1111-1111-1111-111111111111",
  }) as {
    message: {
      token: string;
      notification: { title: string; body: string };
      data: Record<string, string>;
      android: Record<string, unknown>;
    };
  };

  assertEquals(body.message.token, "device-token");
  assertEquals(body.message.notification.title, "Nouvelle réponse à votre demande");
  assertEquals(body.message.data.ticket_id, "11111111-1111-1111-1111-111111111111");
  // No sensitive field may ride along.
  assertEquals(Object.keys(body.message.data), ["ticket_id"]);
});

Deno.test("the message targets the high-importance KYC channel", () => {
  const body = buildFcmMessage("t", { title: "x", body: "y" }) as {
    message: { android: { priority: string; notification: Record<string, unknown> } };
  };
  assertEquals(body.message.android.priority, "HIGH");
  assertEquals(body.message.android.notification.channel_id, "kyc_replies");
});

Deno.test("a message without a ticket id carries no data key", () => {
  const body = buildFcmMessage("t", { title: "x", body: "y" }) as {
    message: { data: Record<string, string> };
  };
  assertEquals(body.message.data.ticket_id, undefined);
});

Deno.test("an UNREGISTERED response marks the token stale", () => {
  assert(isStaleTokenError(404, "{}"));
  assert(isStaleTokenError(400, '{"error":{"details":[{"errorCode":"UNREGISTERED"}]}}'));
  assert(isStaleTokenError(400, "registration-token-not-registered"));
});

Deno.test("a transient failure does not mark the token stale", () => {
  assert(!isStaleTokenError(503, "backend unavailable"));
  assert(!isStaleTokenError(429, "quota exceeded"));
  assert(!isStaleTokenError(401, "invalid credentials"));
});
