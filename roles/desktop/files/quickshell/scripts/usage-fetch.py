#!/usr/bin/env python3
"""Model-usage fetcher for the Quickshell menubar.

In direct mode this reads the credential files the provider CLIs (Claude Code,
Codex CLI, Kimi Code) write locally.  In CLIProxyAPI mode it asks the protected
management API to call the same usage endpoints with each managed credential,
including xAI/Grok; provider tokens never leave CLIProxyAPI. Sub2API mode
reads managed account quotas through its admin API.  With
``--refresh-claude``, an expiring direct-mode Claude access token is handed
back to the official Claude CLI for refresh.

Successful readings are cached privately.  Endpoint failures retain a marked
stale reading until its reset passes, and repeated failures back off instead
of hammering a rate-limited endpoint.

Prints one JSON object keyed by provider (including Gemini in Sub2API mode).
Each provider is {"status": "ok", ...} or {"status": "error", "kind": ...}.
"""

import argparse
import base64
import copy
import fcntl
import hashlib
import json
import math
import os
import re
import shutil
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

TIMEOUT = 20
REFRESH_TIMEOUT = 30

FIVE_HOURS = 5 * 3600
SEVEN_DAYS = 7 * 24 * 3600
XAI_BILLING_WEEKLY_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
XAI_BILLING_MONTHLY_URL = "https://cli-chat-proxy.grok.com/v1/billing"
XAI_REQUEST_HEADERS = {
    "Authorization": "Bearer $TOKEN$",
    "x-xai-token-auth": "xai-grok-cli",
    "x-grok-client-version": "0.2.91",
    "Accept": "*/*",
    "User-Agent": "grok-pager/0.2.91 grok-shell/0.2.91 (macos; aarch64)",
}
CLAUDE_MIN_INTERVAL = 5 * 60
MAX_BACKOFF = 15 * 60
MAX_STALE_AGE = 2 * 24 * 3600
STATE_VERSION = 2


def home(*parts):
    return os.path.join(os.path.expanduser("~"), *parts)


def read_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def err(kind, message="", **details):
    value = {"status": "error", "kind": kind, "message": message}
    value.update(details)
    return value


def http_request(url, headers, method="GET", body=None, ssl_context=None):
    req = urllib.request.Request(url, headers=headers, method=method, data=body)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT,
                                    context=ssl_context) as resp:
            return resp.status, resp.read(), resp.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers
    except Exception as e:  # DNS, timeout, TLS…
        return None, str(e), {}


def http_get(url, headers):
    return http_request(url, headers)


def retry_after_seconds(headers, now=None):
    """Parse Retry-After's seconds or HTTP-date forms."""
    raw = headers.get("Retry-After") if headers else None
    if not isinstance(raw, str):
        return None
    raw = raw.strip()
    if not raw:
        return None
    try:
        return max(0, math.ceil(float(raw)))
    except (ValueError, OverflowError):
        pass
    try:
        parsed = parsedate_to_datetime(raw)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        current = time.time() if now is None else now
        return max(0, math.ceil(parsed.timestamp() - current))
    except (TypeError, ValueError, OverflowError):
        return None


def http_json(provider_cmd, url, headers):
    """Shared fetch + status handling. Returns (data, None) or (None, err)."""
    status, body, response_headers = http_get(url, headers)
    if status is None:
        return None, err("network", body)
    if status == 429:
        return None, err("rate", "Rate limited by the usage endpoint.",
                         retryAfter=retry_after_seconds(response_headers))
    if status in (401, 403):
        return None, err("expired", provider_cmd)
    if not 200 <= status < 300:
        return None, err("http", f"Usage endpoint returned HTTP {status}.")
    try:
        return json.loads(body), None
    except Exception as e:
        return None, err("parse", str(e))


def parse_rfc3339(value):
    if not isinstance(value, str):
        return None
    try:
        text = value.replace("Z", "+00:00")
        return int(datetime.fromisoformat(text).timestamp())
    except ValueError:
        return None


def lenient_num(value):
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def jwt_claims(token):
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return {}


def first_text(mapping, *keys):
    if not isinstance(mapping, dict):
        return None
    for key in keys:
        value = mapping.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


# ---------------------------------------------------------------- State/cache

def usage_state_path():
    override = os.environ.get("QUICKSHELL_USAGE_STATE_PATH")
    if override:
        return os.path.abspath(os.path.expanduser(override))
    cache_home = os.environ.get("XDG_CACHE_HOME")
    if not cache_home:
        cache_home = home(".cache")
    return os.path.join(os.path.expanduser(cache_home), "quickshell",
                        "model-usage.json")


def empty_state():
    return {"version": STATE_VERSION, "providers": {}}


def load_state(path):
    try:
        value = read_json(path)
    except (OSError, ValueError, TypeError):
        return empty_state()
    if not isinstance(value, dict) or value.get("version") != STATE_VERSION:
        return empty_state()
    if not isinstance(value.get("providers"), dict):
        value["providers"] = {}
    return value


def save_state(path, state):
    """Atomically write a user-private cache without following a file link."""
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".model-usage-", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fd = -1
            json.dump(state, fh, separators=(",", ":"))
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600, follow_symlinks=False)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def cached_provider(entry, now, failure=None, retry_at=None):
    """Return a safe cached reading, dropping windows whose reset passed."""
    if not isinstance(entry, dict):
        return None
    value = entry.get("lastOk")
    observed_at = entry.get("observedAt")
    if not isinstance(value, dict) or value.get("status") != "ok":
        return None
    if not isinstance(observed_at, (int, float)):
        return None
    if now - observed_at > MAX_STALE_AGE:
        return None

    cached = copy.deepcopy(value)
    previous_windows = cached.get("windows")
    if isinstance(previous_windows, list):
        cached["windows"] = [window for window in previous_windows
                             if not isinstance(window, dict)
                             or not isinstance(window.get("resetsAt"), (int, float))
                             or window["resetsAt"] > now]
        # A quota percentage belongs to the period in which it was observed.
        # Once every known period resets, do not present that number as current.
        if previous_windows and not cached["windows"] and not cached.get("credits"):
            return None

    accounts = cached.get("accounts")
    if isinstance(accounts, list):
        for account in accounts:
            if not isinstance(account, dict) or account.get("status") != "ok":
                continue
            account_windows = account.get("windows")
            if isinstance(account_windows, list):
                account["windows"] = [window for window in account_windows
                                      if not isinstance(window, dict)
                                      or not isinstance(window.get("resetsAt"),
                                                        (int, float))
                                      or window["resetsAt"] > now]
            account["observedAt"] = int(
                account.get("observedAt", observed_at))
            account["stale"] = failure is not None
            if failure is not None:
                account["staleKind"] = failure.get("kind", "network")
                account["staleMessage"] = failure.get("message", "")

    cached["observedAt"] = int(observed_at)
    cached["stale"] = failure is not None
    if failure is not None:
        cached["staleKind"] = failure.get("kind", "network")
        cached["staleMessage"] = failure.get("message", "")
        if isinstance(retry_at, (int, float)):
            cached["retryAt"] = int(retry_at)
    return cached


def backoff_seconds(failures, minimum, failure):
    delay = min(MAX_BACKOFF, 60 * (2 ** max(0, failures - 1)))
    delay = max(minimum, delay)
    retry_after = failure.get("retryAfter")
    if isinstance(retry_after, (int, float)) and math.isfinite(retry_after):
        delay = max(delay, math.ceil(retry_after))
    return delay


# ---------------------------------------------------------------- Claude

