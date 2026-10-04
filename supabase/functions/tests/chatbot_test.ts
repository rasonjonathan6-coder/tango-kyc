/**
 * Tests for the Tango KYC assistant: provider resolution and guardrails.
 *
 * Everything here is a pure function or an environment lookup, so it runs with
 * no network, no provider account and no API key:
 *
 *   * the provider is inferred from whichever key is present;
 *   * an explicit LLM_PROVIDER wins, and an unknown one disables the feature
 *     rather than guessing;
 *   * no key at all means "not configured" (an honest refusal, not a fake);
 *   * the guardrails catch an internal detail the model must never emit;
 *   * the knowledge base is public and carries no credential.
 *
 * Run with:  deno test --allow-env supabase/functions/tests/chatbot_test.ts
 */
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.6";
import {
  ASSISTANT_SAFE_FALLBACK,
  replyLeaksInternals,
  TANGO_KYC_KNOWLEDGE,
  TANGO_KYC_SYSTEM_PROMPT,
} from "../_shared/chatbot.ts";
import { llmConfigured, resolveLlm } from "../_shared/llm.ts";

const KEY_NAMES = [
  "LLM_PROVIDER",
  "LLM_API_KEY",
  "LLM_MODEL",
  "LLM_BASE_URL",
  "OPENAI_API_KEY",
  "ANTHROPIC_API_KEY",
  "GEMINI_API_KEY",
  "GOOGLE_API_KEY",
];

function withEnv(map: Record<string, string>, fn: () => void): void {
  const saved: Record<string, string | undefined> = {};
  for (const name of KEY_NAMES) {
    saved[name] = Deno.env.get(name);
    Deno.env.delete(name);
  }
  for (const [k, v] of Object.entries(map)) Deno.env.set(k, v);
  try {
    fn();
  } finally {
    for (const name of KEY_NAMES) {
      const value = saved[name];
      if (value === undefined) Deno.env.delete(name);
      else Deno.env.set(name, value);
    }
  }
}

Deno.test("no key at all means the assistant is unconfigured", () => {
  withEnv({}, () => {
    assertFalse(llmConfigured());
    assertEquals(resolveLlm(), null);
  });
});

Deno.test("an OpenAI key is inferred as the openai provider", () => {
  withEnv({ OPENAI_API_KEY: "sk-test" }, () => {
    const resolved = resolveLlm();
    assert(resolved);
    assertEquals(resolved!.provider, "openai");
    assertEquals(resolved!.model, "gpt-4o-mini");
    assert(resolved!.baseUrl.startsWith("https://api.openai.com"));
  });
});

Deno.test("an Anthropic key is inferred as the anthropic provider", () => {
  withEnv({ ANTHROPIC_API_KEY: "sk-ant-test" }, () => {
    assertEquals(resolveLlm()!.provider, "anthropic");
  });
});

Deno.test("a Gemini key is inferred as the gemini provider", () => {
  withEnv({ GEMINI_API_KEY: "gm-test" }, () => {
    assertEquals(resolveLlm()!.provider, "gemini");
  });
});

Deno.test("an explicit LLM_PROVIDER wins over inference", () => {
  withEnv({ LLM_PROVIDER: "anthropic", LLM_API_KEY: "k" }, () => {
    assertEquals(resolveLlm()!.provider, "anthropic");
  });
});

Deno.test("an explicit model and base URL are honoured", () => {
  withEnv(
    { LLM_PROVIDER: "compatible", LLM_API_KEY: "k", LLM_MODEL: "my-model", LLM_BASE_URL: "https://gw.example/v1/" },
    () => {
      const resolved = resolveLlm()!;
      assertEquals(resolved.model, "my-model");
      // The trailing slash is normalised away so URL joining is predictable.
      assertEquals(resolved.baseUrl, "https://gw.example/v1");
    },
  );
});

Deno.test("a compatible provider without a base URL is disabled", () => {
  withEnv({ LLM_PROVIDER: "compatible", LLM_API_KEY: "k" }, () => {
    assertEquals(resolveLlm(), null);
  });
});

Deno.test("an unknown provider is disabled rather than guessed", () => {
  withEnv({ LLM_PROVIDER: "not-a-provider", LLM_API_KEY: "k" }, () => {
    assertEquals(resolveLlm(), null);
  });
});

Deno.test("a provider with no key is disabled", () => {
  withEnv({ LLM_PROVIDER: "openai" }, () => {
    assertEquals(resolveLlm(), null);
  });
});

Deno.test("guardrails catch an internal detail in a reply", () => {
  assert(replyLeaksInternals("The service_role key is ..."));
  assert(replyLeaksInternals("Set SUPABASE_URL in your environment."));
  assert(replyLeaksInternals("The api key is sk-abc123"));
  assert(replyLeaksInternals("We store this in Postgres."));
});

Deno.test("guardrails catch any email address in a reply", () => {
  assert(replyLeaksInternals("Écrivez à support@tango-kyc.example.com"));
  assert(replyLeaksInternals("The admin address is kyc-admin@example.com."));
});

Deno.test("the knowledge base contains no email address", () => {
  const email = /[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/i;
  assertFalse(email.test(TANGO_KYC_KNOWLEDGE));
  assertFalse(email.test(TANGO_KYC_SYSTEM_PROMPT));
});

Deno.test("the knowledge base covers Tango.me questions", () => {
  assert(TANGO_KYC_KNOWLEDGE.includes("Tango.me"));
  assert(TANGO_KYC_KNOWLEDGE.includes("compte Tango"));
});

Deno.test("the system prompt forbids disclosing emails", () => {
  assert(TANGO_KYC_SYSTEM_PROMPT.includes("EMAILS ET CONTACTS"));
  assert(TANGO_KYC_SYSTEM_PROMPT.toLowerCase().includes("email"));
});

Deno.test("guardrails allow an ordinary support answer", () => {
  assertFalse(replyLeaksInternals("Le support répond généralement sous 24 heures ouvrées."));
  assertFalse(replyLeaksInternals("Ouvrez une demande et l'équipe vous répondra."));
});

Deno.test("the safe fallback says nothing internal", () => {
  assertFalse(replyLeaksInternals(ASSISTANT_SAFE_FALLBACK));
});

Deno.test("the knowledge base carries no credential", () => {
  const forbidden = [/service_role/i, /sk-[a-z0-9]/i, /SUPABASE_URL/i, /api[_\s-]?key/i];
  for (const pattern of forbidden) {
    assertFalse(pattern.test(TANGO_KYC_KNOWLEDGE));
  }
});

Deno.test("the system prompt pins the assistant to the knowledge base", () => {
  assert(TANGO_KYC_SYSTEM_PROMPT.includes("UNIQUEMENT"));
  assert(TANGO_KYC_SYSTEM_PROMPT.includes(TANGO_KYC_KNOWLEDGE));
  assert(TANGO_KYC_SYSTEM_PROMPT.toLowerCase().includes("jamais"));
});
