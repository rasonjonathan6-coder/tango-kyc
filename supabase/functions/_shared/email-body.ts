/**
 * Email body cleaning.
 *
 * Inbound mail arrives as HTML with headers, quoted history, legal disclaimers,
 * tracking pixels and provider metadata. The user dashboard must only ever show
 * the human part of the reply, as plain text, with no chance of HTML/XSS
 * injection. Everything here is pure and synchronous so it can be unit tested
 * without network access.
 */

const HEADER_LINE = /^(from|to|cc|bcc|subject|date|message-id|in-reply-to|references|received|return-path|dkim-signature|authentication-results|received-spf|arc-seal|arc-message-signature|arc-authentication-results|reply-to|mime-version|content-type|x-[\w-]+)\s*:/i;

/** Trailing content that is never part of the human reply. */
const SIGNATURE_MARKERS = [
  /^--\s*$/m,
  /^—\s*$/m,
  /^_{5,}$/m,
  /^={5,}$/m,
  /^-{5,}\s*original message\s*-{5,}/i,
  /^on .{5,120} wrote:\s*$/im,
  /^le .{5,120} a écrit\s*:\s*$/im,
  /^sent from my /im,
  /^envoyé depuis mon /im,
  /^get outlook for /im,
  /^this email (and any attachments )?(is|are) confidential/im,
  /^the information (contained )?in this (e-?mail|message)/im,
  /^please consider the environment/im,
];

const QUOTE_MARKERS = [
  /^-{2,}\s*original message\s*-{2,}/i,
  /^_{2,}\s*original message\s*_{2,}/i,
  /^on .{5,200} wrote:\s*$/im,
  /^le .{5,200} a écrit\s*:\s*$/im,
  /^>{1,}\s?/m,
  /^from:\s*.+$/im,
];

const BLOCK_TAGS_WITH_BREAK = [
  "p", "div", "br", "li", "ul", "ol", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6",
  "blockquote", "section", "article", "header", "footer", "pre",
];

/** Removes <script>/<style> payloads including their contents. */
function stripScriptAndStyle(html: string): string {
  return html
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<script\b[\s\S]*?<\/script>/gi, "")
    .replace(/<style\b[\s\S]*?<\/style>/gi, "")
    .replace(/<head\b[\s\S]*?<\/head>/gi, "")
    .replace(/<title\b[\s\S]*?<\/title>/gi, "");
}

const NAMED_ENTITIES: Record<string, string> = {
  nbsp: " ", amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", "#39": "'",
  ndash: "–", mdash: "—", hellip: "…", laquo: "«", raquo: "»",
  lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”", bull: "•", middot: "·",
  eacute: "é", egrave: "è", ecirc: "ê", agrave: "à", acirc: "â", ccedil: "ç",
  ugrave: "ù", ucirc: "û", icirc: "î", iuml: "ï", ocirc: "ô", oelig: "œ",
  Aacute: "Á", Eacute: "É", grave: "`", deg: "°", euro: "€", pound: "£",
  times: "×", divide: "÷", auml: "ä", ouml: "ö", uuml: "ü", szlig: "ß",
  copy: "©", reg: "®", trade: "™", permil: "‰", sect: "§", para: "¶",
};

/**
 * Decodes HTML entities. Runs before tag stripping would be unsafe on its own,
 * so it is paired with a second tag-stripping pass in `htmlToText`.
 */
function decodeEntities(input: string): string {
  return input
    .replace(/&#(\d+);/g, (_m, d: string) => {
      const code = Number(d);
      return code > 0 && code < 0x110000 ? String.fromCodePoint(code) : " ";
    })
    .replace(/&#x([0-9a-f]+);/gi, (_m, h: string) => {
      const code = parseInt(h, 16);
      return code > 0 && code < 0x110000 ? String.fromCodePoint(code) : " ";
    })
    .replace(/&([a-z][a-z0-9]*|#39);/gi, (match, name: string) =>
      Object.prototype.hasOwnProperty.call(NAMED_ENTITIES, name)
        ? NAMED_ENTITIES[name]
        : match
    );
}

/** Removes any tag-looking sequence, repeatedly, so nesting cannot survive. */
function stripAllTags(input: string): string {
  let out = input;
  let previous = "";
  while (out !== previous) {
    previous = out;
    out = out.replace(/<[^>]*>?/g, "");
  }
  return out;
}