CLAUDE_PLANS = {"pro": "Claude Pro", "max": "Claude Max", "team": "Claude Team",
                "enterprise": "Claude Enterprise"}


def claude_plan(oauth):
    subscription = oauth.get("subscriptionType")
    plan = CLAUDE_PLANS.get(subscription, subscription)
    tier = oauth.get("rateLimitTier")
    if subscription == "max" and isinstance(tier, str):
        match = re.search(r"(?:^|[_-])max[_-](\d+x)(?:$|[_-])", tier.lower())
        if match:
            plan = f"{plan} {match.group(1)}"
    return plan


def token_expired(value, now=None, skew=0):
    if not isinstance(value, (int, float)):
        return False
    # Claude's credential file currently stores milliseconds, while accepting
    # seconds here keeps the check tolerant of a future schema change.
    timestamp = value / 1000 if value > 10_000_000_000 else value
    current = time.time() if now is None else now
    return timestamp <= current + skew


def read_claude_oauth(path):
    try:
        oauth = read_json(path)["claudeAiOauth"]
        if not isinstance(oauth, dict) or not isinstance(oauth.get("accessToken"), str):
            return None
        return oauth
    except (OSError, ValueError, TypeError, KeyError):
        return None


def claude_credentials_path():
    cfg_dir = os.environ.get("CLAUDE_CONFIG_DIR") or home(".claude")
    return os.path.join(cfg_dir, ".credentials.json")


def update_cached_claude_metadata(state):
    """Upgrade display metadata without spending a Claude endpoint request."""
    providers = state.get("providers")
    if not isinstance(providers, dict):
        return
    entry = providers.get("claude")
    if not isinstance(entry, dict):
        return
    last_ok = entry.get("lastOk")
    if not isinstance(last_ok, dict):
        return

    # Account and implementation-source labels are no longer part of the UI
    # contract; remove them from the private cache as well as future results.
    last_ok.pop("account", None)
    last_ok.pop("source", None)
    oauth = read_claude_oauth(claude_credentials_path())
    if oauth:
        last_ok["plan"] = claude_plan(oauth)


