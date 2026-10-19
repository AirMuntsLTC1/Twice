import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};

function reply(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers });
}

function normalizeEmail(v: unknown): string {
  return typeof v === "string" ? v.trim().toLowerCase() : "";
}

function validEmail(email: string): boolean {
  return email.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

function randomCode(): string {
  // Rejection sampling avoids modulo bias.
  const limit = Math.floor(0x100000000 / 1_000_000) * 1_000_000;
  const values = new Uint32Array(1);
  do crypto.getRandomValues(values); while (values[0] >= limit);
  return String(values[0] % 1_000_000).padStart(6, "0");
}

async function hmac(value: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function refreshGoogleToken(
  clientId: string,
  clientSecret: string,
  refreshToken: string,
): Promise<string> {
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    }),
  });
  const result = await response.json();
  if (!response.ok || typeof result.access_token !== "string") {
    console.error("Gmail token refresh failed:", result.error ?? response.status);
    throw new Error("Gmail sender unavailable");
  }
  return result.access_token;
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

async function sendCode(
  email: string,
  code: string,
  sender: string,
  accessToken: string,
): Promise<void> {
  const subject = "Your Twice verification code";
  const body =
    `Your Twice verification code is ${code}.\r\n\r\n` +
    "It expires in 5 minutes. If you did not request this code, ignore this email.";
  const raw = [
    `From: Twice <${sender}>`,
    `To: ${email}`,
    `Subject: ${subject}`,
    "MIME-Version: 1.0",
    'Content-Type: text/plain; charset="UTF-8"',
    "Content-Transfer-Encoding: base64",
    "",
    btoa(unescape(encodeURIComponent(body))),
  ].join("\r\n");

  const response = await fetch(
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        raw: base64Url(new TextEncoder().encode(raw)),
      }),
    },
  );

  if (!response.ok) {
    console.error("Gmail send failed with HTTP", response.status);
    throw new Error("Email delivery failed");
  }
}

