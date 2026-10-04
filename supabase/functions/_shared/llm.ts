/**
 * LLM provider abstraction for the Tango KYC assistant.
 *
 * The chatbot must not be welded to one vendor: the key that is available in a
 * given deployment decides the provider. This module resolves a provider from
 * the environment and exposes one `completeChat` call with a common shape.
 *
 * Configuration (all Edge Function secrets, never in the Flutter app):
 *
 *   LLM_PROVIDER   optional. "openai" | "anthropic" | "gemini" | "compatible".
 *                  When absent, it is inferred from whichever key is present.
 *   LLM_API_KEY    the generic key, used when a provider-specific key is absent.
 *   LLM_MODEL      optional model id; each provider has a sane default.
 *   LLM_BASE_URL   optional base URL, required for "compatible" and honoured for
 *                  openai/anthropic when a gateway is used.
 *   LLM_TIMEOUT_MS optional per-call timeout in ms; default 45s, clamped to
 *                  [5s, 110s]. A timed-out call is retried once.
 *
 * Provider-specific fallbacks: OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY.
 *
 * If no key is configured, `resolveLlm()` returns null and the caller answers
 * with an honest "assistant unavailable" message instead of pretending.
 */
import { AppError } from "./http.ts";

/**
 * Reads an environment variable. Kept local (rather than importing the shared
 * `env` from `clients.ts`) so this module has no Supabase dependency and can be
 * unit-tested without pulling the whole client library in.
 */
function env(name: string): string {
  return Deno.env.get(name) ?? "";
}

export interface ChatMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

export interface LlmResult {
  text: string;
  provider: string;
  model: string;
}

type Provider = "openai" | "anthropic" | "gemini" | "compatible";

interface Resolved {
  provider: Provider;
  apiKey: string;
  model: string;
  baseUrl: string;
}

const DEFAULT_MODELS: Record<Provider, string> = {
  openai: "gpt-4o-mini",
  anthropic: "claude-3-5-haiku-latest",
  gemini: "gemini-2.0-flash",
  compatible: "gpt-4o-mini",
};

const DEFAULT_BASE_URLS: Record<Provider, string> = {
  openai: "https://api.openai.com/v1",
  anthropic: "https://api.anthropic.com/v1",
  gemini: "https://generativelanguage.googleapis.com/v1beta",
  compatible: "",
};

function keyFor(provider: Provider): string {
  const generic = env("LLM_API_KEY");
  if (generic) return generic;
  switch (provider) {
    case "openai":
    case "compatible":
      return env("OPENAI_API_KEY");
    case "anthropic":
      return env("ANTHROPIC_API_KEY");
    case "gemini":
      return env("GEMINI_API_KEY") || env("GOOGLE_API_KEY");
  }
}

function inferProvider(): Provider | null {
  if (env("OPENAI_API_KEY")) return "openai";
  if (env("ANTHROPIC_API_KEY")) return "anthropic";
  if (env("GEMINI_API_KEY") || env("GOOGLE_API_KEY")) return "gemini";
  if (env("LLM_BASE_URL")) return "compatible";
  return null;
}

/** Resolves the provider and key, or null when the assistant is unconfigured. */
export function resolveLlm(): Resolved | null {
  const configured = env("LLM_PROVIDER").trim().toLowerCase();
  const provider = (configured || inferProvider()) as Provider | null;
  if (!provider) return null;
  if (!["openai", "anthropic", "gemini", "compatible"].includes(provider)) return null;

  const apiKey = keyFor(provider);
  if (!apiKey) return null;

  const baseUrl = env("LLM_BASE_URL") || DEFAULT_BASE_URLS[provider];
  if (!baseUrl) return null;

  return {
    provider,
    apiKey,
    model: env("LLM_MODEL") || DEFAULT_MODELS[provider],
    baseUrl: baseUrl.replace(/\/$/, ""),
  };
}

/** True when a provider key is configured, so the client can hide the feature. */
export function llmConfigured(): boolean {
  return resolveLlm() !== null;
}

/**
 * Upper bound on a single provider call, from `LLM_TIMEOUT_MS` when set.
 *
 * The default is sized for a shared inference endpoint: a normal Nemotron
 * "lightning" turn lands in a few seconds, but a cold or busy worker can take
 * noticeably longer. 25s cut those slow-but-fine turns short and surfaced them
 * as errors; 45s absorbs them while still failing well before the Edge
 * Function's own wall-clock limit. The value is clamped so a mistyped secret
 * cannot disable the guard entirely.
 */
const DEFAULT_LLM_TIMEOUT_MS = 45_000;
const MIN_LLM_TIMEOUT_MS = 5_000;
const MAX_LLM_TIMEOUT_MS = 110_000;

/** One extra attempt after a timeout or a transient upstream error. */
const LLM_MAX_ATTEMPTS = 2;

function requestTimeoutMs(): number {
  const configured = Number.parseInt(env("LLM_TIMEOUT_MS"), 10);
  if (!Number.isFinite(configured)) return DEFAULT_LLM_TIMEOUT_MS;
  return Math.min(Math.max(configured, MIN_LLM_TIMEOUT_MS), MAX_LLM_TIMEOUT_MS);
}