def refresh_claude_oauth(path, oauth):
    """Ask Claude Code to exchange its own refresh token and rewrite creds."""
    refresh_token = oauth.get("refreshToken")
    scopes = oauth.get("scopes")
    if isinstance(scopes, list):
        scopes = " ".join(scope for scope in scopes if isinstance(scope, str))
    elif isinstance(scopes, str):
        scopes = " ".join(scopes.split())
    else:
        scopes = ""
    if (not isinstance(refresh_token, str) or not refresh_token
            or not scopes or token_expired(oauth.get("refreshTokenExpiresAt"))):
        return None, err("expired", "claude")

    executable = shutil.which("claude")
    if not executable:
        return None, err("refresh", "Claude Code is not installed or not on PATH.")

    environment = os.environ.copy()
    # Subscription login must not be pre-empted by a terminal API key, cloud
    # provider, or access-token override inherited by quickshell.service.
    for name in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
                 "CLAUDE_CODE_OAUTH_TOKEN",
                 "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
                 "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
                 "CLAUDE_CODE_USE_FOUNDRY"):
        environment.pop(name, None)
    environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] = refresh_token
    environment["CLAUDE_CODE_OAUTH_SCOPES"] = scopes
    environment["NO_COLOR"] = "1"

    try:
        completed = subprocess.run(
            [executable, "auth", "login", "--claudeai"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=REFRESH_TIMEOUT,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None, err("refresh", "Claude Code token refresh timed out.")
    except OSError:
        return None, err("refresh", "Claude Code token refresh could not start.")
    if completed.returncode != 0:
        # Deliberately do not surface CLI output: authentication diagnostics
        # are not guaranteed to be free of credential material.
        return None, err("refresh", "Claude Code could not refresh the saved login.")

    refreshed = read_claude_oauth(path)
    if not refreshed or token_expired(refreshed.get("expiresAt"), skew=60):
        return None, err("refresh", "Claude Code did not save a fresh login.")
    return refreshed, None


def claude_limit_window(raw):
    """Convert the current structured Claude usage rows into UI windows."""
    if not isinstance(raw, dict):
        return None
    used = lenient_num(raw.get("percent"))
    if used is None:
        return None

    kind = raw.get("kind") or ""
    group = raw.get("group") or ""
    scope = raw.get("scope") if isinstance(raw.get("scope"), dict) else {}

    scoped_name = None
    for scope_kind in ("model", "surface"):
        scoped = scope.get(scope_kind)
        if isinstance(scoped, dict):
            scoped_name = scoped.get("display_name") or scoped.get("name")
        elif isinstance(scoped, str):
            scoped_name = scoped
        if scoped_name:
            break

    if kind == "session" or group == "session":
        label = "5 hour limit"
        window_secs = FIVE_HOURS
    elif kind == "weekly_scoped" and scoped_name:
        label = f"Weekly ({scoped_name})"
        window_secs = SEVEN_DAYS
    elif kind.startswith("weekly") or group == "weekly":
        label = "Weekly limit"
        window_secs = SEVEN_DAYS
    else:
        label = scoped_name or kind.replace("_", " ").strip().title() or "Usage limit"
        window_secs = None

    return {"label": label, "used": min(max(used, 0.0), 100.0),
            "windowSecs": window_secs,
            "resetsAt": parse_rfc3339(raw.get("resets_at"))}


def parse_claude_usage(data, plan=None):
    if not isinstance(data, dict):
        return err("parse", "Claude returned an invalid usage payload.")

    # Newer Claude usage responses expose a structured list, including
    # account-specific scoped limits such as Fable. Prefer it so new model
    # limits appear automatically without hard-coding their API field names.
    windows = [window for window in
               (claude_limit_window(row) for row in data.get("limits") or [])
               if window]

    # Compatibility with older endpoint responses.
    if not windows:
        for key, label, secs in (("five_hour", "5 hour limit", FIVE_HOURS),
                                 ("seven_day", "Weekly limit", SEVEN_DAYS),
                                 ("seven_day_opus", "Weekly (Opus)", SEVEN_DAYS),
                                 ("seven_day_sonnet", "Weekly (Sonnet)", SEVEN_DAYS)):
            raw = data.get(key)
            if not isinstance(raw, dict):
                continue
            used = raw.get("utilization")
            if not isinstance(used, (int, float)):
                continue
            windows.append({"label": label,
                            "used": min(max(float(used), 0.0), 100.0),
                            "windowSecs": secs,
                            "resetsAt": parse_rfc3339(raw.get("resets_at"))})

    credits = None
    extra = data.get("extra_usage")
    if isinstance(extra, dict) and extra.get("is_enabled"):
        # Monetary amounts arrive in cents.
        used = lenient_num(extra.get("used_credits"))
        limit = lenient_num(extra.get("monthly_limit"))
        credits = {"used": used / 100 if used is not None else None,
                   "limit": limit / 100 if limit is not None else None,
                   "currency": extra.get("currency"),
                   "unlimited": False}

    return {"status": "ok", "plan": plan,
            "windows": windows, "credits": credits}


def fetch_claude(auto_refresh=False):
    path = claude_credentials_path()
    if not os.path.isfile(path):
        return err("nocreds", "claude")
    oauth = read_claude_oauth(path)
    if not oauth:
        return err("nocreds", "claude")
    refreshed = False
    if token_expired(oauth.get("expiresAt"), skew=60):
        if not auto_refresh:
            return err("expired", "claude")
        oauth, refresh_error = refresh_claude_oauth(path, oauth)
        if refresh_error:
            return refresh_error
        refreshed = True
    token = oauth["accessToken"]

    plan = claude_plan(oauth)

    data, e = http_json("claude", "https://api.anthropic.com/api/oauth/usage", {
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-code/2.1.0 (external, cli)",
    })
    # Expiry metadata can lag server-side revocation. Give the CLI one chance
    # to refresh and retry, but never loop on a rejected replacement token.
    if e and e.get("kind") == "expired" and auto_refresh and not refreshed:
        oauth, refresh_error = refresh_claude_oauth(path, oauth)
        if refresh_error:
            return refresh_error
        data, e = http_json("claude", "https://api.anthropic.com/api/oauth/usage", {
            "Authorization": f"Bearer {oauth['accessToken']}",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.0 (external, cli)",
        })
    if e:
        return e

    return parse_claude_usage(data, plan)


# ---------------------------------------------------------------- Codex

CODEX_PLANS = {"plus": "ChatGPT Plus", "pro": "ChatGPT Pro", "team": "ChatGPT Team",
               "business": "ChatGPT Business", "enterprise": "ChatGPT Enterprise",
               "free": "ChatGPT Free"}


def codex_window(raw, model):
    used = raw.get("used_percent")
    if not isinstance(used, (int, float)):
        return None
    secs = raw.get("limit_window_seconds")
    if model:
        span = "usage"
        if isinstance(secs, (int, float)):
            span = "5 hour" if secs <= FIVE_HOURS else humanize_window(int(secs))
        label = f"{model} ({span})"
    elif isinstance(secs, (int, float)) and secs <= FIVE_HOURS:
        label = "5 hour limit"
    elif secs == SEVEN_DAYS:
        label = "Weekly limit"
    elif isinstance(secs, (int, float)):
        label = f"{humanize_window(int(secs))} limit"
    else:
        label = "usage limit"

    reset = raw.get("reset_at")
    resets_at = int(reset) if isinstance(reset, (int, float)) else parse_rfc3339(reset)
    return {"label": label, "used": min(max(float(used), 0.0), 100.0),
            "windowSecs": int(secs) if isinstance(secs, (int, float)) else None,
            "resetsAt": resets_at}


def humanize_window(secs):
    hours = secs // 3600
    if hours >= 24 and hours % 24 == 0:
        return f"{hours // 24} day"
    return f"{hours} hour"


def parse_codex_usage(data, plan=None, account=None):
    if not isinstance(data, dict):
        return err("parse", "Codex returned an invalid usage payload.")

    windows = []

    def push(rate_limit, model=None):
        if not isinstance(rate_limit, dict):
            return
        for key in ("primary_window", "secondary_window"):
            raw = rate_limit.get(key)
            if isinstance(raw, dict):
                window = codex_window(raw, model)
                if window:
                    windows.append(window)

    push(data.get("rate_limit"))
    for extra in data.get("additional_rate_limits") or []:
        if isinstance(extra, dict):
            push(extra.get("rate_limit"), extra.get("limit_name"))

    if plan is None and data.get("plan_type"):
        raw_plan = str(data["plan_type"])
        plan = CODEX_PLANS.get(raw_plan.lower(), f"ChatGPT {raw_plan}")
    account = account or data.get("email")

    credits = None
    raw_credits = data.get("credits")
    if isinstance(raw_credits, dict) and (raw_credits.get("has_credits")
                                          or raw_credits.get("unlimited")):
        credits = {"remaining": lenient_num(raw_credits.get("balance")),
                   "unlimited": bool(raw_credits.get("unlimited"))}

    return {"status": "ok", "plan": plan, "account": account,
            "source": "codex-oauth", "windows": windows, "credits": credits}


def fetch_codex():
    codex_home = os.environ.get("CODEX_HOME") or home(".codex")
    path = os.path.join(codex_home, "auth.json")
    if not os.path.isfile(path):
        return err("nocreds", "codex")
    try:
        tokens = read_json(path).get("tokens")
    except Exception:
        return err("nocreds", "codex")
    if not tokens or "access_token" not in tokens:
        return err("nocreds", "codex")

    claims = jwt_claims(tokens.get("id_token") or "")
    auth_claims = claims.get("https://api.openai.com/auth") or {}
    plan = CODEX_PLANS.get(auth_claims.get("chatgpt_plan_type"),
                           auth_claims.get("chatgpt_plan_type"))
    email = claims.get("email")

    headers = {"Authorization": f"Bearer {tokens['access_token']}",
               "User-Agent": "codex-cli"}
    if tokens.get("account_id"):
        headers["ChatGPT-Account-Id"] = tokens["account_id"]
    data, e = http_json("codex", "https://chatgpt.com/backend-api/wham/usage", headers)
    if e:
        return e

    return parse_codex_usage(data, plan, email)


# ---------------------------------------------------------------- Kimi

def kimi_window_secs(window):
    if not isinstance(window, dict):
        return None
    duration = lenient_num(window.get("duration"))
    if duration is None:
        return None
    unit = (window.get("timeUnit") or "").upper()
    scale = {"TIME_UNIT_SECOND": 1, "TIME_UNIT_MINUTE": 60,
             "TIME_UNIT_HOUR": 3600, "TIME_UNIT_DAY": 86400}.get(unit)
    return int(duration * scale) if scale else None


def kimi_row(counters, window_secs, fallback_label):
    used = lenient_num(counters.get("used"))
    limit = lenient_num(counters.get("limit"))
    remaining = lenient_num(counters.get("remaining"))
    if used is None and limit is not None and remaining is not None:
        used = limit - remaining
    if used is None or not limit:
        return None
    pct = min(max(used / limit * 100.0, 0.0), 100.0)
    resets_at = parse_rfc3339(counters.get("reset_at") or counters.get("resetAt")
                              or counters.get("reset_time") or counters.get("resetTime"))
    if resets_at is None:
        reset_in = lenient_num(counters.get("reset_in") or counters.get("resetIn")
                               or counters.get("ttl"))
        if reset_in is not None:
            resets_at = int(time.time() + reset_in)
    label = counters.get("title") or counters.get("name") or fallback_label
    return {"label": label, "used": pct, "windowSecs": window_secs, "resetsAt": resets_at}


def parse_kimi_usage(data):
    if not isinstance(data, dict):
        return err("parse", "Kimi returned an invalid usage payload.")

    windows = []
    usage = data.get("usage")
    if isinstance(usage, dict):
        window = kimi_row(usage, SEVEN_DAYS, "Weekly limit")
        if window:
            windows.append(window)
    for limit in data.get("limits") or []:
        if not isinstance(limit, dict):
            continue
        counters = limit.get("detail") if isinstance(limit.get("detail"), dict) else limit
        secs = kimi_window_secs(limit.get("window"))
        fallback = "5 hour limit" if secs == FIVE_HOURS else "Usage limit"
        window = kimi_row(counters, secs, fallback)
        if window:
            windows.append(window)

    plan = None
    membership = (data.get("user") or {}).get("membership") or {}
    level = membership.get("level")
    if isinstance(level, str):
        plan = "Kimi " + level.replace("LEVEL_", "").replace("_", " ").title()

    credits = None
    wallet = data.get("boosterWallet")
    if isinstance(wallet, dict):
        balance = wallet.get("balance") or {}
        # amount fields are fixed-point micro-cents: raw / 1e6 = cents.
        left = lenient_num(balance.get("amountLeft"))
        used = lenient_num((wallet.get("monthlyUsed") or {}).get("priceInCents"))
        limit = lenient_num((wallet.get("monthlyChargeLimit") or {}).get("priceInCents"))
        if left is not None or used is not None:
            credits = {"remaining": left / 1e8 if left is not None else None,
                       "used": used / 100 if used is not None else None,
                       "limit": limit / 100 if limit is not None
                                and wallet.get("monthlyChargeLimitEnabled") else None,
                       "unlimited": False}

    return {"status": "ok", "plan": plan, "account": None,
            "source": "kimi-oauth", "windows": windows, "credits": credits}


def fetch_kimi():
    kimi_home = os.environ.get("KIMI_CODE_HOME") or home(".kimi-code")
    path = os.path.join(kimi_home, "credentials", "kimi-code.json")
    if not os.path.isfile(path):
        return err("nocreds", "kimi")
    try:
        creds = read_json(path)
        token = creds["access_token"]
    except Exception:
        return err("nocreds", "kimi")
    expires_at = creds.get("expires_at")
    if isinstance(expires_at, (int, float)) and expires_at <= time.time():
        return err("expired", "kimi")

    base = (os.environ.get("KIMI_CODE_BASE_URL") or "https://api.kimi.com/coding/v1").rstrip("/")
    data, e = http_json("kimi", f"{base}/usages", {
        "Authorization": f"Bearer {token}", "Accept": "application/json"})
    if e:
        return e

    return parse_kimi_usage(data)


# --------------------------------------------------------------- xAI / Grok

def xai_config(payload):
    if not isinstance(payload, dict):
        return None
    config = payload.get("config")
    return config if isinstance(config, dict) else None


def xai_cent(config, *keys):
    if not isinstance(config, dict):
        return None
    raw = None
    for key in keys:
        if key in config:
            raw = config[key]
            break
    if isinstance(raw, dict):
        raw = raw.get("val")
    return lenient_num(raw)


def xai_plan(monthly_limit_cents):
    if monthly_limit_cents == 15_000:
        return "SuperGrok"
    if monthly_limit_cents == 150_000:
        return "SuperGrok Heavy"
    return None


def xai_period(config):
    if not isinstance(config, dict):
        return None, None, None
    period = config.get("currentPeriod", config.get("current_period"))
    if not isinstance(period, dict):
        return None, None, None
    kind = str(period.get("type") or "").lower()
    start = parse_rfc3339(period.get("start"))
    end = parse_rfc3339(period.get("end"))
    return kind, start, end


def parse_xai_usage(weekly_payload, monthly_payload=None):
    """Convert Grok's weekly quota and monthly billing responses for the UI."""
    weekly = xai_config(weekly_payload)
    monthly = xai_config(monthly_payload)
    if weekly is None and monthly is None:
        return err("parse", "xAI returned an invalid billing payload.")

    quota = weekly or monthly
    kind, period_start, period_end = xai_period(quota)
    used = lenient_num(quota.get(
        "creditUsagePercent", quota.get("credit_usage_percent")))
    products = quota.get("productUsage", quota.get("product_usage"))
    products = products if isinstance(products, list) else []
    is_weekly = "weekly" in (kind or "") or used is not None or bool(products)

    windows = []
    if is_weekly:
        window_secs = (period_end - period_start
                       if period_start is not None and period_end is not None
                       and period_end > period_start else SEVEN_DAYS)
        windows.append({
            "label": "Weekly limit",
            # A newly-created period can omit the percentage. Preserve that
            # as unknown instead of reporting a fabricated 0% reading.
            "used": min(max(used, 0.0), 100.0) if used is not None else None,
            "windowSecs": window_secs,
            "resetsAt": period_end,
        })
        for index, item in enumerate(products):
            if not isinstance(item, dict):
                continue
            product_used = lenient_num(item.get(
                "usagePercent", item.get("usage_percent")))
            product = first_text(item, "product") or f"Product {index + 1}"
            windows.append({
                "label": f"{product} usage",
                "used": (min(max(product_used, 0.0), 100.0)
                         if product_used is not None else None),
                "windowSecs": window_secs,
                "resetsAt": period_end,
            })

    billing = monthly or weekly
    monthly_limit = xai_cent(billing, "monthlyLimit", "monthly_limit")
    total_used = xai_cent(billing, "used")
    on_demand_cap = xai_cent(billing, "onDemandCap", "on_demand_cap")
    on_demand_used = xai_cent(billing, "onDemandUsed", "on_demand_used")
    credits = None
    if monthly_limit is not None and monthly_limit > 0:
        included_used = min(total_used, monthly_limit) if total_used is not None else None
        credits = {
            "label": "Monthly credits",
            "description": "included allowance for this billing cycle",
            "used": included_used / 100 if included_used is not None else None,
            "limit": monthly_limit / 100,
            "currency": "USD",
            "unlimited": False,
        }
    elif on_demand_cap is not None and on_demand_cap > 0:
        if on_demand_used is None and total_used is not None and monthly_limit is not None:
            on_demand_used = max(0.0, total_used - monthly_limit)
        credits = {
            "label": "Extra usage",
            "description": "pay-as-you-go beyond plan limits",
            "used": on_demand_used / 100 if on_demand_used is not None else None,
            "limit": on_demand_cap / 100,
            "currency": "USD",
            "unlimited": False,
        }

    if not windows and credits is None:
        return err("parse", "xAI billing did not include quota data.")
    return {"status": "ok", "plan": xai_plan(monthly_limit),
            "account": None, "source": "xai-oauth",
            "windows": windows, "credits": credits}


# ------------------------------------------------------------- CLIProxyAPI

def cliproxy_key_path(source="cliproxy"):
    return management_key_path(source)


def management_key_path(source):
    override = os.environ.get(f"QUICKSHELL_USAGE_{source.upper()}_KEY_PATH")
    if override:
        return os.path.abspath(os.path.expanduser(override))
    state_home = os.environ.get("XDG_STATE_HOME") or home(".local", "state")
    return os.path.join(os.path.expanduser(state_home), "quickshell",
                        f"model-usage-{source}.key")


def read_cliproxy_key(path=None):
    """Read a small, owner-only key file without following a symlink."""
    key_path = path or cliproxy_key_path()
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(key_path, flags)
    except FileNotFoundError:
        return None, err(
            "config",
            "CLIProxyAPI management key is not configured. Add it in widget settings.")
    except OSError:
        return None, err("config", "CLIProxyAPI management key could not be opened safely.")
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) & 0o077):
            return None, err(
                "config", "CLIProxyAPI management key file must be owned by you and mode 0600.")
        raw = os.read(fd, 8193)
        if len(raw) > 8192:
            return None, err("config", "CLIProxyAPI management key is too large.")
    finally:
        os.close(fd)
    try:
        key = raw.decode("utf-8").strip()
    except UnicodeDecodeError:
        key = ""
    if not key or any(ord(char) < 0x20 for char in key):
        return None, err("config", "CLIProxyAPI management key is empty or invalid.")
    return key, None


