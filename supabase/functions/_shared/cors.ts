// CORS = Cross-Origin Resource Sharing.
//
// Your site lives at https://konner1.github.io and this function lives at
// https://<ref>.supabase.co. Those are different "origins", and browsers
// refuse to let a page read a response from another origin unless that server
// opts in with these headers. Without them the call works but the browser
// hides the result and logs a CORS error.

export const corsHeaders = {
  // "*" lets any site call the function. That is safe here because the real
  // protection is the JWT check in auth.ts, not the origin.
  "Access-Control-Allow-Origin": "*",
  // Headers the browser is allowed to send. supabase-js sends these.
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Build a JSON response that always carries the CORS headers.
export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
