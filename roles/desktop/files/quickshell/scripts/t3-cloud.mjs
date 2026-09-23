#!/usr/bin/env node

// T3 Connect authentication and relay bootstrap for the Quickshell client.
//
// Relay access requires the `t3-relay` Clerk JWT template. The public CLI OAuth
// token can manage linked environments but is not accepted by the relay DPoP
// exchange, so this helper owns a native Clerk session, completes its OAuth
// flow in the browser, then performs the same DPoP exchanges as the web client.

import { spawn } from "node:child_process";
import {
    createHash,
    createPrivateKey,
    generateKeyPairSync,
    randomBytes,
    randomUUID,
    sign as signBytes,
    timingSafeEqual,
} from "node:crypto";
import { promises as fs } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { AsyncLocalStorage } from "node:async_hooks";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);
const { safeHttpUrl } = require("../Common/ExternalUrl.js");

export const CLOUD_CONFIG = Object.freeze({
    clerkUrl: process.env.T3CODE_CLERK_URL?.trim() || "https://clerk.t3.codes",
    relayUrl: process.env.T3CODE_RELAY_URL?.trim() || "https://relay.t3.codes",
    browserCommand: process.env.T3CODE_BROWSER_COMMAND?.trim() || "xdg-open",
    mimeCommand: process.env.T3CODE_MIME_COMMAND?.trim() || "xdg-mime",
});

const RELAY_CLIENT_ID = "t3-web";
const RELAY_CONNECT_SCOPE = "environment:connect";
const STANDARD_ENVIRONMENT_SCOPES = [
    "orchestration:read",
    "orchestration:operate",
    "terminal:operate",
    "review:write",
    "relay:read",
];
const ENVIRONMENT_REFRESH_MARGIN_MS = 60 * 1000;
const REQUEST_TIMEOUT_MS = 15_000;
const LOGIN_TIMEOUT_MS = 10 * 60 * 1000;
const CLERK_API_VERSION = "2026-05-12";
const CLERK_JS_VERSION = "6.29.2";
const CLERK_NATIVE_ELECTRON_VERSION = "0.0.33";
const P256_ORDER = BigInt("0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551");

const userHome = process.env.HOME || os.homedir();
const stateRoot = process.env.T3CODE_CLOUD_STATE_DIR
    || process.env.XDG_STATE_HOME
    || path.join(userHome, ".local", "state");
const privateStateDir = path.join(stateRoot, "t3code-cloud");

export const STATE_PATHS = Object.freeze({
    legacyCredentials: path.join(privateStateDir, "credentials.json"),
    clerkClient: path.join(privateStateDir, "clerk-client.json"),
    browserLogin: path.join(privateStateDir, "browser-login.json"),
    dpopKey: path.join(privateStateDir, "dpop-key.json"),
    sessionEpoch: path.join(privateStateDir, "session-epoch.json"),
    stateLock: path.join(privateStateDir, ".state.lock"),
    browserLoginLock: path.join(privateStateDir, ".browser-login.lock"),
    connection: process.env.T3CODE_PANEL_STATE_PATH
        || path.join(stateRoot, "t3code-bar.json"),
});

const sessionEpochContext = new AsyncLocalStorage();

// Exit status of a non-interactive command that found no active T3 Connect
// browser session to mint credentials from. Unlike every other failure it
// cannot clear up by itself, so the panel offers Sign in instead of retrying
// (Common/T3Connection.qml, signInRequiredExit).
export const SIGN_IN_REQUIRED_EXIT = 3;

class SignInRequiredError extends Error {
    constructor() {
        super("Sign in to T3 Connect from the panel, then try again.");
        this.name = "SignInRequiredError";
    }
}

class SessionChangedError extends Error {
    constructor() {
        super("T3 Connect session changed while this request was running.");
        this.name = "SessionChangedError";
    }
}

class HttpError extends Error {
    constructor(message, status) {
        super(message);
        this.name = "HttpError";
        this.status = status;
    }
}

function base64Url(value) {
    return Buffer.from(value).toString("base64url");
}

function sha256(value) {
    return createHash("sha256").update(value).digest();
}

function safeJsonParse(value) {
    try {
        return JSON.parse(value);
    } catch {
        return null;
    }
}

async function readJson(filePath) {
    try {
        return safeJsonParse(await fs.readFile(filePath, "utf8"));
    } catch (error) {
        if (error?.code === "ENOENT")
            return null;
        throw error;
    }
}

async function writePrivateJsonRaw(filePath, value) {
    const directory = path.dirname(filePath);
    await fs.mkdir(directory, { recursive: true, mode: 0o700 });
    await fs.chmod(directory, 0o700);
    const temporary = `${filePath}.${process.pid}.${randomUUID()}.tmp`;
    try {
        await fs.writeFile(temporary, JSON.stringify(value, null, 2) + "\n", {
            mode: 0o600,
            flag: "wx",
        });
        await fs.chmod(temporary, 0o600);
        await fs.rename(temporary, filePath);
        await fs.chmod(filePath, 0o600);
    } finally {
        await fs.rm(temporary, { force: true }).catch(() => undefined);
    }
}