def normalize_cliproxy_url(value):
    """Accept the dashboard URL or an API base and return the server base."""
    text = (value or "").strip()
    try:
        parsed = urllib.parse.urlsplit(text)
        # Reading .port validates malformed ports as well.
        parsed.port
    except (TypeError, ValueError):
        raise ValueError("CLIProxyAPI management address is invalid.") from None
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username is not None or parsed.password is not None
            or parsed.query or parsed.fragment):
        raise ValueError("CLIProxyAPI management address must be an HTTP(S) server URL.")

    path = parsed.path.rstrip("/")
    for suffix in ("/management.html", "/v0/management/auth-files",
                   "/v0/management"):
        if path.endswith(suffix):
            path = path[:-len(suffix)].rstrip("/")
            break
    if any(part in (".", "..") for part in path.split("/")):
        raise ValueError("CLIProxyAPI management address contains an invalid path.")
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))


class CliProxyClient:
    def __init__(self, address, key, verify_tls=True):
        self.base = normalize_cliproxy_url(address)
        self.key = key
        self.ssl_context = None
        if self.base.startswith("https://") and not verify_tls:
            self.ssl_context = ssl._create_unverified_context()  # noqa: SLF001

    def management_json(self, path, payload=None):
        headers = {"Authorization": f"Bearer {self.key}",
                   "Accept": "application/json"}
        body = None
        method = "GET"
        if payload is not None:
            method = "POST"
            headers["Content-Type"] = "application/json"
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        status_code, response, response_headers = http_request(
            self.base + path, headers, method, body, self.ssl_context)
        if status_code is None:
            message = str(response)
            if "CERTIFICATE_VERIFY_FAILED" in message:
                message = ("CLIProxyAPI TLS certificate could not be verified. "
                           "Install its CA or turn off Verify TLS in widget settings.")
            return None, err("network", message)
        if status_code in (401, 403):
            return None, err("config", "CLIProxyAPI rejected the management key.")
        if status_code == 429:
            return None, err("rate", "CLIProxyAPI management API is rate limited.",
                             retryAfter=retry_after_seconds(response_headers))
        if not 200 <= status_code < 300:
            return None, err("http", f"CLIProxyAPI returned HTTP {status_code}.")
        try:
            return json.loads(response), None
        except (TypeError, ValueError):
            return None, err("parse", "CLIProxyAPI returned invalid JSON.")

    def auth_files(self):
        data, failure = self.management_json("/v0/management/auth-files")
        if failure:
            return None, failure
        files = data.get("files") if isinstance(data, dict) else None
        if not isinstance(files, list):
            return None, err("parse", "CLIProxyAPI returned an invalid auth-file list.")
        return [entry for entry in files if isinstance(entry, dict)], None

    def api_json(self, auth_index, url, headers):
        response, failure = self.management_json("/v0/management/api-call", {
            "auth_index": auth_index,
            "method": "GET",
            "url": url,
            "header": headers,
        })
        if failure:
            return None, failure
        if not isinstance(response, dict):
            return None, err("parse", "CLIProxyAPI returned an invalid API-call response.")
        status_code = response.get("status_code", response.get("statusCode"))
        try:
            status_code = int(status_code)
        except (TypeError, ValueError):
            return None, err("parse", "CLIProxyAPI omitted the upstream status code.")
        if status_code == 429:
            return None, err("rate", "Rate limited by the usage endpoint.")
        if status_code in (401, 403):
            return None, err("expired", "Managed provider token was rejected.")
        if not 200 <= status_code < 300:
            return None, err("http", f"Usage endpoint returned HTTP {status_code}.")
        body = response.get("body")
        if isinstance(body, dict):
            return body, None
        try:
            return json.loads(body), None
        except (TypeError, ValueError):
            return None, err("parse", "Usage endpoint returned invalid JSON.")


