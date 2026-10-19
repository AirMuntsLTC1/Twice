import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const SCOPE = "https://www.googleapis.com/auth/gmail.send";
const REDIRECT_URI = "https://jgqxvqlwnfywzoxbfkpk.supabase.co/functions/v1/twice-google-oauth";

function page(message: string, status = 200) {
  return new Response(
    `<!doctype html><meta name="viewport" content="width=device-width"><title>Twice Gmail setup</title><h2>Twice Gmail setup</h2>${message}`,
    { status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } },
  );
}


function base64url(bytes: Uint8Array) {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function fromBase64url(value: string) {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const binary = atob(normalized + "=".repeat((4 - normalized.length % 4) % 4));
  return Uint8Array.from(binary, c => c.charCodeAt(0));
}

async function signState(payload: string, secret: string) {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  return base64url(new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload)),
  ));
}

async function validState(state: string, secret: string) {
  const parts = state.split(".");
  if (parts.length !== 3) return false;
  const [timestampText, nonce, signature] = parts;
  if (!/^\d+$/.test(timestampText) || !/^[A-Za-z0-9_-]{20,}$/.test(nonce)) return false;

  const timestamp = Number(timestampText);
  const now = Math.floor(Date.now() / 1000);
  if (!Number.isSafeInteger(timestamp) || timestamp > now + 30 || now - timestamp > 600) return false;

  const payload = `${timestampText}.${nonce}`;
  const expected = await signState(payload, secret);
  const a = new TextEncoder().encode(expected);
  const b = new TextEncoder().encode(signature);
  if (a.length !== b.length) return false;

  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function createState(secret: string) {
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const nonceBytes = crypto.getRandomValues(new Uint8Array(24));
  const nonce = base64url(nonceBytes);
  const payload = `${timestamp}.${nonce}`;
  return `${payload}.${await signState(payload, secret)}`;
}

serve(async (req) => {
  const url = new URL(req.url);
  const clientId = Deno.env.get("GOOGLE_CLIENT_ID");
  const clientSecret = Deno.env.get("GOOGLE_CLIENT_SECRET");
  const stateSecret = Deno.env.get("GOOGLE_OAUTH_STATE_SECRET");

  if (!clientId || !clientSecret || !stateSecret) {
    return page("Missing GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, or GOOGLE_OAUTH_STATE_SECRET in Supabase Secrets.", 500);
  }

  const redirectUri = REDIRECT_URI;

  if (url.searchParams.get("action") === "authorize") {
    const state = await createState(stateSecret);
    const authUrl = new URL(AUTH_URL);
    authUrl.searchParams.set("client_id", clientId);
    authUrl.searchParams.set("redirect_uri", redirectUri);
    authUrl.searchParams.set("response_type", "code");
    authUrl.searchParams.set("scope", SCOPE);
    authUrl.searchParams.set("access_type", "offline");
    authUrl.searchParams.set("prompt", "consent");
    authUrl.searchParams.set("state", state);

    return new Response(null, {
      status: 302,
      headers: {
        location: authUrl.toString(),
        "cache-control": "no-store",
      },
    });
  }

  const error = url.searchParams.get("error");
  if (error) return page("Google authorization was cancelled or denied. You can close this page.", 400);

  const code = url.searchParams.get("code");
  if (!code) return page('Open this function URL with <code>?action=authorize</code> to begin setup.');

  const state = url.searchParams.get("state");
  if (!state || !(await validState(state, stateSecret))) {
    return page("OAuth state validation failed or expired. Restart from the authorization URL and complete consent within 10 minutes.", 403);
  }

  const tokenResponse = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: clientId,
      client_secret: clientSecret,
      redirect_uri: redirectUri,
      grant_type: "authorization_code",
    }),
  });

  const tokens = await tokenResponse.json();
  if (!tokenResponse.ok) {
    console.error("Google token exchange failed:", tokens.error);
    return new Response("Google token exchange failed. Check your OAuth client and redirect URI.", {
      status: 400,
      headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
    });
  }

  if (!tokens.refresh_token) {
    return new Response("No refresh token returned. Revoke prior access for this app in your Google Account, then restart consent.", {
      status: 400,
      headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
    });
  }

  // This temporary setup function reveals the token only to the browser
  // completing the state-validated OAuth flow. Save it as a Supabase secret,
  // then remove this setup function from public access.
  const escaped = String(tokens.refresh_token).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
  return new Response(
    `<!doctype html><meta name="viewport" content="width=device-width"><meta name="referrer" content="no-referrer"><title>Twice Gmail setup</title><h2>Authorization successful</h2><p>Copy this refresh token into Supabase Secrets as <code>GOOGLE_REFRESH_TOKEN</code>. Do not share it or commit it to GitHub.</p><textarea id="token" rows="5" style="width:100%">${escaped}</textarea><button onclick="navigator.clipboard.writeText(document.getElementById('token').value)">Copy token</button><p>After saving it, disable or remove this temporary setup function.</p>`,
    { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "no-referrer" } },
  );
});
