"""Bounded, read-only T3 Code usage RPC and private offline snapshots.

Supports T3 usage contracts 4 and 5 and the Effect JSON RPC WebSocket protocol.
Only accounting metadata is retained; prompts and raw transcript paths are not.
"""
from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
import re
import socket
import ssl
import stat
import struct
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from model_usage_common import atomic_write_json

MAX_BYTES = 16 * 1024 * 1024
MAX_BUCKETS = 50000
PROVIDERS = ("claude", "codex")


class T3Error(ValueError):
    pass


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def normalize_url(value):
    try:
        if not isinstance(value, str) or any(ord(c) < 33 for c in value.strip()):
            raise ValueError
        url = urllib.parse.urlsplit(value.strip())
        url.port
        if (url.scheme not in ("http", "https") or not url.hostname or url.username is not None
                or url.password is not None or url.query or url.fragment
                or any(p in (".", "..") for p in urllib.parse.unquote(url.path).split("/"))):
            raise ValueError
        return urllib.parse.urlunsplit((url.scheme, url.netloc.lower(), url.path.rstrip("/"), "", ""))
    except (ValueError, TypeError, AttributeError):
        raise T3Error("Enter the T3 server HTTP(S) URL without a pairing token or query string.") from None


def parse_servers(raw):
    if not isinstance(raw, str) or len(raw.encode()) > 32768:
        raise T3Error("T3 server settings are too large.")
    try:
        rows = json.loads(raw)
        if not isinstance(rows, list) or len(rows) > 4:
            raise ValueError
        result, ids = [], set()
        for row in rows:
            if not isinstance(row, dict) or set(row) - {"id", "name", "url", "tokenFile", "enabled"}:
                raise ValueError
            identity = row.get("id", "")
            name = row.get("name", "")
            token_file = row.get("tokenFile", "")
            if (not isinstance(identity, str) or not re.fullmatch(r"[a-zA-Z0-9-]{1,64}", identity)
                    or identity in ids or not isinstance(name, str) or not 1 <= len(name.strip()) <= 80
                    or any(ord(c) < 32 for c in name) or not isinstance(token_file, str)
                    or len(token_file) > 4096 or type(row.get("enabled", True)) is not bool):
                raise ValueError
            ids.add(identity)
            result.append({"id": identity, "name": name.strip(), "url": normalize_url(row.get("url")),
                           "tokenFile": token_file, "enabled": row.get("enabled", True)})
        return result
    except (ValueError, TypeError, RecursionError):
        raise T3Error("Configure up to four T3 servers with unique IDs, names, and valid URLs.") from None