def cliproxy_codex_identity(entry):
    id_token = entry.get("id_token")
    if not isinstance(id_token, dict):
        id_token = {}
    account_id = (first_text(entry, "chatgpt_account_id", "chatgptAccountId")
                  or first_text(id_token, "chatgpt_account_id", "chatgptAccountId"))
    raw_plan = (first_text(entry, "plan_type", "planType")
                or first_text(id_token, "plan_type", "planType"))
    plan = CODEX_PLANS.get(raw_plan.lower(), f"ChatGPT {raw_plan}") if raw_plan else None
    return account_id, plan


def cliproxy_claude_plan(entry):
    raw_plan = first_text(entry, "subscription_type", "subscriptionType",
                          "plan_type", "planType")
    if not raw_plan:
        return None
    return CLAUDE_PLANS.get(raw_plan.lower(), raw_plan)


def mask_email(value):
    """Return a recognisable account label without caching a full address."""
    if not isinstance(value, str):
        return None
    email = value.strip()
    local, separator, domain = email.rpartition("@")
    if not separator or not local or not domain:
        return None
    return f"{local[0]}•••@{domain}"


def mask_emails_in_label(value):
    if not isinstance(value, str):
        return None

    def replace(match):
        return mask_email(match.group(0)) or "Account"

    compact = re.sub(r"\s+", " ", value.strip())
    return re.sub(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", replace,
                  compact, flags=re.IGNORECASE)[:80]


def cliproxy_account_label(entry, position):
    """Choose a user-facing auth label, masking credential identities."""
    email = first_text(entry, "email")
    label = first_text(entry, "label")

    # CLIProxyAPI commonly mirrors the email into label/account/name/id. A
    # genuinely custom label is useful; a mirrored credential identity is not
    # safe to persist in a screenshot-prone status widget.
    if label and (not email or (label != email and email not in label)):
        return mask_emails_in_label(label)
    masked = mask_email(email)
    if masked:
        return masked

    for key in ("account", "name", "id"):
        candidate = first_text(entry, key)
        if not candidate:
            continue
        embedded = re.search(
            r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", candidate,
            flags=re.IGNORECASE)
        if embedded:
            safe_email = mask_email(embedded.group(0))
            if safe_email:
                return safe_email
        # File names and opaque runtime identifiers are implementation detail,
        # not a useful substitute for an account name.
        if key == "account" and len(candidate) <= 80:
            return mask_emails_in_label(candidate)
    return f"Account {position + 1}"


def cliproxy_account_id(provider, entry):
    """Create a stable UI key without exposing CLIProxyAPI's auth index."""
    auth_index = first_text(entry, "auth_index", "authIndex") or "missing"
    digest = hashlib.sha256(
        f"{provider}\0{auth_index}".encode("utf-8")).hexdigest()[:16]
    return f"account-{digest}"


def decorate_cliproxy_reading(provider, entry, reading, position):
    value = copy.deepcopy(reading) if isinstance(reading, dict) else err(
        "parse", "CLIProxyAPI returned an invalid account reading.")
    # Provider parsers may discover the full email in an upstream response.
    # The masked auth-list label is the only identity allowed past this point.
    value.pop("account", None)
    value["id"] = cliproxy_account_id(provider, entry)
    value["label"] = cliproxy_account_label(entry, position)
    return value


def disambiguate_cliproxy_labels(readings):
    totals = {}
    for reading in readings:
        label = reading.get("label")
        totals[label] = totals.get(label, 0) + 1
    seen = {}
    for reading in readings:
        label = reading.get("label")
        if totals.get(label, 0) < 2:
            continue
        seen[label] = seen.get(label, 0) + 1
        reading["label"] = f"{label} · {seen[label]}"


