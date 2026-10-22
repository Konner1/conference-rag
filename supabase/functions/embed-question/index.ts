// embed-question
//
// Browser -> this function -> OpenAI -> browser
//
// Input:  POST { "question": "How can I find peace?" }
// Output: { "embedding": [ ...1536 numbers... ] }
//
// The browser then sends that vector to the database's match_paragraphs()
// function to find the closest paragraphs.
//
// Why not call OpenAI straight from the browser? Anything in browser code can
// be read by anyone who opens dev tools, so the OpenAI key would leak. Here the
// key lives only in Supabase secrets (OPENAI_API_KEY) and never leaves the server.

import { corsHeaders, json } from "../_shared/cors.ts";
import { AuthError, requireUser } from "../_shared/auth.ts";
import { enforceRateLimit } from "../_shared/ratelimit.ts";

const MAX_QUESTION_CHARS = 1000; // cap input so nobody can burn tokens on huge text
const RATE_LIMIT = 120;          // embeddings per user per hour (cheap: ~$0.00002 each)
const RATE_WINDOW_SECONDS = 3600;

Deno.serve(async (req: Request) => {
  // Browsers send an OPTIONS "preflight" request before a cross-origin POST.
  // Answer it with the CORS headers and nothing else.
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  // 1. Who is calling? Reject before doing anything that costs money.
  let user;
  try {
    user = await requireUser(req);
  } catch (e) {
    if (e instanceof AuthError) return json({ error: e.message }, 401);
    return json({ error: "Auth check failed" }, 500);
  }

  // 1b. Is this user still within their hourly quota?
  const limited = await enforceRateLimit(user.id, "embed-question", RATE_LIMIT, RATE_WINDOW_SECONDS);
  if (limited) return limited;

  // 2. Validate the input.
  let question: unknown;
  try {
    ({ question } = await req.json());
  } catch {
    return json({ error: "Body must be JSON" }, 400);
  }
  if (typeof question !== "string" || question.trim() === "") {
    return json({ error: "question must be a non-empty string" }, 400);
  }
  if (question.length > MAX_QUESTION_CHARS) {
    return json({ error: `question must be under ${MAX_QUESTION_CHARS} characters` }, 400);
  }

  // 3. Call OpenAI. This must be the same model we used for the stored
  //    paragraphs, otherwise the vectors live in different "spaces" and the
  //    similarity numbers mean nothing.
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) return json({ error: "Server is missing OPENAI_API_KEY" }, 500);

  const res = await fetch("https://api.openai.com/v1/embeddings", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "text-embedding-3-small",
      input: question.trim(),
    }),
  });

  if (!res.ok) {
    // Log the detail on the server, but do not send OpenAI's error text to the
    // browser: it can reveal account or key information.
    console.error("OpenAI error", res.status, await res.text());
    return json({ error: "Failed to get embedding" }, 502);
  }

  const data = await res.json();
  return json({ embedding: data.data[0].embedding });
});