/** True when a fetch failed because the abort timer fired. */
function isAbort(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

async function postJson(
  url: string,
  headers: Record<string, string>,
  body: unknown,
  timeoutMs: number,
): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    // Read the body while the timer is still armed: a provider that answers
    // headers quickly but stalls the body must be cut off too.
    const text = await res.text();
    let parsed: unknown = null;
    try {
      parsed = text ? JSON.parse(text) : null;
    } catch {
      parsed = null;
    }
    if (!res.ok) {
      // Log the provider detail server side; never return it to the client.
      console.error(`[llm] provider HTTP ${res.status}:`, text.slice(0, 500));
      throw new AppError("LLM_UPSTREAM_ERROR", "The assistant is temporarily unavailable.", 502);
    }
    return parsed;
  } catch (error) {
    if (error instanceof AppError) throw error;
    // An abort is the timeout guard firing, not a generic upstream failure:
    // the caller uses the distinct code to decide whether a retry is worthwhile.
    if (isAbort(error)) {
      console.error(`[llm] provider timed out after ${timeoutMs}ms`);
      throw new AppError("LLM_TIMEOUT", "The assistant took too long to answer.", 504);
    }
    console.error("[llm] request failed:", error instanceof Error ? error.message : error);
    throw new AppError("LLM_UPSTREAM_ERROR", "The assistant is temporarily unavailable.", 502);
  } finally {
    clearTimeout(timer);
  }
}

function extractOpenAi(parsed: unknown): string {
  const choices = (parsed as { choices?: Array<{ message?: { content?: string } }> })?.choices;
  return choices?.[0]?.message?.content?.trim() ?? "";
}

function extractAnthropic(parsed: unknown): string {
  const blocks = (parsed as { content?: Array<{ type?: string; text?: string }> })?.content;
  if (!Array.isArray(blocks)) return "";
  return blocks.filter((b) => b.type === "text").map((b) => b.text ?? "").join("").trim();
}

function extractGemini(parsed: unknown): string {
  const candidates = (parsed as {
    candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
  })?.candidates;
  const parts = candidates?.[0]?.content?.parts;
  if (!Array.isArray(parts)) return "";
  return parts.map((p) => p.text ?? "").join("").trim();
}

/** One chat completion attempt, provider-agnostic. */
async function attemptChat(
  resolved: Resolved,
  messages: ChatMessage[],
  system: string,
  turns: ChatMessage[],
  timeoutMs: number,
): Promise<LlmResult> {
  let parsed: unknown;
  switch (resolved.provider) {
    case "openai":
    case "compatible": {
      parsed = await postJson(
        `${resolved.baseUrl}/chat/completions`,
        { Authorization: `Bearer ${resolved.apiKey}` },
        { model: resolved.model, messages, temperature: 0.3, max_tokens: 700,
          chat_template_kwargs: { enable_thinking: false } },
        timeoutMs,
      );
      const text = extractOpenAi(parsed);
      if (!text) throw new AppError("LLM_UPSTREAM_ERROR", "Empty assistant reply.", 502);
      return { text, provider: resolved.provider, model: resolved.model };
    }
    case "anthropic": {
      parsed = await postJson(
        `${resolved.baseUrl}/messages`,
        { "x-api-key": resolved.apiKey, "anthropic-version": "2023-06-01" },
        {
          model: resolved.model,
          system,
          messages: turns.map((m) => ({ role: m.role, content: m.content })),
          max_tokens: 700,
          temperature: 0.3,
        },
        timeoutMs,
      );
      const text = extractAnthropic(parsed);
      if (!text) throw new AppError("LLM_UPSTREAM_ERROR", "Empty assistant reply.", 502);
      return { text, provider: resolved.provider, model: resolved.model };
    }
    case "gemini": {
      parsed = await postJson(
        `${resolved.baseUrl}/models/${resolved.model}:generateContent?key=${resolved.apiKey}`,
        {},
        {
          systemInstruction: { parts: [{ text: system }] },
          contents: turns.map((m) => ({
            role: m.role === "assistant" ? "model" : "user",
            parts: [{ text: m.content }],
          })),
          generationConfig: { temperature: 0.3, maxOutputTokens: 700 },
        },
        timeoutMs,
      );
      const text = extractGemini(parsed);
      if (!text) throw new AppError("LLM_UPSTREAM_ERROR", "Empty assistant reply.", 502);
      return { text, provider: resolved.provider, model: resolved.model };
    }
  }
}

/**
 * One chat completion, provider-agnostic.
 *
 * A timeout or a transient upstream failure is retried once with the same
 * payload: the slow turns that were surfacing as errors are typically a cold
 * worker, and the second call usually lands on a warm one. A 4xx-class client
 * error is not retried, and the overall time stays bounded by two attempts.
 */
export async function completeChat(messages: ChatMessage[]): Promise<LlmResult> {
  const resolved = resolveLlm();
  if (!resolved) {
    throw new AppError("LLM_NOT_CONFIGURED", "The assistant is not configured.", 503);
  }

  const system = messages.filter((m) => m.role === "system").map((m) => m.content).join("\n\n");
  const turns = messages.filter((m) => m.role !== "system");
  const timeoutMs = requestTimeoutMs();

  let lastError: unknown;
  for (let attempt = 1; attempt <= LLM_MAX_ATTEMPTS; attempt++) {
    try {
      return await attemptChat(resolved, messages, system, turns, timeoutMs);
    } catch (error) {
      lastError = error;
      const retryable =
        error instanceof AppError &&
        (error.code === "LLM_TIMEOUT" || error.code === "LLM_UPSTREAM_ERROR");
      if (!retryable || attempt === LLM_MAX_ATTEMPTS) break;
      console.error(`[llm] attempt ${attempt} failed (${(error as AppError).code}); retrying`);
    }
  }
  throw lastError;
}