async function readSessionEpochRaw() {
    const stored = await readJson(STATE_PATHS.sessionEpoch);
    const value = Number(stored?.value);
    return Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

async function acquireKernelLock(filePath, options = {}) {
    await fs.mkdir(privateStateDir, { recursive: true, mode: 0o700 });
    await fs.chmod(privateStateDir, 0o700);
    // util-linux flock keeps the exclusion in the kernel, so process death,
    // reboot, PID reuse, and competing stale-lock cleanup cannot strand or
    // accidentally unlink ownership. The constant child command reports when
    // the lock is held and then waits for this process to close its stdin.
    const nonblocking = options.nonblocking === true;
    const conflictMessage = options.conflictMessage
        || "Timed out waiting for the T3 Connect state lock.";
    const lockArguments = [
        "--exclusive",
        ...(nonblocking
            ? ["--nonblock"]
            : ["--wait", String(REQUEST_TIMEOUT_MS / 1000)]),
        "--conflict-exit-code",
        "75",
        filePath,
        "bash",
        "-c",
        'printf "acquired\\n"; cat >/dev/null',
    ];
    const child = spawn("flock", lockArguments, { stdio: ["pipe", "pipe", "pipe"] });
    child.stdin.on("error", () => undefined);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    let stdout = "";
    let stderr = "";
    return new Promise((resolve, reject) => {
        let settled = false;
        const timer = setTimeout(() => {
            if (settled)
                return;
            settled = true;
            child.kill("SIGKILL");
            reject(new Error(nonblocking
                ? "Timed out starting the T3 Connect browser-login lock."
                : conflictMessage));
        }, nonblocking ? 2000 : REQUEST_TIMEOUT_MS + 1000);
        const fail = error => {
            if (settled)
                return;
            settled = true;
            clearTimeout(timer);
            child.kill("SIGKILL");
            reject(error);
        };
        child.stderr.on("data", chunk => stderr += chunk);
        child.once("error", fail);
        child.once("close", code => fail(code === 75
            ? new Error(conflictMessage)
            : new Error(
                `Could not acquire the T3 Connect state lock (status ${code}`
                + `${stderr.trim() ? `: ${stderr.trim()}` : ""}).`,
            )));
        child.stdout.on("data", chunk => {
            stdout += chunk;
            if (!settled && stdout.includes("acquired\n")) {
                settled = true;
                clearTimeout(timer);
                resolve(child);
            }
        });
    });
}

async function acquireStateLock() {
    return acquireKernelLock(STATE_PATHS.stateLock);
}

async function acquireBrowserLoginLock() {
    return acquireKernelLock(STATE_PATHS.browserLoginLock, {
        nonblocking: true,
        conflictMessage: "A T3 Connect sign-in is already in progress.",
    });
}

async function releaseKernelLock(child) {
    if (child.exitCode !== null)
        return;
    await new Promise(resolve => {
        const timer = setTimeout(() => child.kill("SIGKILL"), 1000);
        child.once("close", () => {
            clearTimeout(timer);
            resolve();
        });
        child.stdin.end();
    });
}

async function withStateLock(action) {
    const child = await acquireStateLock();
    try {
        return await action();
    } finally {
        await releaseKernelLock(child);
    }
}

async function writePrivateJson(filePath, value) {
    const expectedEpoch = sessionEpochContext.getStore();
    if (expectedEpoch === undefined || filePath === STATE_PATHS.sessionEpoch)
        return writePrivateJsonRaw(filePath, value);
    return withStateLock(async () => {
        if (await readSessionEpochRaw() !== expectedEpoch)
            throw new SessionChangedError();
        await writePrivateJsonRaw(filePath, value);
    });
}

async function removePrivatePath(filePath) {
    const expectedEpoch = sessionEpochContext.getStore();
    if (expectedEpoch === undefined)
        return fs.rm(filePath, { force: true });
    return withStateLock(async () => {
        if (await readSessionEpochRaw() !== expectedEpoch)
            throw new SessionChangedError();
        await fs.rm(filePath, { force: true });
    });
}

async function removeOwnedBrowserLogin(operationId) {
    const expectedEpoch = sessionEpochContext.getStore();
    return withStateLock(async () => {
        if (expectedEpoch !== undefined
                && await readSessionEpochRaw() !== expectedEpoch)
            throw new SessionChangedError();
        const pending = await readJson(STATE_PATHS.browserLogin);
        if (pending?.operationId === operationId)
            await fs.rm(STATE_PATHS.browserLogin, { force: true });
    });
}

function validateServiceOrigin(raw, label) {
    const url = new URL(raw);
    const loopback = url.protocol === "http:"
        && ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname);
    if ((url.protocol !== "https:" && !loopback) || url.username || url.password)
        throw new Error(`${label} must be a secure HTTPS origin.`);
    return url.origin;
}

function safeHttpReason(body) {
    if (!body || typeof body !== "object")
        return "";
    for (const key of ["reason", "code", "error"]) {
        const value = body[key];
        if (typeof value === "string" && /^[a-z0-9._ -]{1,80}$/i.test(value))
            return value;
    }
    return "";
}

async function requestJson(url, options, action) {
    let response;
    try {
        response = await fetch(url, {
            ...options,
            redirect: "error",
            signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        });
    } catch (error) {
        if (error?.name === "TimeoutError")
            throw new Error(`${action} timed out.`);
        throw new Error(`${action} could not reach T3 Connect.`);
    }
    const text = await response.text();
    const body = text === "" ? {} : safeJsonParse(text);
    if (!response.ok) {
        const reason = safeHttpReason(body);
        throw new HttpError(
            `${action} failed (HTTP ${response.status}${reason ? ` · ${reason}` : ""}).`,
            response.status,
        );
    }
    if (!body || typeof body !== "object")
        throw new Error(`${action} returned an unreadable response.`);
    return body;
}

