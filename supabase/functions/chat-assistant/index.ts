/**
 * POST /functions/v1/chat-assistant
 *
 * The authenticated user's chatbot turn against the Tango KYC assistant.
 *
 * Why an Edge Function rather than calling the LLM from the app:
 *   * the provider API key is a server secret and must never ship in the
 *     Flutter binary;
 *   * the system prompt and the knowledge base stay server-side, so they cannot
 *     be read or tampered with by the client;
 *   * the guardrails run server-side, after the model answers, so a leak is
 *     caught even if the model is manipulated.
 *
 * Request body: { messages: [{ role: "user" | "assistant", content: string }] }
 * Response:     { reply: string, provider: string, model: string }
 *               or { configured: false, reply: <honest notice> } when no key.
 */
import {
  ASSISTANT_SAFE_FALLBACK,
  ASSISTANT_UNAVAILABLE_MESSAGE,
  replyLeaksInternals,
  TANGO_KYC_SYSTEM_PROMPT,
} from "../_shared/chatbot.ts";
import { completeChat, llmConfigured, type ChatMessage } from "../_shared/llm.ts";
import { AppError, errorResponse, handlePreflight, jsonResponse } from "../_shared/http.ts";
import { requireUser } from "../_shared/clients.ts";

/** Bounds so one caller cannot drive unbounded cost or context. */
const MAX_MESSAGES = 20;
const MAX_MESSAGE_CHARS = 2000;

interface Incoming {
  messages?: unknown;
}

/** Keeps only well-formed turns, trims them, and caps the history length. */
function parseMessages(raw: unknown): ChatMessage[] {
  if (!Array.isArray(raw)) throw new AppError("MESSAGE_REQUIRED", "Missing messages", 422);
  const turns: ChatMessage[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const role = (item as { role?: unknown }).role;
    const content = (item as { content?: unknown }).content;
    if (role !== "user" && role !== "assistant") continue;
    if (typeof content !== "string") continue;
    const trimmed = content.trim();
    if (!trimmed) continue;
    turns.push({ role, content: trimmed.slice(0, MAX_MESSAGE_CHARS) });
  }
  if (turns.length === 0) throw new AppError("MESSAGE_REQUIRED", "Empty conversation", 422);
  if (turns[turns.length - 1].role !== "user") {
    throw new AppError("MESSAGE_REQUIRED", "The last message must be from the user", 422);
  }
  return turns.slice(-MAX_MESSAGES);
}

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "METHOD_NOT_ALLOWED", message: "Use POST." }, 405);
  }

  try {
    // Authenticated only: the assistant is a signed-in feature, so its cost
    // cannot be driven anonymously.
    await requireUser(req);

    let payload: Incoming;
    try {
      payload = await req.json();
    } catch {
      throw new AppError("MESSAGE_REQUIRED", "Malformed JSON body", 422);
    }

    const turns = parseMessages(payload.messages);

    // No provider key: answer honestly, do not fabricate.
    if (!llmConfigured()) {
      return jsonResponse({
        configured: false,
        reply: ASSISTANT_UNAVAILABLE_MESSAGE,
      });
    }

    const messages: ChatMessage[] = [
      { role: "system", content: TANGO_KYC_SYSTEM_PROMPT },
      ...turns,
    ];

    const result = await completeChat(messages);
    const reply = replyLeaksInternals(result.text) ? ASSISTANT_SAFE_FALLBACK : result.text;

    return jsonResponse({
      configured: true,
      reply,
      provider: result.provider,
      model: result.model,
    });
  } catch (error) {
    return errorResponse(error);
  }
});