def fetch_cliproxy_account(provider, entry, client):
    auth_index = first_text(entry, "auth_index", "authIndex")
    if not auth_index:
        return err("config", f"CLIProxyAPI {provider} credential has no auth_index.")
    if provider == "claude":
        data, failure = client.api_json(auth_index,
            "https://api.anthropic.com/api/oauth/usage", {
                "Authorization": "Bearer $TOKEN$",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-code/2.1.0 (external, cli)",
            })
        return failure or parse_claude_usage(data, cliproxy_claude_plan(entry))
    if provider == "codex":
        account_id, plan = cliproxy_codex_identity(entry)
        if not account_id:
            return err("config", "CLIProxyAPI Codex credential has no ChatGPT account ID.")
        data, failure = client.api_json(auth_index,
            "https://chatgpt.com/backend-api/wham/usage", {
                "Authorization": "Bearer $TOKEN$",
                "ChatGPT-Account-Id": account_id,
                "User-Agent": "codex-cli",
            })
        return failure or parse_codex_usage(data, plan)
    if provider == "kimi":
        data, failure = client.api_json(auth_index,
            "https://api.kimi.com/coding/v1/usages", {
                "Authorization": "Bearer $TOKEN$",
                "Accept": "application/json",
            })
        return failure or parse_kimi_usage(data)
    if provider == "xai":
        def request(url):
            return client.api_json(auth_index, url, XAI_REQUEST_HEADERS)

        # These are both read-only billing calls. Do not use the management
        # panel's paid-account health fallback here: it sends a billable chat
        # completion and is inappropriate for a background widget poll.
        with ThreadPoolExecutor(max_workers=2, thread_name_prefix="xai-billing") as pool:
            weekly_future = pool.submit(request, XAI_BILLING_WEEKLY_URL)
            monthly_future = pool.submit(request, XAI_BILLING_MONTHLY_URL)
            weekly, weekly_failure = weekly_future.result()
            monthly, monthly_failure = monthly_future.result()
        if weekly_failure and monthly_failure:
            priority = {"expired": 0, "rate": 1, "network": 2,
                        "http": 3, "parse": 4}
            return min((weekly_failure, monthly_failure),
                       key=lambda value: priority.get(value.get("kind"), 99))
        parsed = parse_xai_usage(weekly, monthly)
        if parsed.get("status") != "ok":
            return weekly_failure or monthly_failure or parsed
        return parsed
    return err("config", f"Unsupported CLIProxyAPI provider: {provider}")


def provider_remaining_score(reading):
    windows = reading.get("windows") if isinstance(reading, dict) else None
    if not isinstance(windows, list) or not windows:
        return -1
    remaining = [100.0 - window["used"] for window in windows
                 if isinstance(window, dict)
                 and isinstance(window.get("used"), (int, float))]
    return min(remaining) if remaining else -1


def fetch_cliproxy_provider(provider, entries, client):
    matching = [entry for entry in entries
                if (first_text(entry, "provider", "type") or "").lower() == provider
                and entry.get("disabled") is not True]
    if not matching:
        return err("nocreds", f"No enabled {provider} credentials in CLIProxyAPI.")
    readings = [decorate_cliproxy_reading(
                    provider, entry,
                    fetch_cliproxy_account(provider, entry, client), position)
                for position, entry in enumerate(matching)]
    return summarize_accounts(readings, "cliproxy")


def summarize_accounts(readings, source):
    disambiguate_cliproxy_labels(readings)
    successful = [value for value in readings
                  if isinstance(value, dict) and value.get("status") == "ok"]
    if not successful:
        priority = {"config": 0, "expired": 1, "rate": 2, "network": 3,
                    "http": 4, "parse": 5}
        failure = copy.deepcopy(min(
            readings, key=lambda value: priority.get(value.get("kind"), 99)))
        failure.pop("id", None)
        failure.pop("label", None)
        failure.update({
            "source": source,
            "accountCount": len(readings),
            "availableCount": 0,
            "accounts": readings,
        })
        return failure

    # CLIProxyAPI may rotate across several subscriptions. The most usable
    # account is the meaningful pool-level reading; summing percentages would
    # be dimensionally wrong and showing the fullest account would create
    # false alarms while another account still has capacity.
    best = copy.deepcopy(max(successful, key=provider_remaining_score))
    best_account_id = best.pop("id")
    best.pop("label", None)
    best.pop("account", None)
    best["source"] = source
    best["accountCount"] = len(readings)
    best["availableCount"] = len(successful)
    best["bestAccountId"] = best_account_id
    best["accounts"] = readings
    return best


def make_cliproxy_providers(address, verify_tls):
    provider_names = ("claude", "codex", "kimi", "xai")
    key, key_error = read_cliproxy_key()
    if key_error:
        return tuple((name, lambda failure=key_error: copy.deepcopy(failure))
                     for name in provider_names), "no-key"
    try:
        client = CliProxyClient(address, key, verify_tls)
    except ValueError as failure:
        value = err("config", str(failure))
        return tuple((name, lambda failure=value: copy.deepcopy(failure))
                     for name in provider_names), "invalid-url"
    files, list_error = client.auth_files()
    if list_error:
        providers = tuple((name, lambda failure=list_error: copy.deepcopy(failure))
                          for name in provider_names)
    else:
        providers = tuple((name, lambda provider=name:
                          fetch_cliproxy_provider(provider, files, client))
                          for name in provider_names)
    fingerprint = hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]
    return providers, f"{client.base}|{verify_tls}|{fingerprint}"


# ---------------------------------------------------------------- Sub2API

SUB2API_PLATFORMS = {"anthropic": "claude", "openai": "codex",
                     "gemini": "gemini", "antigravity": "gemini", "grok": "xai"}
SUB2API_PROVIDERS = ("claude", "codex", "gemini", "xai")


def normalize_sub2api_url(value):
    try:
        base = normalize_cliproxy_url(value)
    except ValueError as failure:
        raise ValueError(str(failure).replace("CLIProxyAPI", "Sub2API")) from None
    for suffix in ("/api/v1/admin/accounts", "/api/v1/admin", "/api/v1",
                   "/admin/accounts", "/admin/dashboard", "/admin"):
        if base.endswith(suffix):
            return base[:-len(suffix)]
    return base


class Sub2ApiClient:
    def __init__(self, address, key, verify_tls=True):
        self.base = normalize_sub2api_url(address)
        self.key = key
        self.ssl_context = (ssl._create_unverified_context()
                            if not verify_tls else None)

    def api_json(self, path):
        # Admin keys must never be forwarded by an HTTP redirect.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None

        request = urllib.request.Request(self.base + "/api/v1/admin" + path,
            headers={"x-api-key": self.key, "Accept": "application/json"})
        opener = urllib.request.build_opener(NoRedirect(),
            urllib.request.HTTPSHandler(context=self.ssl_context))
        try:
            with opener.open(request, timeout=TIMEOUT) as response:
                payload = response.read()
        except urllib.error.HTTPError as failure:
            with failure:
                if failure.code in (401, 403):
                    return None, err("config",
                        f"Sub2API rejected the admin API key (HTTP {failure.code}). "
                        "Use the admin API key from Sub2API admin settings, not an inference API key.")
                if failure.code == 429:
                    return None, err("rate", "Sub2API is rate limited.",
                        retryAfter=retry_after_seconds(failure.headers))
                return None, err("http", f"Sub2API returned HTTP {failure.code}.")
        except Exception:
            return None, err("network", "Could not connect to Sub2API. Check its URL and TLS settings.")
        try:
            envelope = json.loads(payload)
            if not isinstance(envelope, dict) or envelope.get("code") != 0:
                return None, err("parse", "Sub2API returned an unsuccessful API response.")
            return envelope["data"], None
        except (ValueError, TypeError, KeyError):
            return None, err("parse", "Sub2API returned an invalid API response.")

    def accounts(self):
        accounts = []
        for page in range(1, 101):
            data, failure = self.api_json(
                f"/accounts?lite=true&page={page}&page_size=100")
            if failure:
                return None, failure
            if (not isinstance(data, dict) or not isinstance(data.get("items"), list)
                    or not isinstance(data.get("total"), int)):
                return None, err("parse", "Sub2API returned an invalid account list.")
            items = data["items"]
            if any(not isinstance(item, dict) for item in items):
                return None, err("parse", "Sub2API returned an invalid account.")
            accounts.extend(items)
            if len(accounts) >= data["total"]:
                return accounts, None
            if not items:
                break
        return None, err("parse", "Sub2API account pagination did not complete.")


