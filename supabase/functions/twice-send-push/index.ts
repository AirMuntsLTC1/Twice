import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-twice-push-secret",
};

function base64url(input: string | Uint8Array): string {
  const bytes = typeof input === "string"
    ? new TextEncoder().encode(input)
    : input;
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function pemBytes(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

async function firebaseAccessToken(sa: {
  project_id: string;
  client_email: string;
  private_key: string;
}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const unsigned = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemBytes(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const assertion = `${unsigned}.${base64url(new Uint8Array(signature))}`;
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  const result = await response.json();
  if (!response.ok || !result.access_token) {
    throw new Error(`Google OAuth failed (${response.status})`);
  }
  return result.access_token as string;
}

function notificationText(row: Record<string, unknown>, actor: string) {
  const type = String(row.type ?? "");
  const suppliedBody = typeof row.body === "string" ? row.body.trim() : "";
  const titles: Record<string, string> = {
    like: "New like",
    comment: "New comment",
    reply: "New reply",
    follow: "New follower",
    follow_request: "Follow request",
    follow_accept: "Follow request accepted",
    message: "New message",
    story_reaction: "Story reaction",
    story_reply: "Story reply",
    save: "Post saved",
  };
  const bodies: Record<string, string> = {
    like: `${actor} liked your post.`,
    comment: `${actor} commented on your post.`,
    reply: `${actor} replied to your comment.`,
    follow: `${actor} started following you.`,
    follow_request: `${actor} requested to follow you.`,
    follow_accept: `${actor} accepted your follow request.`,
    message: suppliedBody || `${actor} sent you a message.`,
    story_reaction: `${actor} reacted to your story.`,
    story_reply: suppliedBody || `${actor} replied to your story.`,
    save: `${actor} saved your post.`,
  };
  return {
    title: titles[type] ?? "Twice notification",
    body: suppliedBody || bodies[type] || `${actor} sent you a notification.`,
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return Response.json({ error: "Method not allowed" }, { status: 405, headers: corsHeaders });
  }

  const expected = Deno.env.get("TWICE_PUSH_WEBHOOK_SECRET") ?? "";
  const supplied = req.headers.get("x-twice-push-secret") ?? "";
  if (!expected || !supplied || supplied.length !== expected.length) {
    return Response.json({ error: "Unauthorized" }, { status: 401, headers: corsHeaders });
  }
  const a = new TextEncoder().encode(expected);
  const b = new TextEncoder().encode(supplied);
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a[i] ^ b[i];
  if (mismatch !== 0) {
    return Response.json({ error: "Unauthorized" }, { status: 401, headers: corsHeaders });
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return Response.json({ error: "Invalid JSON" }, { status: 400, headers: corsHeaders });
  }

  if (
    payload.type !== "INSERT" ||
    payload.table !== "notifications" ||
    payload.schema !== "public" ||
    !payload.record ||
    typeof payload.record !== "object"
  ) {
    return Response.json({ ignored: true }, { status: 200, headers: corsHeaders });
  }

  const row = payload.record as Record<string, unknown>;
  const recipientId = typeof row.recipient_id === "string" ? row.recipient_id : "";
  const notificationId = typeof row.id === "string" ? row.id : "";
  if (!recipientId || !notificationId) {
    return Response.json({ error: "Missing notification recipient or ID" }, { status: 400, headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const serviceAccountText = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON");
  if (!supabaseUrl || !serviceKey || !serviceAccountText) {
    console.error("Required server environment is missing");
    return Response.json({ error: "Server configuration missing" }, { status: 500, headers: corsHeaders });
  }

  try {
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: tokenRows, error: tokenError } = await admin
      .from("device_push_tokens")
      .select("id, token")
      .eq("user_id", recipientId);

    if (tokenError) throw new Error("Could not load recipient tokens");
    if (!tokenRows?.length) {
      return Response.json({ sent: 0, reason: "No registered devices" }, { headers: corsHeaders });
    }

    let actor = "Someone";
    let actorAvatar = "";
    const actorId = typeof row.actor_id === "string" ? row.actor_id : "";
    if (actorId) {
      const { data: profile } = await admin
        .from("profiles")
        .select("username, display_name, avatar_url")
        .eq("id", actorId)
        .maybeSingle();
      if (profile) {
        actor = profile.display_name?.trim() || profile.username || actor;
        actorAvatar = profile.avatar_url || "";
      }
    }

    const sa = JSON.parse(serviceAccountText);
    if (!sa.project_id || !sa.client_email || !sa.private_key) {
      throw new Error("Firebase service account JSON is missing required fields");
    }
    const accessToken = await firebaseAccessToken(sa);
    const text = notificationText(row, actor);
    const type = String(row.type ?? "");
    const data: Record<string, string> = {
      id: notificationId,
      type,
      title: text.title,
      body: text.body,
      actorId,
      actorName: actor,
      actorAvatar,
      postId: typeof row.post_id === "string" ? row.post_id : "",
      storyId: typeof row.story_id === "string" ? row.story_id : "",
      commentId: typeof row.comment_id === "string" ? row.comment_id : "",
      createdAt: typeof row.created_at === "string" ? row.created_at : "",
    };

    let sent = 0;
    let removed = 0;
    const failures: string[] = [];

    for (const tokenRow of tokenRows) {
      const response = await fetch(
        `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(sa.project_id)}/messages:send`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${accessToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              token: tokenRow.token,
              // Data-only: Android must not auto-render a generic
              // notification; the app's local notification service handles it.
              data,
              android: {
                priority: "HIGH",
              },
            },
          }),
        },
      );

      if (response.ok) {
        sent++;
        continue;
      }

      const errorBody = await response.text();
      let fcmErrorCode = "";
      try {
        const parsed = JSON.parse(errorBody);
        fcmErrorCode = parsed?.error?.details?.find(
          (item: { errorCode?: string }) => item.errorCode === "UNREGISTERED",
        )?.errorCode ?? "";
      } catch {
        // Keep the token if the error response is not valid JSON.
      }

      if (fcmErrorCode === "UNREGISTERED") {
        const { error } = await admin
          .from("device_push_tokens")
          .delete()
          .eq("id", tokenRow.id);
        if (!error) removed++;
        else console.error("Could not remove an unregistered token.");
      } else {
        failures.push(`FCM returned ${response.status}`);
        console.error("FCM send failed:", response.status, errorBody.slice(0, 500));
      }
    }

    return Response.json({ sent, removedInvalidTokens: removed, failures: failures.length }, {
      headers: corsHeaders,
    });
  } catch (error) {
    console.error("Push sender failed:", error instanceof Error ? error.message : "Unknown error");
    return Response.json({ error: "Push delivery failed" }, { status: 500, headers: corsHeaders });
  }
});

