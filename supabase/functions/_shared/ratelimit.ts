// Per-user rate limiting for the Edge Functions.
//
// Auth only proves WHO is calling. It does not stop a logged-in user (or a stolen
// token) from calling the function thousands of times and spending your OpenAI
// credits. This counts calls per user per function in Postgres
// (rate_limit_hit in the migrations) and says no once the limit is reached.
//
// The counter table can only be touched with the service_role key, which is
// injected into every Edge Function as SUPABASE_SERVICE_ROLE_KEY. It never
// reaches the browser.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "./cors.ts";

export async function enforceRateLimit(
  userId: string,
  fn: string,
  limit: number,
  windowSeconds: number,
): Promise<Response | null> {
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: allowed, error } = await admin.rpc("rate_limit_hit", {
    p_user: userId,
    p_fn: fn,
    p_limit: limit,
    p_window_seconds: windowSeconds,
  });

  // Fail closed: if we cannot count, refuse rather than risk unlimited spend.
  if (error) {
    console.error("rate limit check failed", error.message);
    return new Response(JSON.stringify({ error: "Rate limit check failed" }), {
      status: 503,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (!allowed) {
    return new Response(
      JSON.stringify({ error: "Too many requests. Please try again later." }),
      {
        status: 429,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
          "Retry-After": String(windowSeconds),
        },
      },
    );
  }

  return null; // within the limit: carry on
}