async function clerkNativeRequest(resource, clientToken, options, action) {
    const clerk = validateServiceOrigin(CLOUD_CONFIG.clerkUrl, "Clerk URL");
    const url = new URL(resource, `${clerk}/`);
    url.searchParams.set("__clerk_api_version", CLERK_API_VERSION);
    url.searchParams.set("_clerk_js_version", CLERK_JS_VERSION);
    url.searchParams.set("_is_native", "1");
    url.searchParams.set("_electron_sdk_version", CLERK_NATIVE_ELECTRON_VERSION);
    const headers = { ...options?.headers };
    if (clientToken)
        headers.authorization = `Bearer ${clientToken}`;
    if (options?.body !== undefined && !headers["content-type"])
        headers["content-type"] = "application/json";
    let response;
    try {
        response = await fetch(url, {
            ...options,
            headers,
            redirect: "error",
            signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        });
    } catch (error) {
        if (error?.name === "TimeoutError")
            throw new Error(`${action} timed out.`);
        throw new Error(`${action} could not reach T3 Connect.`);
    }
    const text = await response.text();
    const body = text === "" ? {} : safeJsonParse(text);
    if (!response.ok) {
        const responseBody = body?.response && typeof body.response === "object"
            ? body.response : body;
        const reason = safeHttpReason(responseBody);
        throw new HttpError(
            `${action} failed (HTTP ${response.status}${reason ? ` · ${reason}` : ""}).`,
            response.status,
        );
    }
    if (!body || typeof body !== "object")
        throw new Error(`${action} returned an unreadable response.`);
    const authorization = response.headers.get("authorization") || "";
    return {
        data: body.response && typeof body.response === "object" ? body.response : body,
        client: body.client && typeof body.client === "object" ? body.client : null,
        clientToken: authorization.startsWith("Bearer ")
            ? authorization.slice("Bearer ".length) : authorization || clientToken,
    };
}

async function rememberClerkClientToken(clientToken) {
    if (typeof clientToken !== "string" || clientToken === "")
        throw new Error("T3 Connect returned no browser session credential.");
    await writePrivateJson(STATE_PATHS.clerkClient, { clientToken });
    return clientToken;
}

async function initializeClerkClient() {
    const result = await clerkNativeRequest(
        "/v1/client",
        "",
        { method: "GET" },
        "T3 Connect browser session setup",
    );
    await rememberClerkClientToken(result.clientToken);
    return result;
}

async function currentClerkClient() {
    const stored = await readJson(STATE_PATHS.clerkClient);
    if (typeof stored?.clientToken !== "string" || stored.clientToken === "")
        return initializeClerkClient();
    try {
        const result = await clerkNativeRequest(
            "/v1/client",
            stored.clientToken,
            { method: "GET" },
            "T3 Connect sign-in check",
        );
        await rememberClerkClientToken(result.clientToken);
        return result;
    } catch (error) {
        if (!(error instanceof HttpError) || ![401, 403].includes(error.status))
            throw error;
        await removePrivatePath(STATE_PATHS.clerkClient);
        return initializeClerkClient();
    }
}

function clerkSessionIdentity(session) {
    const user = session?.user;
    if (!user || typeof user !== "object")
        return "";
    const addresses = Array.isArray(user.email_addresses) ? user.email_addresses : [];
    const primary = addresses.find(address => address?.id === user.primary_email_address_id)
        || addresses[0];
    if (typeof primary?.email_address === "string" && primary.email_address.trim() !== "")
        return primary.email_address.trim();
    return typeof user.username === "string" ? user.username.trim() : "";
}

function jwtExpiryEpochMs(token) {
    try {
        const claims = safeJsonParse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"));
        return Number.isFinite(claims?.exp) ? claims.exp * 1000 : Date.now() + 30_000;
    } catch {
        return Date.now() + 30_000;
    }
}

export async function t3CodeRelayCredentials() {
    const clientResult = await currentClerkClient();
    const sessions = Array.isArray(clientResult.data.sessions)
        ? clientResult.data.sessions : [];
    const activeSession = sessions.find(session =>
        session?.id === clientResult.data.last_active_session_id
            && session?.status === "active")
        || sessions.find(session => session?.status === "active");
    if (!activeSession?.id)
        return null;

    const tokenResult = await clerkNativeRequest(
        `/v1/client/sessions/${encodeURIComponent(activeSession.id)}/tokens/t3-relay?debug=skip_cache`,
        clientResult.clientToken,
        { method: "POST", body: "{}" },
        "T3 Connect relay sign-in",
    );
    await rememberClerkClientToken(tokenResult.clientToken);
    if (typeof tokenResult.data.jwt !== "string" || tokenResult.data.jwt === "")
        throw new Error("T3 Connect returned no relay credential.");
    return {
        source: "t3-connect-session",
        accessToken: tokenResult.data.jwt,
        refreshToken: "",
        expiresAtEpochMs: jwtExpiryEpochMs(tokenResult.data.jwt),
        identity: clerkSessionIdentity(activeSession)
            || decodeIdentity("", tokenResult.data.jwt),
    };
}

function runCommand(command, args, action) {
    return new Promise((resolve, reject) => {
        const child = spawn(command, args, { stdio: "ignore" });
        child.once("error", () => reject(new Error(`${action} is unavailable.`)));
        child.once("close", status => status === 0
            ? resolve() : reject(new Error(`${action} failed.`)));
    });
}

