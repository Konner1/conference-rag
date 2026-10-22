// Manual JWT verification.
//
// We deploy with --no-verify-jwt, so Supabase does NOT check the caller for us.
// That means this file is the only thing standing between the public internet
// and your OpenAI bill. If it is wrong, anyone can spend your credits.
//
// How login works: when a user clicks the magic link, Supabase Auth gives the
// browser a JWT (a signed token that says "this is user X"). supabase-js sends
// it on every call as:   Authorization: Bearer <jwt>
// We ask Supabase Auth to validate that token and tell us who it belongs to.

import { createClient, type User } from "https://esm.sh/@supabase/supabase-js@2";

export class AuthError extends Error {}

export async function requireUser(req: Request): Promise<User> {
  const header = req.headers.get("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!token) throw new AuthError("Missing bearer token");

  // SUPABASE_URL and SUPABASE_ANON_KEY are injected into every Edge Function
  // automatically. The anon key is fine here: we only ask Auth to validate a
  // token, we are not reading any protected table.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
  );

  // getUser(token) makes Supabase Auth verify the signature and expiry.
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) throw new AuthError("Invalid or expired token");

  // The anon key itself is also sent as a bearer token by logged-out visitors.
  // It validates as a JWT but has no user, so getUser rejects it above. That is
  // exactly what we want: only real logged-in users get through.
  return data.user;
}
