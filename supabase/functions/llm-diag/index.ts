// TEMPORARY diagnostic function. Deleted immediately after use.
// Probes several candidate models with the configured key and returns only
// the upstream HTTP status and a redacted error body for each.
const CANDIDATES = [
  "nvidia/llama-3.1-nemotron-70b-instruct",
  "nvidia/llama-3.1-nemotron-51b-instruct",
  "nvidia/llama-3.1-nemotron-ultra-253b-v1",
  "nvidia/nemotron-3.5-lightning-30b-a3b",
  "nvidia/nemotron-nano-3-30b-a3b",
  "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning",
  "nvidia/nemotron-3-ultra-550b-a55b",
  "meta/llama-3.3-70b-instruct",
  "nvidia/llama-3.3-nemotron-super-49b-v1.5",
];

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const only = url.searchParams.get("model");
  const base = (Deno.env.get("LLM_BASE_URL") ?? "").replace(/\/$/, "");
  const key = Deno.env.get("LLM_API_KEY") ?? "";
  const configuredModel = Deno.env.get("LLM_MODEL") ?? "";

  if (!base || !key) {
    return Response.json({ error: "NOT_CONFIGURED", baseUrlSet: base.length > 0, keyPresent: key.length > 0 }, { status: 500 });
  }

  const models = only ? [only] : CANDIDATES;
  const out = [];
  for (const model of models) {
    try {
      const res = await fetch(`${base}/chat/completions`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
        body: JSON.stringify({ model, messages: [{ role: "user", content: "ping" }], max_tokens: 8 }),
      });
      const text = await res.text();
      let snippet = text.split(key).join("<redacted>").slice(0, 220);
      try {
        const j = JSON.parse(text);
        const content = j?.choices?.[0]?.message?.content;
        snippet = content ? `OK: ${content.slice(0, 120)}` : (j?.detail || j?.title || snippet);
      } catch { /* keep raw */ }
      out.push({ model, status: res.status, body: snippet });
    } catch (e) {
      out.push({ model, status: 0, body: e instanceof Error ? e.message : String(e) });
    }
  }
  return Response.json({ configuredModel, results: out });
});