def read_token(path):
    if not path:
        return ""
    try:
        fd = os.open(Path(path).expanduser(), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError
            raw = os.read(fd, 8193)
        finally:
            os.close(fd)
        value = raw.decode("ascii").strip()
        if not value or len(raw) > 8192 or any(ord(c) < 33 or ord(c) > 126 for c in value):
            raise ValueError
        return value
    except (OSError, ValueError, UnicodeError):
        raise T3Error("The T3 token file must be private (0600), owned by you, and contain a connection token.") from None


def fingerprint(host, provider, path, volume):
    # An inode on one host identifies the same directory even through a symlink.
    return digest([host.lower(), provider, volume or path])


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, url, timeout):
        self.url = normalize_url(url)
        self.deadline = time.monotonic() + timeout

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise T3Error("T3 usage request timed out.")
        return remaining

    def exchange(self, token):
        data = urllib.parse.urlencode({
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "subject_token": token,
            "subject_token_type": "urn:t3:params:oauth:token-type:environment-bootstrap",
            "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "scope": "orchestration:read", "client_label": "Omarchy Model Usage",
            "client_device_type": "desktop", "client_os": "Linux",
        }).encode()
        req = urllib.request.Request(self.url + "/oauth/token", data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"})
        try:
            with urllib.request.build_opener(NoRedirects()).open(req, timeout=self.remaining()) as response:
                parts, size = [], 0
                while size <= 65536:
                    self.remaining()
                    part = response.read1(min(8192, 65537 - size))
                    if not part:
                        break
                    parts.append(part)
                    size += len(part)
                raw = b"".join(parts)
            if len(raw) > 65536:
                raise ValueError
            result = json.loads(raw)
            access = result.get("access_token") if isinstance(result, dict) else None
            if (not isinstance(access, str) or not 1 <= len(access) <= 8192
                    or any(ord(c) < 33 or ord(c) > 126 for c in access)
                    or result.get("token_type") != "Bearer"):
                raise ValueError
            return access
        except urllib.error.HTTPError as exc:
            exc.close()
            raise T3Error("T3 rejected the credential. Enter a fresh connection token from that server.") from None
        except (ValueError, UnicodeError):
            raise T3Error("T3 returned an unsupported authentication response.") from None

    def rpc(self, query, token):
        url = urllib.parse.urlsplit(self.url)
        port = url.port or (443 if url.scheme == "https" else 80)
        connection = socket.create_connection((url.hostname, port), timeout=self.remaining())
        try:
            if url.scheme == "https":
                connection = ssl.create_default_context().wrap_socket(connection, server_hostname=url.hostname)
            key = base64.b64encode(os.urandom(16)).decode()
            host = url.netloc
            headers = [f"GET {url.path}/ws HTTP/1.1", f"Host: {host}", "Upgrade: websocket",
                       "Connection: Upgrade", f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13"]
            if token:
                headers.append("Authorization: Bearer " + token)
            connection.sendall(("\r\n".join(headers) + "\r\n\r\n").encode("ascii"))
            # Read only through the HTTP terminator, preserving an immediate WS frame.
            response = bytearray()
            while not response.endswith(b"\r\n\r\n"):
                if len(response) >= 16384:
                    raise T3Error("T3 returned oversized connection headers.")
                connection.settimeout(self.remaining())
                part = connection.recv(1)
                if not part:
                    raise T3Error("T3 closed the connection.")
                response.extend(part)
            lines = response.decode("latin1").split("\r\n")
            status = lines[0].split(" ")
            if len(status) < 2:
                raise T3Error("Invalid T3 connection response.")
            code = status[1]
            if code in ("401", "403"):
                raise PermissionError
            if code != "101":
                raise T3Error("T3 usage API is unavailable. Check the server URL and T3 version.")
            parsed = {k.lower(): v.strip() for line in lines[1:] if ":" in line for k, v in [line.split(":", 1)]}
            expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            if parsed.get("sec-websocket-accept", "").strip() != expected or parsed.get("upgrade", "").lower() != "websocket":
                raise T3Error("Invalid T3 WebSocket upgrade.")

            def send(opcode, data):
                mask = os.urandom(4)
                header = bytes([0x80 | opcode])
                length = len(data)
                header += bytes([0x80 | length]) if length < 126 else bytes([0xfe]) + struct.pack("!H", length)
                connection.settimeout(self.remaining())
                connection.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

            def receive(count):
                result = bytearray()
                while len(result) < count:
                    connection.settimeout(self.remaining())
                    chunk = connection.recv(count - len(result))
                    if not chunk:
                        raise T3Error("T3 disconnected before returning usage.")
                    result.extend(chunk)
                return bytes(result)

            send(1, json.dumps({"_tag": "Request", "id": "0", "tag": "server.getUsageSummary",
                                "payload": query, "headers": []}).encode())
            message, total, fragmented = bytearray(), 0, False
            for _ in range(4096):
                a, b = receive(2)
                size = b & 127
                if size == 126:
                    size = struct.unpack("!H", receive(2))[0]
                elif size == 127:
                    size = struct.unpack("!Q", receive(8))[0]
                total += size
                opcode, final = a & 15, bool(a & 128)
                if a & 112 or b & 128 or total > MAX_BYTES or (opcode >= 8 and (size > 125 or not final)):
                    raise T3Error("T3 usage response exceeds limits or uses unsupported frames.")
                data = receive(size)
                if opcode == 9:
                    send(10, data)
                    continue
                if opcode == 10:
                    continue
                if opcode == 8:
                    raise T3Error("T3 closed the usage connection. Check access and server compatibility.")
                if (opcode == 1 and fragmented) or (opcode == 0 and not fragmented) or opcode not in (0, 1):
                    raise T3Error("Invalid T3 usage frame sequence.")
                message.extend(data)
                fragmented = not final
                if not final:
                    continue
                document = json.loads(message)
                message.clear()
                if not isinstance(document, dict):
                    raise T3Error("Invalid T3 RPC response.")
                if document.get("_tag") == "Ping":
                    send(1, b'{"_tag":"Pong"}')
                elif document.get("_tag") == "Exit" and str(document.get("requestId")) == "0":
                    result = document.get("exit", {})
                    if not isinstance(result, dict) or result.get("_tag") != "Success":
                        raise T3Error("T3 could not report usage. Check read access and update to a compatible T3 version.")
                    return result.get("value")
            raise T3Error("T3 sent too many messages without a usage summary.")
        finally:
            connection.close()


def integer(value, maximum=10**15):
    if type(value) is not int or not 0 <= value <= maximum:
        raise T3Error("T3 returned invalid usage counters.")
    return value


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError
    date = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if date.tzinfo is None:
        raise ValueError
    return int(date.timestamp() * 1000)


def normalize_summary(document, query):
    """Drop all unneeded fields, including filesystem paths and upstream errors."""
    try:
        if not isinstance(document, dict) or type(document.get("contractVersion")) is not int or document["contractVersion"] not in (4, 5):
            raise T3Error("Update T3 Code: usage contract version 4 or 5 is required.")
        for key in ("timeZone", "sinceDay", "untilDay"):
            if document.get(key) != query[key]:
                raise ValueError
        read_at = timestamp(document.get("readAt"))
        if read_at > time.time() * 1000 + 300000:
            raise ValueError
        sources, buckets = document.get("sources"), document.get("buckets")
        if not isinstance(sources, list) or len(sources) > 8 or not isinstance(buckets, list) or len(buckets) > MAX_BUCKETS:
            raise ValueError
        clean_sources, providers = [], set()
        for source in sources:
            fp = source["fingerprint"]
            provider = fp["provider"]
            if provider not in PROVIDERS:
                continue
            if provider in providers or source["status"] not in ("ok", "partial", "missing", "failed"):
                raise ValueError
            providers.add(provider)
            for key in ("hostId", "resolvedHomePath", "volumeId"):
                if not isinstance(fp[key], str) or len(fp[key]) > 4096:
                    raise ValueError
            if not fp["hostId"] or not fp["resolvedHomePath"]:
                raise ValueError
            clean_sources.append({"provider": provider,
                "fingerprint": fingerprint(fp["hostId"], provider, fp["resolvedHomePath"], fp["volumeId"]),
                "status": source["status"], "sessions": integer(source["distinctSessions"], 10**9)})
        clean_buckets, seen = [], set()
        for row in buckets:
            provider = row["provider"]
            if provider not in PROVIDERS:
                continue
            model = row["model"]
            day = row["day"]
            if (provider not in providers or not isinstance(model, str) or not 1 <= len(model) <= 256
                    or not isinstance(day, str) or not query["sinceDay"] <= day <= query["untilDay"]):
                raise ValueError
            datetime.strptime(day, "%Y-%m-%d")
            hour = row.get("hourStart")
            if query.get("resolution") == "hour":
                at = timestamp(hour)
                if not timestamp(query["sinceTime"]) <= at < timestamp(query["untilTime"]):
                    raise ValueError
            elif hour is not None:
                raise ValueError
            key = (provider, model, day, hour)
            if key in seen:
                raise ValueError
            seen.add(key)
            totals = {key: integer(row["totals"][key]) for key in (
                "uncachedInputTokens", "cachedInputTokens", "cacheCreationTokens", "outputTokens", "reasoningTokens")}
            count = integer(row["records"], 10**9)
            if totals["reasoningTokens"] > totals["outputTokens"] or (sum(totals.values()) and not count):
                raise ValueError
            clean_buckets.append({"provider": provider, "model": model, "day": day, "hourStart": hour,
                                  "totals": totals, "records": count})
        return {"readAt": read_at, "sources": clean_sources, "buckets": clean_buckets}
    except (ValueError, TypeError, KeyError, AttributeError, OverflowError) as exc:
        if isinstance(exc, T3Error):
            raise
        raise T3Error("T3 returned incomplete or inconsistent historical usage.") from None


def load_private_json(path, limit):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_size > limit):
                return None
            raw = os.read(fd, limit + 1)
        finally:
            os.close(fd)
        return json.loads(raw) if len(raw) <= limit else None
    except (OSError, ValueError):
        return None


def restore_summary(saved, query):
    # Reuse the wire validator without retaining raw hostnames or paths in cache.
    sources = saved["sources"]
    for source in sources:
        if not re.fullmatch(r"[a-f0-9]{64}", source["fingerprint"]):
            raise ValueError
    raw = {**query, "contractVersion": 5,
        "readAt": datetime.fromtimestamp(saved["readAt"] / 1000, timezone.utc).isoformat(),
        "buckets": saved["buckets"], "sources": [
            {"fingerprint": {"hostId": "cached", "provider": s["provider"],
                             "resolvedHomePath": s["fingerprint"], "volumeId": ""},
             "status": s["status"], "distinctSessions": s["sessions"]} for s in sources]}
    validated = normalize_summary(raw, query)
    for original, cleaned in zip(sources, validated["sources"]):
        cleaned["fingerprint"] = original["fingerprint"]
    return validated


def collect(server, query, days, state_dir, timeout):
    token = read_token(server["tokenFile"])
    identity = digest([server["url"], token])
    cache = state_dir / ("t3-usage-" + digest([identity, days, query["timeZone"]]) + ".json")
    auth_path = state_dir / ("t3-auth-" + identity + ".json")
    auth = load_private_json(auth_path, 16384)
    access = auth.get("access", "") if isinstance(auth, dict) else ""
    if not isinstance(access, str) or len(access) > 8192 or any(ord(c) < 33 or ord(c) > 126 for c in access):
        access = ""
    error = None
    try:
        client = Client(server["url"], timeout)
        try:
            raw = client.rpc(query, access or token)
        except PermissionError:
            if not token:
                raise T3Error("Enter a T3 connection token in Costs settings.") from None
            access = client.exchange(token)
            try:
                atomic_write_json(auth_path, {"access": access})
            except OSError:
                pass
            raw = client.rpc(query, access)
        normalized = normalize_summary(raw, query)
        try:
            atomic_write_json(cache, {"version": 2, "query": query, "summary": normalized})
        except OSError:
            pass
        return normalized, "fresh", ""
    except T3Error as exc:
        error = str(exc)
    except (OSError, ValueError, urllib.error.URLError, http.client.HTTPException, RecursionError):
        error = "Could not read T3 usage. Check the connection, certificate, and server."
    cached = load_private_json(cache, MAX_BYTES)
    if isinstance(cached, dict) and cached.get("version") == 2:
        try:
            normalized = restore_summary(cached["summary"], cached["query"])
            if time.time() * 1000 - normalized["readAt"] <= 32 * 86400000:
                return normalized, "stale", error
        except (ValueError, KeyError, TypeError, AttributeError, OverflowError):
            pass
    return None, "unavailable", error
