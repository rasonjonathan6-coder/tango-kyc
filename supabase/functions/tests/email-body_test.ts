/**
 * Unit tests for the email body cleaner.
 *
 * Run with:  deno test --allow-env supabase/functions/tests/email-body_test.ts
 */
import { assertEquals, assertStringIncludes, assert } from "jsr:@std/assert@1.0.6";
import {
  extractCleanReplyBody,
  htmlToText,
  sanitizeForStorage,
  stripHeaders,
  stripQuotedHistory,
} from "../_shared/email-body.ts";

Deno.test("htmlToText converts markup to readable text", () => {
  const html = "<p>Hello,</p><p>Your request has been <strong>reviewed</strong>.</p>";
  assertEquals(htmlToText(html).replace(/\n+/g, " ").trim(), "Hello, Your request has been reviewed.");
});

Deno.test("htmlToText keeps link targets", () => {
  const text = htmlToText('<p>Please use the following link: <a href="https://tango.example/v/1">open it</a></p>');
  assertStringIncludes(text, "https://tango.example/v/1");
  assertStringIncludes(text, "open it");
});

Deno.test("htmlToText strips scripts and styles with their contents", () => {
  const html = '<style>body{color:red}</style><script>alert("xss")</script><p>Real content</p>';
  const text = htmlToText(html);
  assertEquals(text.includes("alert"), false);
  assertEquals(text.includes("color:red"), false);
  assertStringIncludes(text, "Real content");
});

Deno.test("htmlToText decodes entities", () => {
  const text = htmlToText("<p>Ben &amp; Co &#8212; caf&eacute;</p>");
  assertStringIncludes(text, "Ben & Co");
  assertStringIncludes(text, "café");
});

Deno.test("stripHeaders removes an RFC 5322 header block", () => {
  const raw = [
    "From: Admin <tangoturq@gmail.com>",
    "To: reply+abc@inbound.resend.app",
    "Subject: Re: Manual KYC Verification request",
    "Date: Thu, 25 Sep 2026 14:00:00 +0000",
    "Message-ID: <abc@mail.gmail.com>",
    "DKIM-Signature: v=1; a=rsa-sha256; d=gmail.com",
    "",
    "Hello,",
    "",
    "Your verification request has been reviewed.",
  ].join("\n");

  const body = stripHeaders(raw);
  assertEquals(body.includes("DKIM-Signature"), false);
  assertEquals(body.includes("Message-ID"), false);
  assertStringIncludes(body, "Your verification request has been reviewed.");
});

Deno.test("stripQuotedHistory cuts quoted replies", () => {
  const raw = [
    "Thanks, I have reviewed it.",
    "",
    "On Thu, 25 Sep 2026 at 10:00, Tango Support wrote:",
    "> Hello support tango team,",
    "> I am requesting a manual review.",
  ].join("\n");

  const body = stripQuotedHistory(raw);
  assertEquals(body.includes("I am requesting a manual review"), false);
  assertStringIncludes(body, "Thanks, I have reviewed it.");
});

Deno.test("stripQuotedHistory cuts at a signature delimiter", () => {
  const raw = [
    "The link is https://tango.example/verify/42",
    "",
    "-- ",
    "Best regards,",
    "Tango Support Team",
  ].join("\n");

  const body = stripQuotedHistory(raw);
  assertStringIncludes(body, "https://tango.example/verify/42");
  assertEquals(body.includes("Best regards"), false);
});

Deno.test("extractCleanReplyBody prefers the text part and cleans it", () => {
  const body = extractCleanReplyBody({
    text: [
      "From: Admin <tangoturq@gmail.com>",
      "Subject: Re: KYC",
      "",
      "Hello,",
      "",
      "Your verification request has been reviewed.",
      "",
      "Please use the following link:",
      "https://tango.example/verify/42",
      "",
      "On Thu, 25 Sep 2026, Tango KYC wrote:",
      "> original request",
    ].join("\n"),
    html: "<p>ignored when text is present</p>",
  });

  assertStringIncludes(body, "Your verification request has been reviewed.");
  assertStringIncludes(body, "https://tango.example/verify/42");
  assertEquals(body.includes("From:"), false);
  assertEquals(body.includes("Subject:"), false);
  assertEquals(body.includes("original request"), false);
  assertEquals(body.includes("<p>"), false);
});

Deno.test("extractCleanReplyBody falls back to HTML when no text part exists", () => {
  const body = extractCleanReplyBody({
    text: null,
    html: "<div><p>Hello,</p><p>Your verification request has been reviewed.</p>" +
      "<p>Please use the following link:<br><a href=\"https://tango.example/verify/7\">Verify now</a></p></div>",
  });

  assertStringIncludes(body, "Your verification request has been reviewed.");
  assertStringIncludes(body, "https://tango.example/verify/7");
  assertEquals(body.includes("<div>"), false);
  assertEquals(body.includes("<a href"), false);
});

Deno.test("extractCleanReplyBody never returns markup for a hostile payload", () => {
  const body = extractCleanReplyBody({
    text: null,
    html: '<p>Hi</p><img src=x onerror="alert(1)"><script>steal()</script>' +
      '<iframe src="https://evil.example"></iframe><p>&lt;script&gt;alert(2)&lt;/script&gt;</p>' +
      "<p><svg/onload=alert(3)></p>",
  });

  assertEquals(body.includes("<"), false);
  assertEquals(body.includes(">"), false);
  assertEquals(body.includes("onerror"), false);
  assertEquals(body.includes("onload"), false);
  assertEquals(body.includes("steal()"), false);
  assertStringIncludes(body, "Hi");
});

Deno.test("entity-encoded markup cannot survive as live tags", () => {
  // A payload that only becomes markup after entity decoding must be neutralised.
  const body = extractCleanReplyBody({
    text: null,
    html: "<p>&amp;lt;script&amp;gt;alert(1)&amp;lt;/script&amp;gt;</p><p>Your request was reviewed.</p>",
  });
  assertEquals(body.includes("<script"), false);
  assertStringIncludes(body, "Your request was reviewed.");
});

Deno.test("extractCleanReplyBody returns empty string for an empty message", () => {
  assertEquals(extractCleanReplyBody({ html: null, text: null }), "");
  assertEquals(extractCleanReplyBody({ html: "   ", text: "" }), "");
});

Deno.test("sanitizeForStorage removes leftover markup and control characters", () => {
  const value = sanitizeForStorage("<b>Hello</b>\u0000\u0007 world<script>x</script>");
  assertEquals(value.includes("<"), false);
  assertEquals(value.includes("\u0000"), false);
  assertStringIncludes(value, "Hello");
  assertStringIncludes(value, "world");
});

Deno.test("sanitizeForStorage enforces a maximum length", () => {
  const value = sanitizeForStorage("a".repeat(50), 10);
  assertEquals(value.length, 10);
});

Deno.test("extractCleanReplyBody preserves non-English content", () => {
  const body = extractCleanReplyBody({
    text: "Bonjour,\n\nVotre demande de vérification a été examinée.\n\nCordialement,",
  });
  assertStringIncludes(body, "Votre demande de vérification a été examinée.");
  assert(body.length > 0);
});