function openBrowser(url) {
    return new Promise((resolve, reject) => {
        const safeUrl = safeHttpUrl(url);
        if (safeUrl === "") {
            reject(new Error("Refusing to open an unsupported browser URL."));
            return;
        }
        const child = spawn(CLOUD_CONFIG.browserCommand, [safeUrl], {
            detached: true,
            stdio: "ignore",
        });
        child.once("error", () => reject(new Error("Could not open your browser.")));
        child.once("spawn", () => {
            child.unref();
            resolve();
        });
    });
}

function formBody(entries) {
    return new URLSearchParams(entries).toString();
}

function loginPage() {
    return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Sign in · T3 Connect</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#15151d;color:#eeeef5;font:16px system-ui,sans-serif}.card{width:min(430px,calc(100% - 32px));padding:36px;border:1px solid #343443;border-radius:18px;background:#1d1d27;text-align:center;box-shadow:0 24px 70px #0008}h1{margin:0 0 10px;font-size:25px}p{margin:0 0 28px;color:#b7b7c8;line-height:1.5}.actions{display:grid;gap:12px}a{display:block;padding:13px 18px;border-radius:10px;background:#303553;color:#f4f4ff;text-decoration:none;font-weight:700}a:hover{background:#3b4268}.fine{margin:24px 0 0;font-size:13px;color:#858598}
</style></head><body><main class="card"><h1>T3 Connect</h1><p>Choose an account to access your linked environments.</p><div class="actions"><a href="/start?provider=google">Continue with Google</a><a href="/start?provider=github">Continue with GitHub</a></div><p class="fine">You’ll return to the T3 Code panel automatically.</p></main></body></html>`;
}

function sendHtml(response, status, html) {
    response.writeHead(status, {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
        "x-content-type-options": "nosniff",
    });
    response.end(html);
}

function safeSecretMatch(provided, expected) {
    const left = Buffer.from(provided);
    const right = Buffer.from(expected);
    return left.length === right.length && timingSafeEqual(left, right);
}

function readSmallBody(request, maximum = 4096) {
    return new Promise((resolve, reject) => {
        let body = "";
        request.setEncoding("utf8");
        request.on("data", chunk => {
            body += chunk;
            if (body.length > maximum) {
                reject(new Error("T3 Connect callback was too large."));
                request.destroy();
            }
        });
        request.once("end", () => resolve(body));
        request.once("error", reject);
    });
}

async function browserSignIn() {
    const operationId = randomUUID();
    const operationLock = await acquireBrowserLoginLock();
    try {
        return await runOwnedBrowserSignIn(operationId);
    } finally {
        await releaseKernelLock(operationLock);
    }
}

async function runOwnedBrowserSignIn(operationId) {
    const initial = await currentClerkClient();
    let clientToken = initial.clientToken;
    let signInId = "";
    let settled = false;
    let finishResolve;
    let finishReject;
    const finished = new Promise((resolve, reject) => {
        finishResolve = resolve;
        finishReject = reject;
    });
    // A generation watcher can reject this before control reaches `await
    // finished` (for example while xdg-mime is running). Attach a handler now
    // so Node never treats that intentional cancellation as unhandled.
    void finished.catch(() => undefined);
    const settle = (error = null) => {
        if (settled)
            return;
        settled = true;
        if (error)
            finishReject(error);
        else
            finishResolve();
    };
    const callbackSecret = randomBytes(32).toString("base64url");
    const server = http.createServer((request, response) => {
        void (async () => {
            const localUrl = new URL(request.url || "/", "http://127.0.0.1");
            if (request.method === "GET" && localUrl.pathname === "/") {
                sendHtml(response, 200, loginPage());
                return;
            }
            if (request.method === "GET" && localUrl.pathname === "/start") {
                const provider = localUrl.searchParams.get("provider");
                if (!["google", "github"].includes(provider)) {
                    response.writeHead(400).end();
                    return;
                }
                if (signInId !== "") {
                    response.writeHead(409).end();
                    return;
                }
                signInId = "starting";
                try {
                    const signIn = await clerkNativeRequest(
                        "/v1/client/sign_ins",
                        clientToken,
                        {
                            method: "POST",
                            headers: { "content-type": "application/x-www-form-urlencoded" },
                            body: formBody({
                                strategy: `oauth_${provider}`,
                                redirect_url: "t3code://app/",
                                action_complete_redirect_url: "t3code://app/",
                            }),
                        },
                        "T3 Connect browser sign-in",
                    );
                    clientToken = await rememberClerkClientToken(signIn.clientToken);
                    const verificationUrl = signIn.data?.first_factor_verification
                        ?.external_verification_redirect_url;
                    const target = new URL(verificationUrl);
                    if (target.protocol !== "https:" || !signIn.data?.id)
                        throw new Error("T3 Connect returned an invalid browser sign-in.");
                    signInId = signIn.data.id;
                    response.writeHead(302, {
                        location: target.toString(),
                        "cache-control": "no-store",
                    });
                    response.end();
                } catch {
                    signInId = "";
                    sendHtml(response, 502, loginPage().replace(
                        "Choose an account to access your linked environments.",
                        "Sign-in could not start. Return to the panel and try again.",
                    ));
                }
                return;
            }
            if (request.method === "POST" && localUrl.pathname === "/oauth-callback") {
                const provided = String(request.headers.authorization || "")
                    .replace(/^Bearer\s+/i, "");
                if (!safeSecretMatch(provided, callbackSecret)) {
                    response.writeHead(403).end();
                    return;
                }
                try {
                    const rawCallback = await readSmallBody(request);
                    const callback = new URL(rawCallback);
                    const callbackFailed = callback.searchParams.get("__clerk_status") === "failed";
                    const nonce = callback.searchParams.get("rotating_token_nonce") || "";
                    if (callback.protocol !== "t3code:" || callback.hostname !== "app"
                            || callbackFailed || nonce === "" || signInId === "")
                        throw new Error("T3 Connect browser sign-in was cancelled or invalid.");
                    const completed = await clerkNativeRequest(
                        `/v1/client/sign_ins/${encodeURIComponent(signInId)}?rotating_token_nonce=${encodeURIComponent(nonce)}`,
                        clientToken,
                        { method: "GET" },
                        "T3 Connect browser callback",
                    );
                    clientToken = await rememberClerkClientToken(completed.clientToken);
                    const client = completed.client || (await currentClerkClient()).data;
                    const sessions = Array.isArray(client?.sessions) ? client.sessions : [];
                    if (!sessions.some(session => session?.status === "active"))
                        throw new Error("T3 Connect did not create an active session.");
                    response.writeHead(200, {
                        "content-type": "application/json",
                        "cache-control": "no-store",
                    });
                    response.end('{"handled":true}', () => settle());
                } catch (error) {
                    // This was still the panel's callback. Consume it even
                    // when Clerk reports a cancellation/failure, otherwise
                    // the launcher would fall through and open Nightly.
                    response.writeHead(200, {
                        "content-type": "application/json",
                        "cache-control": "no-store",
                    });
                    response.end('{"handled":true,"completed":false}', () => {
                        settle(error instanceof Error ? error
                            : new Error("T3 Connect browser sign-in failed."));
                    });
                }
                return;
            }
            response.writeHead(404).end();
        })().catch(error => {
            if (!response.headersSent)
                response.writeHead(500);
            response.end(() => {
                settle(error instanceof Error ? error
                    : new Error("T3 Connect sign-in failed."));
            });
        });
    });
    server.on("clientError", (_error, socket) => socket.destroy());
    await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", resolve);
    });
    const port = server.address().port;
    const expectedEpoch = sessionEpochContext.getStore();
    let epochCheckRunning = false;
    const epochWatch = expectedEpoch === undefined ? null : setInterval(() => {
        if (epochCheckRunning)
            return;
        epochCheckRunning = true;
        void readSessionEpochRaw().then(currentEpoch => {
            if (currentEpoch !== expectedEpoch)
                settle(new SessionChangedError());
        }).catch(error => settle(error instanceof Error ? error
            : new Error("Could not verify the T3 Connect session.")))
            .finally(() => epochCheckRunning = false);
    }, 100);
    epochWatch?.unref();
    const timeout = setTimeout(() => settle(new Error(
        "T3 Connect sign-in timed out. Try again from the panel.",
    )), LOGIN_TIMEOUT_MS);
    try {
        await writePrivateJson(STATE_PATHS.browserLogin, {
            version: 1,
            operationId,
            port,
            callbackSecret,
            expiresAtEpochMs: Date.now() + LOGIN_TIMEOUT_MS,
        });
        await runCommand(
            CLOUD_CONFIG.mimeCommand,
            ["default", "t3code-nightly.desktop", "x-scheme-handler/t3code"],
            "T3 Connect callback registration",
        );
        await openBrowser(`http://127.0.0.1:${port}/`);
        await finished;
    } finally {
        clearTimeout(timeout);
        if (epochWatch !== null)
            clearInterval(epochWatch);
        try {
            await removeOwnedBrowserLogin(operationId);
        } finally {
            await new Promise(resolve => {
                // Chrome may leave a speculative localhost socket waiting for its
                // first request. server.close() waits for Node's 60-second header
                // timeout on that socket, even though OAuth is already complete.
                // Callback settlement happens only after response.end() flushes,
                // so every remaining connection is safe to close immediately.
                server.close(resolve);
                server.closeAllConnections();
            });
        }
    }
}

