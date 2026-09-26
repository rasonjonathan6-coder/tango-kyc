/**
 * Unit tests for the MVola error surface shared by the Edge Functions.
 *
 * The payment rules themselves live in SQL and are covered by the backend
 * suite. What is exercised here is the layer the client actually sees: a
 * database error must become a stable machine code with a user-safe message and
 * the right HTTP status, and internals must never leak through it.
 *
 * Run with:  deno test --allow-env supabase/functions/tests/mvola_test.ts
 */
import { assert, assertEquals } from "jsr:@std/assert@1.0.6";
import { AppError, errorResponse, handlePreflight, translateDbError } from "../_shared/http.ts";

/** Reads the JSON body and status off a Response produced by errorResponse. */
async function bodyOf(error: unknown): Promise<{ status: number; body: Record<string, string> }> {
  const response = errorResponse(error);
  return { status: response.status, body: await response.json() };
}

Deno.test("translateDbError maps each MVola database code to itself", () => {
  const codes = [
    "PAYMENT_NOT_FOUND",
    "PAYMENT_ALREADY_REVIEWED",
    "MVOLA_NOT_CONFIGURED",
    "MVOLA_DISABLED",
    "MVOLA_UNAVAILABLE",
    "MVOLA_REFERENCE_REQUIRED",
    "MVOLA_REFERENCE_INVALID",
    "MVOLA_PAYER_INVALID",
    "MVOLA_DECISION_INVALID",
    "MVOLA_REASON_REQUIRED",
    "MVOLA_REASON_INVALID",
  ];
  for (const code of codes) {
    const mapped = translateDbError({ message: `P0001: ${code}` });
    assertEquals(mapped.code, code, `${code} should survive translation`);
  }
});

Deno.test("translateDbError keeps the pre-existing codes intact", () => {
  // Guards the MVola additions against shadowing the original mappings.
  const codes = ["AUTH_REQUIRED", "FORBIDDEN", "TICKET_NOT_FOUND", "MESSAGE_REQUIRED", "RATE_LIMITED"];
  for (const code of codes) {
    assertEquals(translateDbError({ message: code }).code, code);
  }
});

Deno.test("RATE_LIMITED_DAILY is not shadowed by its RATE_LIMITED prefix", () => {
  assertEquals(translateDbError({ message: "RATE_LIMITED_DAILY" }).code, "RATE_LIMITED_DAILY");
});

Deno.test("MVOLA_REFERENCE_REQUIRED is not shadowed by MVOLA_REFERENCE_INVALID", () => {
  assertEquals(
    translateDbError({ message: "MVOLA_REFERENCE_REQUIRED" }).code,
    "MVOLA_REFERENCE_REQUIRED",
  );
});

Deno.test("an unrecognised database error degrades to INTERNAL and leaks nothing", async () => {
  const mapped = translateDbError({ message: "relation \"secret_table\" does not exist at line 42" });
  assertEquals(mapped.code, "INTERNAL");

  const { status, body } = await bodyOf(mapped);
  assertEquals(status, 500);
  assertEquals(body.error, "INTERNAL");
  assertEquals(body.message, "Something went wrong. Please try again.");
  assert(!JSON.stringify(body).includes("secret_table"), "internal detail must not leak");
});

Deno.test("payment errors answer with the status the client branches on", async () => {
  const cases: Array<[string, number]> = [
    ["PAYMENT_NOT_FOUND", 404],
    ["PAYMENT_ALREADY_REVIEWED", 409],
    ["MVOLA_REFERENCE_REQUIRED", 422],
    ["MVOLA_REFERENCE_INVALID", 422],
    ["MVOLA_REASON_REQUIRED", 422],
    ["MVOLA_NOT_CONFIGURED", 503],
    ["MVOLA_DISABLED", 503],
    ["FORBIDDEN", 403],
    ["AUTH_REQUIRED", 401],
  ];
  for (const [code, expected] of cases) {
    const { status, body } = await bodyOf(new AppError(code, "internal detail"));
    assertEquals(status, expected, `${code} should answer ${expected}`);
    assertEquals(body.error, code);
    assertEquals(body.message.includes("internal detail"), false, `${code} must not echo internals`);
  }
});

Deno.test("an unconfigured mobile money service is not reported as a client error", async () => {
  const { status } = await bodyOf(new AppError("MVOLA_NOT_CONFIGURED", "missing app_settings row"));
  assertEquals(status, 503);
});

Deno.test("preflight is answered for the payment endpoint and other methods fall through", async () => {
  const preflight = handlePreflight(new Request("https://example.test", { method: "OPTIONS" }));
  assert(preflight !== null, "OPTIONS must be answered");
  assertEquals(preflight!.status, 204);

  assertEquals(handlePreflight(new Request("https://example.test", { method: "POST" })), null);
});
