// The registered number must be a ten-digit Madagascar mobile number with an
// operator prefix 032/033/034/037/038. Mirrors the client rule.
import { assertEquals } from "jsr:@std/assert";
import { isValidRegisterNumber } from "../_shared/register.ts";

Deno.test("accepts ten-digit numbers with every allowed prefix", () => {
  for (const prefix of ["032", "033", "034", "037", "038"]) {
    assertEquals(
      isValidRegisterNumber(`${prefix}1234567`),
      true,
      `${prefix} must be accepted`,
    );
  }
});

Deno.test("accepts the number even when formatted with spaces or dashes", () => {
  assertEquals(isValidRegisterNumber("034 67 54 333"), true);
  assertEquals(isValidRegisterNumber("034-675-4333"), true);
});

Deno.test("rejects a number that is not ten digits", () => {
  assertEquals(isValidRegisterNumber("034675433"), false); // nine digits
  assertEquals(isValidRegisterNumber("03467543330"), false); // eleven digits
});

Deno.test("rejects a number with a disallowed prefix", () => {
  assertEquals(isValidRegisterNumber("0311234567"), false);
  assertEquals(isValidRegisterNumber("0351234567"), false);
  assertEquals(isValidRegisterNumber("0361234567"), false);
  assertEquals(isValidRegisterNumber("0391234567"), false);
});

Deno.test("rejects a number that is not a phone at all", () => {
  assertEquals(isValidRegisterNumber("hello"), false);
  assertEquals(isValidRegisterNumber("   "), false);
});

Deno.test("lets an email through: the rule only constrains numbers", () => {
  assertEquals(isValidRegisterNumber("user+a-mvola-e2e-1@example.com"), true);
});