async function forwardBrowserCallback(rawCallback) {
    const callback = new URL(rawCallback);
    if (callback.protocol !== "t3code:" || callback.hostname !== "app")
        throw new Error("This is not a T3 Connect browser callback.");
    const pending = await readJson(STATE_PATHS.browserLogin);
    if (!Number.isInteger(pending?.port) || pending.port < 1 || pending.port > 65535
            || typeof pending?.callbackSecret !== "string"
            || Number(pending?.expiresAtEpochMs) < Date.now())
        throw new Error("No T3 Connect browser sign-in is waiting.");
    const response = await fetch(`http://127.0.0.1:${pending.port}/oauth-callback`, {
        method: "POST",
        headers: {
            authorization: `Bearer ${pending.callbackSecret}`,
            "content-type": "text/plain; charset=utf-8",
        },
        body: callback.toString(),
        redirect: "error",
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS + 5000),
    });
    const responseBody = await response.text();
    if (!response.ok)
        throw new Error("T3 Connect browser callback could not be completed.");
    if (safeJsonParse(responseBody)?.handled !== true)
        throw new Error("T3 Connect browser callback was not accepted.");
    return { handled: true };
}

async function waitForT3CodeRelayCredentials(interactive) {
    const current = await t3CodeRelayCredentials();
    if (current)
        return current;
    if (!interactive)
        throw new SignInRequiredError();

    await browserSignIn();
    const credentials = await t3CodeRelayCredentials();
    if (!credentials)
        throw new Error("T3 Connect browser sign-in did not complete.");
    return credentials;
}

