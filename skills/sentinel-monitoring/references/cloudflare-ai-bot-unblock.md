# Cloudflare Bot Management for AI Crawlers

## Problem
AI bots (GPTBot, Claude-Web, PerplexityBot) were returning HTTP 403 on lafronteraia.com.
Googlebot and Bingbot were fine (HTTP 200). Root cause: Cloudflare's `ai_bots_protection: "block"`
in Bot Management settings.

This prevents content from appearing in ChatGPT, Claude, and Perplexity responses,
hurting AEO (Answer Engine Optimization). ~25% of search traffic is now via AI chatbots.

## Diagnosis

```bash
# Check current state
curl -s -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
  "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/bot_management" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']['ai_bots_protection'])"

# Test individual bots
for bot in "GPTBot" "Claude-Web" "PerplexityBot" "Googlebot" "Bingbot"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" -A "$bot" https://tusitio.com/)
  echo "$bot: HTTP $code"
done
```

## Fix

```bash
# Unblock all AI bots (PUT required, PATCH returns 405)
curl -s -X PUT -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
  "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/bot_management" \
  -H "Content-Type: application/json" \
  -d '{"enable_js":false,"fight_mode":false,"ai_bots_protection":"disabled","crawler_protection":"disabled"}'
```

**Important**: 
- Only PUT works (PATCH → 405 Method Not Allowed)
- Must include `enable_js` and `fight_mode` in payload even if unchanged
- Changes take effect within seconds

## Sub-categories
Cloudflare Bot Management has sub-categories (`ai_training`, `ai_search`, `ai_user`).
Setting `ai_bots_protection: "disabled"` is sufficient to unblock all of them.
The sub-categories can be set to `"user_agent_overridable"` for per-bot control via robots.txt.

## Verification

```bash
# All should return HTTP 200
for bot in "GPTBot/1.0" "Claude-Web/1.0" "PerplexityBot/1.0" "Googlebot/2.1" "bingbot/2.0"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -A "$bot" https://tusitio.com/)
  [ "$code" = "200" ] && echo "✅ $bot" || echo "❌ $bot: HTTP $code"
done
```