def sub2api_number(value):
    number = lenient_num(value) if not isinstance(value, bool) else None
    return number if number is not None and math.isfinite(number) else None


def parse_sub2api_usage(data):
    if not isinstance(data, dict):
        return err("parse", "Sub2API returned invalid account usage.")
    if data.get("error") or data.get("error_code") or data.get("needs_reauth") or data.get("is_forbidden"):
        kind = {"unauthenticated": "expired", "rate_limited": "rate",
                "network_error": "network"}.get(data.get("error_code"), "http")
        if data.get("needs_reauth"):
            kind = "expired"
        return err(kind, "Sub2API could not read this account's quota. Check the account in its dashboard.")
    windows = []
    fields = [("five_hour", "5 hour limit", FIVE_HOURS),
              ("seven_day", "Weekly limit", SEVEN_DAYS),
              ("seven_day_sonnet", "Sonnet weekly limit", SEVEN_DAYS),
              ("seven_day_fable", "Fable weekly limit", SEVEN_DAYS),
              ("thirty_day", "Monthly limit", 30 * 86400)]
    for pool in ("shared", "pro", "flash"):
        for period, seconds in (("daily", 86400), ("minute", 60)):
            fields.append((f"gemini_{pool}_{period}",
                           f"Gemini {pool.title()} {period}", seconds))
    for field, label, seconds in fields:
        value = data.get(field)
        if not isinstance(value, dict):
            continue
        used = sub2api_number(value.get("utilization"))
        reset = parse_rfc3339(value.get("resets_at"))
        if reset is not None and reset <= time.time():
            continue
        windows.append({"label": label, "used": min(100, max(0, used))
                        if used is not None else None,
                        "windowSecs": seconds, "resetsAt": reset})
    quotas = data.get("antigravity_quota")
    if isinstance(quotas, dict):
        for model, quota in sorted(quotas.items()):
            if not isinstance(quota, dict):
                continue
            used = sub2api_number(quota.get("utilization"))
            reset = parse_rfc3339(quota.get("reset_time"))
            if reset is not None and reset <= time.time():
                continue
            windows.append({"label": str(model)[:80], "used": min(100, max(0, used))
                            if used is not None else None,
                            "windowSecs": None, "resetsAt": reset})
    for field, label in (("grok_request_quota", "Request limit"),
                         ("grok_token_quota", "Token limit")):
        quota = data.get(field)
        if not isinstance(quota, dict):
            continue
        limit = sub2api_number(quota.get("limit"))
        left = sub2api_number(quota.get("remaining"))
        reset = parse_rfc3339(quota.get("reset_at")) or sub2api_number(quota.get("reset_unix"))
        if reset is not None and reset <= time.time():
            continue
        used = min(100, max(0, (1 - left / limit) * 100)) if limit and limit > 0 and left is not None else None
        windows.append({"label": label, "used": used, "windowSecs": None, "resetsAt": reset})
    if not windows:
        return err("wait", "Sub2API has no current quota snapshot. Use the account, then refresh usage.")
    return {"status": "ok", "windows": windows, "credits": None,
            "plan": mask_emails_in_label(first_text(data, "subscription_tier"))}


def sub2api_codex_snapshot(entry):
    # GET /accounts/:id/usage can generate an inference request for Codex.
    # Read the persisted snapshot from the lite inventory instead.
    extra = entry.get("extra")
    extra = extra if isinstance(extra, dict) else {}
    data = {}
    for period, field in (("5h", "five_hour"), ("7d", "seven_day")):
        used = sub2api_number(extra.get(f"codex_{period}_used_percent"))
        if used is None:
            continue
        reset = extra.get(f"codex_{period}_reset_at")
        if not parse_rfc3339(reset):
            observed = parse_rfc3339(extra.get("codex_usage_updated_at"))
            after = sub2api_number(extra.get(f"codex_{period}_reset_after_seconds"))
            if observed is not None and after is not None:
                reset = datetime.fromtimestamp(observed + after, timezone.utc).isoformat()
        data[field] = {"utilization": used, "resets_at": reset}
    return parse_sub2api_usage(data)


def fetch_sub2api_provider(provider, entries, client):
    matching = [entry for entry in entries
                if SUB2API_PLATFORMS.get(entry.get("platform")) == provider
                and entry.get("status") != "disabled"]
    if not matching:
        return err("nocreds", f"No enabled {provider} accounts in Sub2API.")
    readings = []
    for position, entry in enumerate(matching):
        account_id = entry.get("id")
        if type(account_id) is not int or account_id <= 0:
            value = err("parse", "Sub2API account has an invalid ID.")
        elif provider == "codex":
            value = sub2api_codex_snapshot(entry)
        else:
            data, failure = client.api_json(f"/accounts/{account_id}/usage")
            value = failure or parse_sub2api_usage(data)
        value["id"] = "account-" + hashlib.sha256(
            f"sub2api:{account_id}".encode()).hexdigest()[:16]
        value["label"] = mask_emails_in_label(first_text(entry, "name")) or f"Account {position + 1}"
        readings.append(value)
    return summarize_accounts(readings, "sub2api")


def make_sub2api_providers(address, verify_tls):
    key, failure = read_cliproxy_key(management_key_path("sub2api"))
    if failure:
        failure["message"] = failure["message"].replace("CLIProxyAPI management", "Sub2API admin API")
    client = None
    if not failure:
        try:
            client = Sub2ApiClient(address, key, verify_tls)
        except ValueError as error:
            failure = err("config", str(error))
    fingerprint = "sub2api|" + hashlib.sha256(
        f"{address}|{verify_tls}|{key}".encode()).hexdigest()
    if not failure:
        entries, failure = client.accounts()
    if failure:
        # Keep setup failures visible even before an inventory is available.
        failure["source"] = "sub2api"
        return tuple((name, lambda: copy.deepcopy(failure))
                     for name in SUB2API_PROVIDERS), fingerprint
    return tuple((name, lambda provider=name:
                  fetch_sub2api_provider(provider, entries, client))
                 for name in SUB2API_PROVIDERS), fingerprint


PROVIDERS = (("claude", fetch_claude), ("codex", fetch_codex),
             ("kimi", fetch_kimi),
             ("xai", lambda: err(
                 "config", "xAI usage is available through CLIProxyAPI.")))
MIN_INTERVALS = {"claude": CLAUDE_MIN_INTERVAL}


def fetch_all(providers=PROVIDERS):
    """Fetch independent providers concurrently, preserving output order."""
    selected = tuple(providers)
    if not selected:
        return {}
    result = {}
    with ThreadPoolExecutor(max_workers=len(selected), thread_name_prefix="usage") as pool:
        futures = [(name, pool.submit(fn)) for name, fn in selected]
        for name, future in futures:
            try:
                result[name] = future.result()
            except Exception as error:
                result[name] = err("parse", str(error))
    return result