function decodeIdentity(idToken, fallbackToken = "") {
    for (const token of [idToken, fallbackToken]) {
        if (typeof token !== "string")
            continue;
        const payload = token.split(".")[1];
        if (!payload)
            continue;
        const claims = safeJsonParse(Buffer.from(payload, "base64url").toString("utf8"));
        if (!claims || typeof claims !== "object")
            continue;
        for (const key of ["email", "preferred_username", "sub"]) {
            if (typeof claims[key] === "string" && claims[key].trim() !== "")
                return claims[key].trim();
        }
    }
    return "";
}

function activatePanel() {
    try {
        const child = spawn("qs", ["ipc", "call", "popouts", "open", "t3code"], {
            detached: true,
            stdio: "ignore",
        });
        child.once("error", () => undefined);
        child.unref();
    } catch {
        // Authentication is complete even when no running shell can be found.
    }
}

function publicJwkFrom(privateJwk) {
    return {
        kty: privateJwk.kty,
        crv: privateJwk.crv,
        x: privateJwk.x,
        y: privateJwk.y,
    };
}

export function computeDpopThumbprint(publicJwk) {
    const canonical = JSON.stringify({
        crv: publicJwk.crv,
        kty: publicJwk.kty,
        x: publicJwk.x,
        y: publicJwk.y,
    });
    return base64Url(sha256(canonical));
}

async function loadOrCreateDpopKey() {
    const stored = await readJson(STATE_PATHS.dpopKey);
    if (stored?.privateJwk && stored?.publicJwk) {
        const thumbprint = computeDpopThumbprint(stored.publicJwk);
        if (thumbprint === stored.thumbprint) {
            return {
                ...stored,
                privateKey: createPrivateKey({ key: stored.privateJwk, format: "jwk" }),
            };
        }
    }
    const generated = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const privateJwk = generated.privateKey.export({ format: "jwk" });
    const publicJwk = publicJwkFrom(privateJwk);
    const persisted = {
        privateJwk,
        publicJwk,
        thumbprint: computeDpopThumbprint(publicJwk),
    };
    await writePrivateJson(STATE_PATHS.dpopKey, persisted);
    return { ...persisted, privateKey: generated.privateKey };
}

function normalizedProofUrl(raw) {
    const url = new URL(raw);
    url.search = "";
    url.hash = "";
    return url.toString();
}

function normalizeP256LowS(signature) {
    // @noble/curves, used by the T3 server verifier, rejects malleable high-S
    // ECDSA signatures. OpenSSL may emit either form, so canonicalize the
    // 64-byte JOSE r||s value before putting it in the compact JWT.
    const s = BigInt(`0x${signature.subarray(32).toString("hex")}`);
    if (s <= P256_ORDER / 2n)
        return signature;
    const normalized = Buffer.from(signature);
    Buffer.from((P256_ORDER - s).toString(16).padStart(64, "0"), "hex").copy(normalized, 32);
    return normalized;
}

export function createDpopProof({ method, url, accessToken = "", key, now = Date.now() }) {
    const header = base64Url(JSON.stringify({
        typ: "dpop+jwt",
        alg: "ES256",
        jwk: key.publicJwk,
    }));
    const payload = {
        htm: method.toUpperCase(),
        htu: normalizedProofUrl(url),
        jti: randomUUID(),
        iat: Math.floor(now / 1000),
        ...(accessToken ? { ath: base64Url(sha256(accessToken)) } : {}),
    };
    const encodedPayload = base64Url(JSON.stringify(payload));
    const signingInput = `${header}.${encodedPayload}`;
    const signature = normalizeP256LowS(signBytes("sha256", Buffer.from(signingInput), {
        key: key.privateKey,
        dsaEncoding: "ieee-p1363",
    }));
    return `${signingInput}.${base64Url(signature)}`;
}

async function relayAccessToken(credentials, key, scopes) {
    const relay = validateServiceOrigin(CLOUD_CONFIG.relayUrl, "Relay URL");
    const url = `${relay}/v1/client/dpop-token`;
    const response = await requestJson(url, {
        method: "POST",
        headers: {
            "content-type": "application/x-www-form-urlencoded",
            dpop: createDpopProof({ method: "POST", url, key }),
        },
        body: formBody({
            grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
            subject_token: credentials.accessToken,
            subject_token_type: "urn:ietf:params:oauth:token-type:jwt",
            requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
            resource: relay,
            scope: scopes.join(" "),
            client_id: RELAY_CLIENT_ID,
        }),
    }, "T3 Connect relay authorization");
    if (typeof response.access_token !== "string" || response.token_type !== "DPoP")
        throw new Error("T3 Connect returned an invalid relay token.");
    return response.access_token;
}

async function linkedEnvironments(credentials) {
    const relay = validateServiceOrigin(CLOUD_CONFIG.relayUrl, "Relay URL");
    const response = await requestJson(`${relay}/v1/environments`, {
        method: "GET",
        headers: { authorization: `Bearer ${credentials.accessToken}` },
    }, "T3 Connect environment discovery");
    return Array.isArray(response.environments) ? response.environments : [];
}

