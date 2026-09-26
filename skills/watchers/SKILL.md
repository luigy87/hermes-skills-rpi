---
name: watchers
description: Poll RSS, JSON APIs, and GitHub with watermark dedup.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [cron, polling, rss, github, http, automation, monitoring]
    category: devops
    requires_toolsets: [terminal]
    related_skills: []
---

# Watchers

Poll external sources on an interval and react only to new items. Three ready-made scripts plus a shared watermark helper; wire them into a cron job (or run them ad-hoc from the terminal).

## When to Use

- User wants to watch an RSS/Atom feed and be notified of new entries
- User wants to watch a GitHub repo's issues / pulls / releases / commits
- User wants to poll an arbitrary JSON endpoint and get notified on new items
- User asks for "a watcher for X" or "notify me when X changes"

## Mental model

A watcher is just a script that:

1. Fetches data from the external source
2. Compares against a watermark file of previously-seen IDs
3. Writes the new watermark back
4. Prints new items to stdout (or nothing on no-change)

The scripts below handle all three. The agent runs them via the terminal tool — from a cron job, a webhook, or an interactive chat — and reports what's new.

## Ready-made scripts

All three live in `$HERMES_HOME/skills/devops/watchers/scripts/` once the skill is installed. Each reads `WATCHER_STATE_DIR` (defaults to `$HERMES_HOME/watcher-state/`) for its state file, keyed by the `--name` argument.

| Script | What it watches | Dedup key |
|---|---|---|
| `watch_rss.py` | RSS 2.0 or Atom feed URL | `<guid>` / `<id>` |
| `watch_http_json.py` | Any JSON endpoint returning a list of objects | Configurable id field |
| `watch_github.py` | GitHub issues / pulls / releases / commits for a repo | `id` / `sha` |

All three:

- First run records a baseline — never replays existing feed
- Watermark is a bounded ID set (max 500) to cap memory
- Output format: `## <title>\n<url>\n\n<optional body>` per item
- Empty stdout on no-new — the caller treats that as silent
- Non-zero exit on fetch errors

## Usage

Run a watcher directly from the terminal tool:

```bash
python $HERMES_HOME/skills/devops/watchers/scripts/watch_rss.py \
  --name hn --url https://news.ycombinator.com/rss --max 5
```

Watch a GitHub repo (set `GITHUB_TOKEN` in `~/.hermes/.env` to avoid the 60 req/hr anonymous rate limit):

```bash
python $HERMES_HOME/skills/devops/watchers/scripts/watch_github.py \
  --name hermes-issues --repo NousResearch/hermes-agent --scope issues
```

Poll an arbitrary JSON API:

```bash
python $HERMES_HOME/skills/devops/watchers/scripts/watch_http_json.py \
  --name api --url https://api.example.com/events \
  --id-field event_id --items-path data.events
```

## Wiring into cron

Ask the agent to schedule a cron job with a prompt like:

> Every 15 minutes, run `watch_rss.py --name hn --url https://news.ycombinator.com/rss`. If it prints anything, summarize the headlines and deliver them. If it prints nothing, stay silent.

The agent invokes the script via the terminal tool inside the cron job's agent loop; no changes to cron's built-in `--script` flag are needed.

## State files

Every watcher writes `$HERMES_HOME/watcher-state/<name>.json`. Inspect:

```bash
cat $HERMES_HOME/watcher-state/hn.json
```

Force a replay (next run treated as first poll):

```bash
rm $HERMES_HOME/watcher-state/hn.json
```

## Writing your own

All three scripts use the same template: load watermark, fetch, diff, save, emit. `scripts/_watermark.py` is the shared helper; import it to get atomic writes + bounded ID set + first-run baseline for free. See any of the three reference scripts for how little boilerplate it takes.

## Common Pitfalls

1. **Printing a "no new items" header every tick.** Callers rely on empty stdout = silent. If you print anything on an empty delta, you spam the channel. The shipped scripts handle this; custom scripts must too.
2. **Expecting the first run to emit items.** It won't — first run records a baseline. If you need an initial digest, delete the state file after the first run or add a `--prime-with-latest N` flag in your own script.
3. **Unbounded watermark growth.** The shared helper caps at 500 IDs. Raise it for high-churn feeds; lower it on constrained filesystems.
4. **Putting the state dir where the agent's sandbox can't write.** `$HERMES_HOME/watcher-state/` is always writable. Docker/Modal backends may not see arbitrary host paths.

5. **No retry on a transient timeout kills the whole source for that tick.** A
   slow-but-alive endpoint gets marked `ERROR` and its entire cycle is lost.
   Verified 08-Sep-2026: two arXiv sources failed with `TimeoutError` at 05:00;
   minutes later `export.arxiv.org` answered in 0.5s. It was momentary
   slowness, not a dead source. Wrap the fetch in one retry with a short sleep
   — if it fails twice in a row it still reports as before, so a real outage is
   not masked:

   ```python
   def fetch(url, accept=None):
       req = urllib.request.Request(url, headers={"User-Agent": UA,
                                                  "Accept": accept or "*/*"})
       last = None
       for attempt in (1, 2):
           try:
               with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                   return r.read().decode("utf-8", errors="ignore")
           except (TimeoutError, urllib.error.URLError, OSError) as e:
               last = e
               if attempt == 1:
                   time.sleep(3)
       raise last
   ```

   Before adding the retry, confirm the source is genuinely reachable (curl it
   directly). A retry over a dead endpoint just doubles the wait. Also prefer
   `https://` over `http://` for APIs that offer both.

6. **An accumulating output store makes a correct fix look broken.** If the
   consumer file *accumulates* (dedup by hash, so pending items survive between
   cycles — a deliberate design to avoid losing work), items written **before**
   a producer fix keep the old broken shape. Verified 08-Sep-2026: after fixing
   three code paths that omitted a required key, the regenerated file still
   showed 3 bad items. The fix was fine; the store was additive.

   Check the store's semantics before doubting the fix:

   ```bash
   grep -nE "previos|accumulat|append|dedup|\+ nuevas" <producer>.py
   stat -c "%y" <output-file>      # did it actually get rewritten?
   ```

   If it accumulates: the fix covers only NEW items. Backfill the old ones by
   inferring the missing field from data that *is* present (e.g. `source` →
   category) rather than deleting the file — losing pending work is worse than
   a migration. Then verify by *effect*: re-run the exact expression that was
   crashing (`item["key"]`) and confirm it no longer raises.

7. **An overwritten inbox cannot feed a weekly report.** If the daily run
   rewrites its output and the ledger keeps only titles/decisions, a weekly
   consumer sees one day. Archive raw items (url, votes/stars, source, ts) to
   an append file with time-based pruning parsed from JSON — never by string
   slicing a fixed offset, which silently mis-compares and wipes the archive.
   Test pruning with one old and one recent synthetic line.

8. **Adding sources grows the run time; re-check the global timeout.** Each
   new host adds latency and politeness gaps; a whole-run `signal.alarm` sized
   for the old source count kills the run midway. Keep it below the cron
   wrapper's own cap. Community sources (Reddit) throttle with 429: give them
   larger gaps and let the host quarantine skip the rest of that host.