async function findUserByEmail(
  supabase: ReturnType<typeof createClient>,
  email: string,
) {
  for (let page = 1; page <= 100; page++) {
    const { data, error } = await supabase.auth.admin.listUsers({
      page,
      perPage: 1000,
    });
    if (error) throw new Error("Account lookup failed");
    const user = data.users.find((u) => u.email?.toLowerCase() === email);
    if (user) return user;
    if (data.users.length < 1000) return null;
  }
  throw new Error("Account lookup reached its safety limit");
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const hashSecret = Deno.env.get("OTP_HASH_SECRET");
  const googleClientId = Deno.env.get("GOOGLE_CLIENT_ID");
  const googleClientSecret = Deno.env.get("GOOGLE_CLIENT_SECRET");
  const googleRefreshToken = Deno.env.get("GOOGLE_REFRESH_TOKEN");
  const sender = normalizeEmail(Deno.env.get("GOOGLE_SENDER_EMAIL"));

  if (!supabaseUrl || !serviceKey || !hashSecret || hashSecret.length < 32 ||
      !googleClientId || !googleClientSecret || !googleRefreshToken ||
      !validEmail(sender)) {
    return reply({ error: "Server authentication configuration is incomplete" }, 500);
  }

  let input: Record<string, unknown>;
  try {
    const parsed = await req.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return reply({ error: "Invalid request" }, 400);
    }
    input = parsed as Record<string, unknown>;
  } catch {
    return reply({ error: "Invalid JSON" }, 400);
  }

  const action = input.action;
  const email = normalizeEmail(input.email);
  if (!validEmail(email)) return reply({ error: "Enter a valid email address" }, 400);

  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    if (action === "send_code") {
      const username = typeof input.username === "string" ? input.username.trim() : "";
      const displayName = typeof input.display_name === "string"
        ? input.display_name.trim()
        : "";

      if (username.length > 30 || displayName.length > 80 ||
          (username && !/^[a-zA-Z0-9_]{3,30}$/.test(username))) {
        return reply({ error: "Check your username and display name" }, 400);
      }

      // Reserve the 60-second cooldown atomically before sending.
      // If delivery fails, remove this reservation so the user can retry.
      const code = randomCode();
      const codeHash = await hmac(`${email}:${code}`, hashSecret);
      const expiresAt = new Date(Date.now() + 5 * 60_000).toISOString();
      const metadata = { username, display_name: displayName };

      const { data: reserved, error: reserveError } = await supabase.rpc(
        "twice_issue_email_code",
        {
          p_email: email,
          p_code_hash: codeHash,
          p_expires_at: expiresAt,
          p_metadata: metadata,
        },
      );
      if (reserveError) throw new Error("Verification storage is not ready");
      if (reserved !== true) {
        return reply({ error: "Please wait before requesting another code" }, 429);
      }

      try {
        const accessToken = await refreshGoogleToken(
          googleClientId,
          googleClientSecret,
          googleRefreshToken,
        );
        await sendCode(email, code, sender, accessToken);
      } catch (error) {
        // Delete only our reservation; do not remove a newer code created later.
        await supabase.from("email_verification_codes")
          .delete()
          .eq("email", email)
          .eq("code_hash", codeHash);
        throw error;
      }

      return reply({
        ok: true,
        message: "If this address can receive mail, a verification code has been sent.",
      });
    }

    if (action === "verify_code") {
      const code = typeof input.code === "string" ? input.code.trim() : "";
      if (!/^\d{6}$/.test(code)) {
        return reply({ error: "Enter the six-digit code" }, 400);
      }

      // Read metadata before consuming the code; the atomic RPC prevents
      // two concurrent requests from consuming the same code successfully.
      const { data: row, error: readError } = await supabase
        .from("email_verification_codes")
        .select("user_metadata, expires_at, attempts")
        .eq("email", email)
        .maybeSingle();

      if (readError) throw new Error("Verification lookup failed");
      if (!row || Date.parse(row.expires_at) <= Date.now() || row.attempts >= 5) {
        return reply({ error: "Code is invalid or expired. Request a new code." }, 400);
      }

      const suppliedHash = await hmac(`${email}:${code}`, hashSecret);
      const { data: consumed, error: consumeError } = await supabase.rpc(
        "twice_consume_email_code",
        { p_email: email, p_code_hash: suppliedHash },
      );
      if (consumeError) throw new Error("Verification check failed");
      if (consumed !== true) {
        return reply({ error: "Code is incorrect or expired" }, 400);
      }

      const metadata = row.user_metadata ?? {};
      let user = await findUserByEmail(supabase, email);

      if (!user) {
        const requested = String(metadata.username || email.split("@")[0])
          .toLowerCase().replace(/[^a-z0-9_]/g, "").slice(0, 30);
        const username = requested.length >= 3
          ? requested
          : `user_${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}`;

        const created = await supabase.auth.admin.createUser({
          email,
          email_confirm: true,
          user_metadata: {
            username,
            display_name: String(metadata.display_name || ""),
          },
        });

        if (created.error || !created.data.user) {
          // A concurrent signup may have created this email; re-check.
          user = await findUserByEmail(supabase, email);
          if (!user) throw new Error("Account creation failed");
        } else {
          user = created.data.user;
        }
      }

      const link = await supabase.auth.admin.generateLink({
        type: "magiclink",
        email,
      });
      if (link.error || !link.data.properties?.hashed_token) {
        throw new Error("Sign-in token generation failed");
      }

      return reply({
        ok: true,
        token_hash: link.data.properties.hashed_token,
        verify_type: "magiclink",
        user_id: user.id,
      });
    }

    return reply({ error: "Unknown action. Use send_code or verify_code." }, 400);
  } catch (error) {
    console.error(
      "twice-email-code:",
      error instanceof Error ? error.message : "unknown error",
    );
    return reply({ error: "Authentication request failed. Please try again." }, 500);
  }
});