async function preferredEnvironmentId(previousState, environments) {
    if (typeof previousState?.environmentId === "string"
            && environments.some(item => item.environmentId === previousState.environmentId))
        return previousState.environmentId;
    try {
        const localId = (await fs.readFile(path.join(userHome, ".t3", "userdata",
            "environment-id"), "utf8")).trim();
        if (environments.some(item => item.environmentId === localId))
            return localId;
    } catch {
        // A remote-only client has no local environment id.
    }
    return environments.toSorted((left, right) =>
        String(right.linkedAt || "").localeCompare(String(left.linkedAt || "")))[0]?.environmentId
        || "";
}

function checkedEndpoint(endpoint) {
    if (!endpoint || typeof endpoint !== "object")
        throw new Error("T3 Connect returned no managed environment endpoint.");
    return {
        httpBaseUrl: validateServiceOrigin(endpoint.httpBaseUrl, "Environment HTTP URL"),
        wsBaseUrl: (() => {
            const url = new URL(endpoint.wsBaseUrl);
            const loopback = url.protocol === "ws:"
                && ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname);
            if ((url.protocol !== "wss:" && !loopback) || url.username || url.password)
                throw new Error("Environment WebSocket URL must be secure.");
            return url.toString().replace(/\/$/, "");
        })(),
        providerKind: typeof endpoint.providerKind === "string" ? endpoint.providerKind : "",
    };
}

async function exchangeEnvironmentToken(endpoint, bootstrapCredential, key) {
    const url = `${endpoint.httpBaseUrl}/oauth/token`;
    const response = await requestJson(url, {
        method: "POST",
        headers: {
            "content-type": "application/x-www-form-urlencoded",
            dpop: createDpopProof({ method: "POST", url, key }),
        },
        body: formBody({
            grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
            subject_token: bootstrapCredential,
            subject_token_type: "urn:t3:params:oauth:token-type:environment-bootstrap",
            requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
            scope: STANDARD_ENVIRONMENT_SCOPES.join(" "),
            client_label: "Quickshell T3 panel",
            client_device_type: "desktop",
            client_os: "linux",
        }),
    }, "T3 Connect environment authorization");
    if (typeof response.access_token !== "string" || response.token_type !== "DPoP"
            || typeof response.expires_in !== "number")
        throw new Error("T3 Connect returned an invalid environment token.");
    return response;
}

export async function connectCloud(credentials) {
    if (credentials?.source !== "t3-connect-session" || !credentials.accessToken)
        throw new Error("A T3 Connect browser sign-in is required.");
    const currentCredentials = credentials;
    const environments = await linkedEnvironments(currentCredentials);
    const previousState = await readJson(STATE_PATHS.connection);
    if (environments.length === 0) {
        const state = {
            authMode: "cloud",
            cloudStatus: "no-environments",
            cloudIdentity: currentCredentials.identity || "signed in",
            environmentCandidates: [],
        };
        await writePrivateJson(STATE_PATHS.connection, state);
        return state;
    }

    const environmentId = await preferredEnvironmentId(previousState, environments);
    const environment = environments.find(item => item.environmentId === environmentId);
    if (!environment)
        throw new Error("T3 Connect could not select a linked environment.");

    const key = await loadOrCreateDpopKey();
    const relayToken = await relayAccessToken(currentCredentials, key, [RELAY_CONNECT_SCOPE]);
    const relay = validateServiceOrigin(CLOUD_CONFIG.relayUrl, "Relay URL");
    const connectUrl = `${relay}/v1/environments/${encodeURIComponent(environmentId)}/connect`;
    const connected = await requestJson(connectUrl, {
        method: "POST",
        headers: {
            authorization: `DPoP ${relayToken}`,
            dpop: createDpopProof({
                method: "POST",
                url: connectUrl,
                accessToken: relayToken,
                key,
            }),
            "content-type": "application/json",
        },
        body: JSON.stringify({ clientKeyThumbprint: key.thumbprint }),
    }, "T3 Connect environment connection");
    if (connected.environmentId !== environmentId || typeof connected.credential !== "string")
        throw new Error("T3 Connect returned an invalid environment connection.");

    const endpoint = checkedEndpoint(connected.endpoint || environment.endpoint);
    const environmentToken = await exchangeEnvironmentToken(endpoint, connected.credential, key);
    const state = {
        authMode: "cloud",
        cloudStatus: "connected",
        cloudIdentity: currentCredentials.identity || "signed in",
        environmentId,
        environmentLabel: typeof environment.label === "string" ? environment.label : "T3 Connect",
        httpBaseUrl: endpoint.httpBaseUrl,
        wsBaseUrl: endpoint.wsBaseUrl,
        accessToken: environmentToken.access_token,
        tokenType: "DPoP",
        expiresAtEpochMs: Date.now() + environmentToken.expires_in * 1000,
        scope: typeof environmentToken.scope === "string"
            ? environmentToken.scope : STANDARD_ENVIRONMENT_SCOPES.join(" "),
    };
    await writePrivateJson(STATE_PATHS.connection, state);
    return state;
}

async function usableConnection() {
    const current = await readJson(STATE_PATHS.connection);
    if (current?.authMode === "cloud" && current?.tokenType === "DPoP"
            && current?.accessToken && current?.httpBaseUrl && current?.wsBaseUrl
            && Number(current.expiresAtEpochMs) > Date.now() + ENVIRONMENT_REFRESH_MARGIN_MS)
        return current;
    const credentials = await waitForT3CodeRelayCredentials(false);
    const connected = await connectCloud(credentials);
    if (!connected.accessToken)
        throw new Error("No environments are linked to this T3 Connect account.");
    return connected;
}