/** Converts an HTML document fragment into readable plain text. */
export function htmlToText(html: string): string {
  let out = stripScriptAndStyle(html);

  // Links become "label (url)" or just the url when the label is the url.
  out = out.replace(/<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi, (_m, href, label) => {
    const text = stripAllTags(String(label)).trim();
    if (!text || text === href) return ` ${href} `;
    return ` ${text} (${href}) `;
  });

  for (const tag of BLOCK_TAGS_WITH_BREAK) {
    out = out.replace(new RegExp(`<${tag}\\b[^>]*>`, "gi"), "\n");
    out = out.replace(new RegExp(`</${tag}>`, "gi"), "\n");
  }

  out = stripAllTags(out);

  // Entities are decoded before the final strip pass: a payload such as
  // "&lt;script&gt;" must not be turned back into live markup.
  out = decodeEntities(out);
  out = stripAllTags(out);

  return out;
}

/** Collapses whitespace while preserving paragraph structure. */
function normalizeWhitespace(text: string): string {
  return text
    .replace(/\r\n?/g, "\n")
    .replace(/\u00a0/g, " ")
    .replace(/[ \t]+/g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .split("\n")
    .map((line) => line.trim())
    .join("\n")
    .trim();
}

/** Drops a leading RFC 5322 style header block, if present. */
export function stripHeaders(text: string): string {
  const lines = text.split("\n");
  let index = 0;
  let sawHeader = false;

  while (index < lines.length) {
    const line = lines[index];
    if (line.trim() === "") {
      if (sawHeader) {
        index += 1; // consume the blank line separating headers from the body
      }
      break;
    }
    if (HEADER_LINE.test(line) || /^\s+\S/.test(line) === (sawHeader && /^\s/.test(line))) {
      if (HEADER_LINE.test(line)) sawHeader = true;
      if (!sawHeader && !/^\s/.test(line)) break;
      index += 1;
      continue;
    }
    break;
  }

  return sawHeader ? lines.slice(index).join("\n") : text;
}

/** True when a line looks like a quoted previous message rather than a reply. */
function isQuoteLine(line: string): boolean {
  return /^\s*>/.test(line);
}

/**
 * Cuts the message at the first sign of quoted history or a signature block.
 * Only the first occurrence is used so that legitimate "-- " text in a body
 * does not truncate the whole message.
 */
export function stripQuotedHistory(text: string): string {
  let cut = text.length;

  for (const marker of SIGNATURE_MARKERS) {
    const match = marker.exec(text);
    if (match && match.index > 0 && match.index < cut) {
      cut = match.index;
    }
  }

  for (const marker of QUOTE_MARKERS) {
    if (marker.source.startsWith("^{1,}")) continue;
    const match = marker.exec(text);
    if (match && match.index > 0 && match.index < cut) {
      cut = match.index;
    }
  }

  let result = text.slice(0, cut);

  // Remove any residual quoted lines, but only a trailing run.
  const lines = result.split("\n");
  let end = lines.length;
  while (end > 0 && (lines[end - 1].trim() === "" || isQuoteLine(lines[end - 1]))) {
    if (lines[end - 1].trim() !== "" && !isQuoteLine(lines[end - 1])) break;
    end -= 1;
  }
  if (end < lines.length && lines.slice(end).some(isQuoteLine)) {
    result = lines.slice(0, end).join("\n");
  }

  return result;
}

export interface CleanReplyOptions {
  /** Provider metadata that must never reach the dashboard. */
  dropLines?: string[];
}

/**
 * Full pipeline: HTML or text in, clean human-readable plain text out.
 * This is the function the webhook stores in `messages.body`.
 */
export function extractCleanReplyBody(
  raw: { html?: string | null; text?: string | null },
  options: CleanReplyOptions = {},
): string {
  let body = "";

  const text = (raw.text ?? "").trim();
  const html = (raw.html ?? "").trim();

  if (text) {
    // Respect the plain-text alternative when it carries real content.
    body = text;
  } else if (html) {
    body = htmlToText(html);
  }

  if (!body) return "";

  body = stripHeaders(body);
  body = normalizeWhitespace(body);
  body = stripQuotedHistory(body);
  body = normalizeWhitespace(body);

  if (options.dropLines?.length) {
    const drop = options.dropLines.map((l) => l.toLowerCase());
    body = body
      .split("\n")
      .filter((line) => !drop.includes(line.trim().toLowerCase()))
      .join("\n");
    body = normalizeWhitespace(body);
  }

  return body;
}

/**
 * Defence in depth for the dashboard: ensures nothing that could be interpreted
 * as markup survives, and bounds the stored size.
 */
export function sanitizeForStorage(body: string, maxLength = 20000): string {
  const stripped = body
    .replace(/<[^>]*>/g, "")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "");
  const cleaned = normalizeWhitespace(stripped);
  return cleaned.length > maxLength ? cleaned.slice(0, maxLength) : cleaned;
}
