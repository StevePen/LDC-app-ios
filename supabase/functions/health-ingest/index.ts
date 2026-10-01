import { createClient } from "npm:@supabase/supabase-js@2";

// Receives JSON posts from the iPhone Health exporter (LDC fork).
// Auth: x-ingest-token header, SHA-256 hashed and checked against public.ingest_tokens.
// Stores the untouched body in public.health_payloads.

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });

  const token = req.headers.get("x-ingest-token");
  if (!token) return json(401, { error: "missing token" });

  const tokenHash = await sha256Hex(token);
  const { data: match, error: tokenError } = await supabase
    .from("ingest_tokens")
    .select("id")
    .eq("token_hash", tokenHash)
    .is("revoked_at", null)
    .maybeSingle();

  if (tokenError) return json(500, { error: "token lookup failed" });
  if (!match) return json(401, { error: "invalid token" });

  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return json(400, { error: "body must be JSON" });
  }

  // Keep request headers for debugging, minus the token
  const headers: Record<string, string> = {};
  req.headers.forEach((value, key) => {
    if (key.toLowerCase() !== "x-ingest-token") headers[key] = value;
  });

  const { data, error } = await supabase
    .from("health_payloads")
    .insert({ headers, payload })
    .select("id")
    .single();

  if (error) return json(500, { error: "insert failed", detail: error.message });
  return json(200, { ok: true, id: data.id });
});