def fetch_all_resilient(providers, state, now=None, min_intervals=None):
    """Fetch due providers and update persistent last-good/backoff state."""
    current = time.time() if now is None else now
    selected = tuple(providers)
    intervals = MIN_INTERVALS if min_intervals is None else min_intervals
    provider_state = state.setdefault("providers", {})
    if not isinstance(provider_state, dict):
        provider_state = {}
        state["providers"] = provider_state

    due = []
    skipped = {}
    for name, fetch in selected:
        entry = provider_state.get(name)
        if not isinstance(entry, dict):
            entry = {}
            provider_state[name] = entry
        next_attempt = entry.get("nextAttemptAt", 0)
        failures = entry.get("failures", 0)
        has_failures = isinstance(failures, int) and failures > 0
        if isinstance(next_attempt, (int, float)) and current < next_attempt:
            failure = entry.get("lastError") if has_failures else None
            cached = cached_provider(entry, current, failure, next_attempt)
            if cached is not None:
                skipped[name] = cached
                continue
            if isinstance(failure, dict):
                value = copy.deepcopy(failure)
                value["retryAt"] = int(next_attempt)
                skipped[name] = value
                continue
            if isinstance(entry.get("lastOk"), dict):
                skipped[name] = err(
                    "wait", "Waiting for the provider polling interval.",
                    retryAt=math.ceil(next_attempt))
                continue
        due.append((name, fetch))

    fetched = fetch_all(due)
    result = {}
    for name, _ in selected:
        if name in skipped:
            result[name] = skipped[name]
            continue

        value = fetched[name]
        if not isinstance(value, dict):
            value = err("parse", "Usage provider returned an invalid result.")
        entry = provider_state[name]
        minimum = intervals.get(name, 0)
        entry["lastAttemptAt"] = int(current)
        if value.get("status") == "ok":
            clean = copy.deepcopy(value)
            for key in ("observedAt", "stale", "staleKind", "staleMessage",
                        "retryAt"):
                clean.pop(key, None)
            entry.update({
                "lastOk": clean,
                "observedAt": int(current),
                "failures": 0,
                "nextAttemptAt": math.ceil(current + minimum),
            })
            entry.pop("lastError", None)
            value = copy.deepcopy(clean)
            value["observedAt"] = int(current)
            value["stale"] = False
            result[name] = value
            continue

        previous = entry.get("failures", 0)
        previous = previous if isinstance(previous, int) and previous >= 0 else 0
        failures = min(previous, 30) + 1
        retry_at = math.ceil(current + backoff_seconds(failures, minimum, value))
        failure = copy.deepcopy(value)
        entry.update({
            "failures": failures,
            "lastError": failure,
            "nextAttemptAt": retry_at,
        })
        cached = cached_provider(entry, current, failure, retry_at)
        if cached is not None:
            result[name] = cached
        else:
            failure["retryAt"] = retry_at
            result[name] = failure
    return result


def test_connection(source, address, verify_tls=True):
    """Check current credentials and inventory without cached quota readings."""
    name = "Sub2API" if source == "sub2api" else "CLIProxyAPI"
    key, failure = read_cliproxy_key(management_key_path(source))
    if failure:
        message = failure["message"].replace("CLIProxyAPI management", "Sub2API admin API") if source == "sub2api" else failure["message"]
        return {"success": False, "kind": failure["kind"], "message": message}
    try:
        client = (Sub2ApiClient if source == "sub2api" else CliProxyClient)(address, key, verify_tls)
    except ValueError as failure:
        return {"success": False, "kind": "config", "message": str(failure)}
    entries, failure = client.accounts() if source == "sub2api" else client.auth_files()
    if failure:
        return {"success": False, "kind": failure["kind"], "message": failure["message"]}
    supported = 0
    for entry in entries:
        if source == "sub2api":
            supported += (entry.get("status") != "disabled"
                          and entry.get("platform") in SUB2API_PLATFORMS)
        else:
            supported += (entry.get("disabled") is not True and
                (first_text(entry, "provider", "type") or "").lower() in
                ("claude", "codex", "kimi", "xai"))
    message = f"Connected to {name}. Admin access verified." if source == "sub2api" else f"Connected to {name}. Management access verified."
    if supported:
        message += f" Found {supported} supported enabled account{'s' if supported != 1 else ''}."
    else:
        message += " No supported enabled accounts found."
    return {"success": True, "accountCount": supported, "message": message}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source", choices=("direct", "cliproxy", "sub2api"), default="direct",
        help="credential source (default: direct)",
    )
    parser.add_argument(
        "--cliproxy-url",
        default="http://127.0.0.1:8317",
        help="CLIProxyAPI server or management.html URL",
    )
    parser.add_argument(
        "--cliproxy-insecure", action="store_true",
        help="disable TLS certificate verification for CLIProxyAPI only",
    )
    parser.add_argument(
        "--refresh-claude",
        action="store_true",
        help="let the installed Claude CLI refresh expiring Claude credentials",
    )
    parser.add_argument("--sub2api-url", default="", help="Sub2API server or admin URL")
    parser.add_argument("--sub2api-insecure", action="store_true",
                        help="disable TLS verification for Sub2API only")
    parser.add_argument("--test-connection", action="store_true",
                        help="test management access without reading or writing the usage cache")
    args = parser.parse_args()
    if args.test_connection:
        if args.source == "direct":
            parser.error("--test-connection requires a server source")
        address = args.sub2api_url if args.source == "sub2api" else args.cliproxy_url
        verify_tls = not (args.sub2api_insecure if args.source == "sub2api" else args.cliproxy_insecure)
        json.dump(test_connection(args.source, address, verify_tls), sys.stdout)
        return

    source_fingerprint = "direct"
    if args.source == "sub2api":
        providers, source_fingerprint = make_sub2api_providers(
            args.sub2api_url, not args.sub2api_insecure)
    elif args.source == "cliproxy":
        providers, source_fingerprint = make_cliproxy_providers(
            args.cliproxy_url, not args.cliproxy_insecure)
    else:
        providers = (
            ("claude", lambda: fetch_claude(args.refresh_claude)),
            ("codex", fetch_codex),
            ("kimi", fetch_kimi),
            ("xai", lambda: err(
                "config", "xAI usage is available through CLIProxyAPI.")),
        )
    path = usage_state_path()
    state = empty_state()
    lock = None
    lock_fd = None
    try:
        directory = os.path.dirname(path)
        os.makedirs(directory, mode=0o700, exist_ok=True)
        flags = os.O_CREAT | os.O_RDWR
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        lock_fd = os.open(path + ".lock", flags, 0o600)
        os.fchmod(lock_fd, 0o600)
        lock = os.fdopen(lock_fd, "r+")
        lock_fd = None
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        state = load_state(path)
    except OSError:
        if lock is not None:
            lock.close()
        elif lock_fd is not None:
            os.close(lock_fd)
        lock = None

    if state.get("sourceFingerprint") != source_fingerprint:
        state["providers"] = {}
    state["sourceFingerprint"] = source_fingerprint
    if args.source == "direct":
        update_cached_claude_metadata(state)

    # Enabling refresh should immediately recover an auth failure left by the
    # disabled setting, but a failed enabled refresh still observes backoff.
    previous_refresh = state.get("claudeAutoRefresh")
    if args.source == "direct" and args.refresh_claude and previous_refresh is not True:
        claude_state = state.get("providers", {}).get("claude", {})
        if not isinstance(claude_state, dict):
            claude_state = {}
            state["providers"]["claude"] = claude_state
        last_error = claude_state.get("lastError", {})
        if not isinstance(last_error, dict):
            last_error = {}
        if last_error.get("kind") in ("expired", "refresh"):
            claude_state["nextAttemptAt"] = 0
    state["claudeAutoRefresh"] = args.source == "direct" and args.refresh_claude

    try:
        result = fetch_all_resilient(providers, state)
        if lock is not None:
            try:
                save_state(path, state)
            except (OSError, TypeError, ValueError):
                pass
    finally:
        if lock is not None:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
            lock.close()
    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()