async function requestWebSocketTicket(connection, key) {
    const url = `${connection.httpBaseUrl}/api/auth/websocket-ticket`;
    return requestJson(url, {
        method: "POST",
        headers: {
            authorization: `DPoP ${connection.accessToken}`,
            dpop: createDpopProof({
                method: "POST",
                url,
                accessToken: connection.accessToken,
                key,
            }),
        },
    }, "T3 Connect WebSocket authorization");
}

export async function issueWebSocketTicket() {
    let connection = await usableConnection();
    const key = await loadOrCreateDpopKey();
    let issued;
    try {
        issued = await requestWebSocketTicket(connection, key);
    } catch (error) {
        if (!(error instanceof HttpError) || ![401, 403].includes(error.status))
            throw error;
        const credentials = await waitForT3CodeRelayCredentials(false);
        connection = await connectCloud(credentials);
        issued = await requestWebSocketTicket(connection, key);
    }
    if (typeof issued.ticket !== "string" || issued.ticket === "")
        throw new Error("T3 Connect returned no WebSocket ticket.");
    const socketUrl = new URL(connection.wsBaseUrl);
    if (socketUrl.pathname === "" || socketUrl.pathname === "/")
        socketUrl.pathname = "/ws";
    socketUrl.searchParams.set("wsTicket", issued.ticket);
    return { socketUrl: socketUrl.toString() };
}

async function cloudStatus() {
    const connection = await readJson(STATE_PATHS.connection);
    let credentials = null;
    try {
        credentials = await t3CodeRelayCredentials();
    } catch {
        // Status is informational; the next explicit sign-in surfaces details.
    }
    return {
        signedIn: Boolean(credentials?.accessToken),
        identity: credentials?.identity || connection?.cloudIdentity || "",
        status: connection?.cloudStatus || (credentials ? "signed-in" : "signed-out"),
        environmentId: connection?.environmentId || "",
        environmentLabel: connection?.environmentLabel || "",
    };
}

async function removeCloudState() {
    await withStateLock(async () => {
        const nextEpoch = await readSessionEpochRaw() + 1;
        // Publish invalidation before deleting credentials. Any older helper
        // waiting on the lock then fails its guarded write instead of
        // recreating connection state after logout.
        await writePrivateJsonRaw(STATE_PATHS.sessionEpoch, { value: nextEpoch });
        await Promise.all([
            fs.rm(STATE_PATHS.legacyCredentials, { force: true }),
            fs.rm(STATE_PATHS.clerkClient, { force: true }),
            fs.rm(STATE_PATHS.browserLogin, { force: true }),
            fs.rm(STATE_PATHS.dpopKey, { force: true }),
            fs.rm(STATE_PATHS.connection, { force: true }),
        ]);
    });
}

async function loginAndConnect() {
    try {
        const credentials = await waitForT3CodeRelayCredentials(true);
        const result = await connectCloud(credentials);
        return {
            status: result.cloudStatus,
            identity: result.cloudIdentity,
            environmentId: result.environmentId || "",
            environmentLabel: result.environmentLabel || "",
        };
    } finally {
        // Browser sign-in steals focus. Return to the module on success and
        // failures so the result never disappears behind it.
        activatePanel();
    }
}

function writeStdout(value) {
    return new Promise((resolve, reject) => {
        process.stdout.write(value, error => error ? reject(error) : resolve());
    });
}

async function publishCommandResult(result) {
    const line = JSON.stringify(result) + "\n";
    const expectedEpoch = sessionEpochContext.getStore();
    if (expectedEpoch === undefined) {
        await writeStdout(line);
        return;
    }
    // The check and pipe write share logout's kernel lock. Therefore either the
    // result reaches its caller before logout publishes invalidation, or logout
    // wins and this stale command emits no credential-bearing result at all.
    await withStateLock(async () => {
        if (await readSessionEpochRaw() !== expectedEpoch)
            throw new SessionChangedError();
        await writeStdout(line);
    });
}

async function main(argv) {
    const command = argv[2] || "status";
    let result;
    if (command === "login")
        result = await loginAndConnect();
    else if (command === "connect") {
        const connected = await connectCloud(await waitForT3CodeRelayCredentials(false));
        result = {
            status: connected.cloudStatus,
            identity: connected.cloudIdentity,
            environmentId: connected.environmentId || "",
            environmentLabel: connected.environmentLabel || "",
        };
    }
    else if (command === "ticket")
        result = await issueWebSocketTicket();
    else if (command === "status")
        result = await cloudStatus();
    else if (command === "oauth-callback")
        result = await forwardBrowserCallback(argv[3] || "");
    else if (command === "logout") {
        await removeCloudState();
        result = { status: "signed-out" };
    } else {
        throw new Error("Usage: t3-cloud.mjs [login|connect|ticket|status|logout|oauth-callback]");
    }
    await publishCommandResult(result);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    const commandEpoch = process.argv[2] === "logout"
        ? Promise.resolve(undefined) : readSessionEpochRaw();
    commandEpoch.then(epoch => epoch === undefined
        ? main(process.argv)
        : sessionEpochContext.run(epoch, () => main(process.argv))).catch(error => {
        process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
        process.exitCode = error instanceof SignInRequiredError ? SIGN_IN_REQUIRED_EXIT : 1;
    });
}
