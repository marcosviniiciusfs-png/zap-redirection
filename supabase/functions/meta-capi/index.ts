const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type RedirectGroup = {
  id: string;
  pixel_id: string | null;
  capi_access_token: string | null;
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}

function requiredEnv(name: string) {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing ${name}`);
  }
  return value;
}

function getClientIp(request: Request) {
  const forwardedFor = request.headers.get("x-forwarded-for") || "";
  return forwardedFor.split(",")[0]?.trim() || request.headers.get("cf-connecting-ip") || "";
}

async function supabaseGet(path: string) {
  const supabaseUrl = requiredEnv("SUPABASE_URL");
  const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
  const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
    },
  });

  if (!response.ok) {
    throw new Error(await response.text());
  }

  return response.json();
}

async function findGroup(userId: string, groupSlug: string): Promise<RedirectGroup | null> {
  const rows = await supabaseGet(
    [
      "redirect_groups?select=id,pixel_id,capi_access_token",
      `user_id=eq.${encodeURIComponent(userId)}`,
      `slug=eq.${encodeURIComponent(groupSlug)}`,
      "limit=1",
    ].join("&"),
  );

  return rows[0] || null;
}

async function hasLink(groupId: string, linkSlug: string) {
  const rows = await supabaseGet(
    [
      "redirect_links?select=id",
      `group_id=eq.${encodeURIComponent(groupId)}`,
      `slug=eq.${encodeURIComponent(linkSlug)}`,
      "limit=1",
    ].join("&"),
  );

  return rows.length > 0;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  try {
    const payload = await request.json();
    const userId = String(payload.user_id || "");
    const groupSlug = String(payload.group_id || "");
    const linkSlug = String(payload.link_id || "");
    const eventName = String(payload.event_name || "");

    if (!userId || !groupSlug || !linkSlug || !eventName) {
      return jsonResponse({ error: "Missing required event fields" }, 400);
    }

    if (!["Lead", "Contact"].includes(eventName)) {
      return jsonResponse({ error: "Unsupported event" }, 400);
    }

    const group = await findGroup(userId, groupSlug);
    if (!group || !(await hasLink(group.id, linkSlug))) {
      return jsonResponse({ ok: true, skipped: "unknown_link" });
    }

    if (!group.capi_access_token) {
      return jsonResponse({ ok: true, skipped: "missing_capi_token" });
    }

    const pixelId = String(payload.pixel_id || group.pixel_id || "");
    if (!pixelId) {
      return jsonResponse({ ok: true, skipped: "missing_pixel_id" });
    }

    const metaEvent = {
      event_name: eventName,
      event_time: Math.floor(Date.now() / 1000),
      event_id: String(payload.event_id || `${linkSlug}-${eventName}-${Date.now()}`),
      action_source: "website",
      event_source_url: String(payload.event_source_url || ""),
      user_data: {
        client_ip_address: getClientIp(request),
        client_user_agent: String(payload.user_agent || request.headers.get("user-agent") || ""),
        fbp: payload.fbp || undefined,
        fbc: payload.fbc || undefined,
      },
      custom_data: {
        content_category: String(payload.content_category || "whatsapp_redirect"),
        content_name: String(payload.project_name || payload.campaign_name || linkSlug),
        campaign_name: String(payload.campaign_name || ""),
        group_id: groupSlug,
        link_id: linkSlug,
      },
    };

    const metaResponse = await fetch(`https://graph.facebook.com/v20.0/${pixelId}/events`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        data: [metaEvent],
        access_token: group.capi_access_token,
      }),
    });

    const metaBody = await metaResponse.json().catch(() => ({}));
    if (!metaResponse.ok) {
      return jsonResponse({ ok: false, meta: metaBody }, 502);
    }

    return jsonResponse({ ok: true, meta: metaBody });
  } catch (error) {
    return jsonResponse({ error: error instanceof Error ? error.message : "Unexpected error" }, 500);
  }
});
