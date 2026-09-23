const test = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const {
    createHash,
    createPublicKey,
    generateKeyPairSync,
    verify,
} = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { shellDir } = require("./shell.cjs");

const repoDir = path.resolve(__dirname, "../..");

function readRepo(relativePath) {
    return fs.readFileSync(path.join(repoDir, relativePath), "utf8");
}

function readShell(relativePath) {
    return fs.readFileSync(path.join(shellDir, relativePath), "utf8");
}

function startProcess(command, args, env, input = "") {
    const child = spawn(command, args, { env });
    const result = new Promise((resolve, reject) => {
        let stdout = "";
        let stderr = "";
        const timeout = setTimeout(() => {
            child.kill();
            reject(new Error(`Timed out running ${command}; stdout=${stdout}; stderr=${stderr}`));
        }, 10_000);
        child.stdout.setEncoding("utf8");
        child.stderr.setEncoding("utf8");
        child.stdout.on("data", chunk => stdout += chunk);
        child.stderr.on("data", chunk => stderr += chunk);
        child.once("error", error => {
            clearTimeout(timeout);
            reject(error);
        });
        child.once("close", status => {
            clearTimeout(timeout);
            resolve({ status, stdout, stderr });
        });
    });
    child.stdin.end(input);
    return { child, result };
}

function runProcess(command, args, env, input = "") {
    return startProcess(command, args, env, input).result;
}

function runNode(script, command, env) {
    return runProcess(process.execPath, [script, command], env);
}

async function waitFor(predicate, message, timeoutMs = 5000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        const value = predicate();
        if (value)
            return value;
        await new Promise(resolve => setTimeout(resolve, 20));
    }
    throw new Error(message);
}

function decodeJwtPart(value, part) {
    return JSON.parse(Buffer.from(value.split(".")[part], "base64url").toString("utf8"));
}

test("the signed-out T3 panel presents T3 Connect login instead of pairing", () => {
    const chip = readShell("Bar/T3Chip.qml");
    const facade = readShell("Common/T3Code.qml");
    const popover = readShell("Popovers/T3CodePopover.qml");
    const inbox = readShell("Popovers/T3InboxPage.qml");
    const connection = readShell("Common/T3Connection.qml");
    const shell = readShell("shell.qml");
    const helper = readShell("scripts/t3-cloud.mjs");

    assert.doesNotMatch(popover, /function openDesktopClient\(\)/);
    assert.doesNotMatch(popover, /text: "Open T3 Code"/);
    assert.doesNotMatch(inbox, /Create a pairing link|Pair this panel|Paste link|Open Nightly/);
    assert.doesNotMatch([chip, facade, popover, inbox, connection, helper].join("\n"),
        /T3 Cloud/, "T3 Connect must be used consistently as the product name");
    assert.match(inbox, /title: T3Code\.cloudLoginRunning \? "Finish in your browser"/);
    assert.match(inbox, /label: T3Code\.cloudLoginRunning \? "Waiting for browser…"/);
    assert.match(inbox, /onTriggered: T3Code\.loginCloud\(\)/);
    assert.match(inbox, /Sign in with Google or GitHub to access your linked environments/);
    assert.doesNotMatch(inbox, /Sign in to T3 Connect|Refresh T3 Connect/);
    assert.doesNotMatch(popover, /T3 Connect · signed out|T3 Connect · signing in/);
    assert.match(popover, /id: footer\s+visible: T3Code\.state === "connected"/);
    assert.match(connection, /t3-cloud\.mjs", "login"/);
    assert.match(connection, /t3-cloud\.mjs", "ticket"/);
    assert.match(connection, /Quickshell\.env\("XDG_STATE_HOME"\)\s*\|\|/,
        "an unset XDG_STATE_HOME must fall back instead of producing an empty watcher path");
    assert.match(shell, /function open\(name: string\): void \{\s*Popouts\.openPanel\(name,/);
    assert.match(helper,
        /spawn\("qs", \[\s*"ipc", "--any-display", "-p", SHELL_DIR,\s*"call", "--", "popouts", "open", "t3code",\s*\]/,
        "the shell runs by path, so reopening the panel must name its config");
    assert.match(helper, /tokens\/t3-relay/);
    assert.match(helper, /Continue with Google/);
    assert.match(helper, /Continue with GitHub/);
    assert.match(helper, /browserCommand:[^\n]+"xdg-open"/);
    assert.doesNotMatch(helper, /secret-tool|desktopCommand|openT3Code/);
});

test("credential generations isolate every T3 transport attempt", () => {
    const connection = readShell("Common/T3Connection.qml");
    const socket = readShell("Common/T3Socket.qml");
    const helper = readShell("scripts/t3-cloud.mjs");

    assert.match(connection,
        /function resetTransport\(\)[\s\S]*sessionEpoch\+\+[\s\S]*socketLoader\.active = false;/,
        "credential replacement must destroy the old socket wrapper");
    assert.match(connection,
        /function openSocketUrl\(url, epoch\)[\s\S]*pendingSocketEpoch = epoch;[\s\S]*socketLoader\.active = false;[\s\S]*socketLoader\.active = true;/,
        "each reconnect must get a fresh wrapper so old close/open events cannot leak");
    assert.match(socket,
        /signal textReceived\(string message, int epoch\)/);
    assert.match(socket,
        /signal socketStatusChanged\(int status, string error, int epoch\)/);
    assert.match(connection,
        /function onTextReceived\(message, epoch\) \{\s*if \(epoch === root\.sessionEpoch\)\s*root\.message\(message\);/);
    assert.match(connection,
        /function onSocketStatusChanged\(st, socketError, epoch\) \{\s*if \(epoch !== root\.sessionEpoch\)\s*return;/);
    assert.match(connection,
        /ticketRequest\.abort\(\)[\s\S]*descriptorRequest\.abort\(\)/,
        "credential replacement must abort both HTTP requests");
    assert.match(connection, /id: ticketTimeout[\s\S]*request\.abort\(\)/);
    assert.match(connection, /id: descriptorTimeout[\s\S]*request\.abort\(\)/);
    assert.match(helper,
        /Publish invalidation before deleting credentials[\s\S]*STATE_PATHS\.sessionEpoch[\s\S]*Promise\.all/,
        "logout must invalidate older helper commands before deleting state");
    assert.match(helper,
        /sessionEpochContext\.run\(epoch, \(\) => main\(process\.argv\)\)/,
        "executable helper commands must guard their writes with the captured epoch");
    assert.match(helper,
        /function removePrivatePath\(filePath\)[\s\S]*readSessionEpochRaw\(\) !== expectedEpoch[\s\S]*fs\.rm\(filePath/,
        "stale helper cleanup must not delete state from a newer session");
    assert.match(helper,
        /function acquireKernelLock[\s\S]*spawn\("flock", lockArguments[\s\S]*function acquireStateLock[\s\S]*STATE_PATHS\.stateLock[\s\S]*releaseKernelLock/,
        "kernel flock ownership must replace racy persistent lock-file reclamation");
    assert.doesNotMatch(helper, /processExists|processIdentity|EEXIST/,
        "state locking must not reclaim path locks with a racy owner-file protocol");
    assert.match(helper,
        /finally \{\s*clearTimeout\(timeout\);[\s\S]*await removeOwnedBrowserLogin\(operationId\);\s*\} finally \{[\s\S]*server\.closeAllConnections\(\)/,
        "a logout generation change must still close the old browser-login server");
    assert.match(helper,
        /acquireBrowserLoginLock\(\)[\s\S]*browserLoginLock[\s\S]*nonblocking: true/,
        "one kernel-owned interactive login must exclude competing helpers");
    assert.match(helper,
        /function removeOwnedBrowserLogin\(operationId\)[\s\S]*pending\?\.operationId === operationId/,
        "an old login cleanup must not delete a newer callback record");
    assert.match(helper,
        /function publishCommandResult\(result\)[\s\S]*withStateLock[\s\S]*readSessionEpochRaw\(\) !== expectedEpoch[\s\S]*writeStdout/,
        "credential-bearing command output must be ordered against logout");
});

test("credential refresh handoff and connect watchdogs cannot strand T3 connecting", () => {
    const connection = readShell("Common/T3Connection.qml");
    const socket = readShell("Common/T3Socket.qml");
    const facade = readShell("Common/T3Code.qml");

    assert.match(connection,
        /cloudTicketProc\.running\s*&& cloudTicketProc\.attemptEpoch !== root\.sessionEpoch\)[\s\S]*cloudTicketProc\.reconnectEpoch = root\.sessionEpoch;[\s\S]*root\.state = "offline";[\s\S]*else if \(!cloudTicketProc\.running\) \{\s*root\.connect\(\);/,
        "a new credential must either connect now or reserve the one post-exit handoff");

    const staleExitStart = connection.indexOf(
        "if (attemptEpoch !== root.sessionEpoch) {");
    const staleExitEnd = connection.indexOf(
        "if (cloudTicketProc.timedOutEpoch === attemptEpoch)", staleExitStart);
    assert.notEqual(staleExitStart, -1, "the helper exit must identify a stale generation");
    assert.notEqual(staleExitEnd, -1, "the stale helper branch must end before current-exit handling");
    const staleExit = connection.slice(staleExitStart, staleExitEnd);
    assert.match(staleExit,
        /const reconnectEpoch = cloudTicketProc\.reconnectEpoch;[\s\S]*cloudTicketProc\.reconnectEpoch = -1;[\s\S]*reconnectEpoch === root\.sessionEpoch && root\.paired\)[\s\S]*root\.connect\(\);[\s\S]*return;/,
        "a stale exit must consume the newest handoff before reconnecting");
    assert.equal((staleExit.match(/root\.connect\(\)/g) || []).length, 1,
        "one stale helper exit may start only one replacement attempt");
    assert.match(connection,
        /onRunningChanged: \{\s*if \(running\)[\s\S]*return;\s*\}[\s\S]*const attemptEpoch[\s\S]*if \(attemptEpoch !== root\.sessionEpoch\)/,
        "the handoff must run only after Process.running becomes false");

    const cloudConnectStart = connection.indexOf(
        'if (authMode === "cloud" && tokenType === "DPoP")');
    const bearerConnectStart = connection.indexOf("if (ticketRequest)", cloudConnectStart);
    const cloudConnect = connection.slice(cloudConnectStart, bearerConnectStart);
    assert.ok(cloudConnect.indexOf("cloudTicketProc.running = true;")
            < cloudConnect.indexOf('state = "connecting";'),
        "connecting must not be published before the current helper is running");
    assert.match(cloudConnect,
        /cloudTicketProc\.attemptEpoch !== epoch\)[\s\S]*cloudTicketProc\.reconnectEpoch = epoch;[\s\S]*state = "offline";/,
        "a stale running helper is not current connection work");

    assert.match(connection,
        /id: cloudTicketTimeout[\s\S]*cloudTicketProc\.timedOutEpoch = epoch;\s*cloudTicketProc\.running = false;/,
        "a wedged ticket helper must be terminated and handled after exit");
    assert.match(connection,
        /cloudTicketProc\.timedOutEpoch === attemptEpoch[\s\S]*T3 Connect authorization timed out[\s\S]*root\.scheduleRetry\(attemptEpoch\)/,
        "a timed-out helper must leave connecting and retry its current generation");
    assert.match(connection,
        /id: socketConnectTimeout[\s\S]*root\.state !== "connecting"[\s\S]*T3 connection timed out[\s\S]*root\.scheduleRetry\(epoch\)/,
        "a WebSocket handshake must have a bounded connecting state");
    assert.match(connection,
        /status === Loader\.Error[\s\S]*root\.connectionError = "QtWebSockets is not installed";[\s\S]*root\.state = "offline";/,
        "a failed dynamic WebSocket load must leave connecting immediately");

    assert.match(connection,
        /function activatePendingSocket\(\)[\s\S]*socketLoader\.item\.sessionEpoch = epoch;[\s\S]*socketConnectTimeout\.restart\(\);[\s\S]*socketLoader\.item\.active = true;/,
        "the socket generation and watchdog must be installed before activation");
    assert.match(socket,
        /onActiveChanged: \{\s*if \(active\)\s*activeSessionEpoch = sessionEpoch;[\s\S]*sock\.active = active;/,
        "the wrapper must capture its epoch before activating QtWebSockets");
    assert.match(facade, /T3Connection\.scheduleRetry\(\);/);
    assert.doesNotMatch(facade, /(^|[^.A-Za-z0-9_])scheduleRetry\(/m,
        "the protocol facade must not call a nonexistent local retry function");
});

test("a refreshed credential waits for Process termination and reconnects once", () => {
    // Model the two QML event handlers with Process.running deliberately kept
    // true after resetTransport requests termination. This is the production
    // race: FileView.onLoaded runs before Process.onRunningChanged(false).
    const transport = {
        sessionEpoch: 1,
        paired: true,
        state: "offline",
        connects: 0,
    };
    const process = {
        running: true,
        attempted: true,
        attemptEpoch: 0,
        reconnectEpoch: -1,
    };
    const credentialLoaded = () => {
        if (process.running && process.attemptEpoch !== transport.sessionEpoch) {
            process.reconnectEpoch = transport.sessionEpoch;
            transport.state = "offline";
        } else if (!process.running) {
            transport.connects++;
            transport.state = "connecting";
        }
    };
    const runningChanged = () => {
        if (process.running || !process.attempted)
            return;
        const attemptEpoch = process.attemptEpoch;
        process.attempted = false;
        if (attemptEpoch !== transport.sessionEpoch) {
            const reconnectEpoch = process.reconnectEpoch;
            process.reconnectEpoch = -1;
            if (reconnectEpoch === transport.sessionEpoch && transport.paired) {
                transport.connects++;
                transport.state = "connecting";
            }
        }
    };

    credentialLoaded();
    credentialLoaded(); // duplicate watcher delivery overwrites one slot
    assert.equal(process.running, true, "termination has not completed yet");
    assert.equal(transport.connects, 0, "no generation may overlap the old helper");
    assert.equal(transport.state, "offline",
        "a stale terminating helper is not active current-generation work");

    process.running = false;
    runningChanged();
    runningChanged(); // duplicate notification cannot consume the slot twice
    assert.equal(transport.connects, 1);
    assert.equal(process.reconnectEpoch, -1);
    assert.equal(transport.state, "connecting");
});

test("browser-login ownership excludes competitors and logout settles its owner", async t => {
    const server = http.createServer((request, response) => {
        const route = new URL(request.url, "http://127.0.0.1").pathname;
        if (request.method === "GET" && route === "/v1/client") {
            response.writeHead(200, {
                "content-type": "application/json",
                authorization: "Bearer concurrent-clerk-client",
            });
            response.end(JSON.stringify({
                response: {
                    object: "client",
                    sessions: [],
                    last_active_session_id: null,
                },
                client: null,
            }));
            return;
        }
        response.writeHead(404, { "content-type": "application/json" });
        response.end('{"error":"not_found"}');
    });
    await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", resolve);
    });
    t.after(() => new Promise(resolve => server.close(resolve)));

    const temporaryHome = fs.mkdtempSync(path.join(os.tmpdir(), "t3-panel-login-owner-"));
    t.after(() => fs.rmSync(temporaryHome, { recursive: true, force: true }));
    const binDir = path.join(temporaryHome, "bin");
    fs.mkdirSync(binDir);
    fs.writeFileSync(path.join(binDir, "qs"), "#!/usr/bin/env bash\nexit 0\n", {
        mode: 0o755,
    });

    const script = path.join(shellDir, "scripts/t3-cloud.mjs");
    const stateRoot = path.join(temporaryHome, "state");
    const browserLoginPath = path.join(stateRoot, "t3code-cloud", "browser-login.json");
    const backend = `http://127.0.0.1:${server.address().port}`;
    const env = {
        ...process.env,
        HOME: temporaryHome,
        PATH: `${binDir}:${process.env.PATH}`,
        T3CODE_CLOUD_STATE_DIR: stateRoot,
        T3CODE_CLERK_URL: backend,
        T3CODE_RELAY_URL: backend,
        T3CODE_BROWSER_COMMAND: "/usr/bin/true",
        T3CODE_MIME_COMMAND: "/usr/bin/true",
    };
    const runningChildren = [];
    t.after(() => {
        for (const child of runningChildren) {
            if (child.exitCode === null)
                child.kill("SIGKILL");
        }
    });

    const first = startProcess(process.execPath, [script, "login"], env);
    runningChildren.push(first.child);
    const firstRecord = await waitFor(() => {
        try {
            return JSON.parse(fs.readFileSync(browserLoginPath, "utf8"));
        } catch {
            return null;
        }
    }, "the first browser login never published its callback record");
    assert.match(firstRecord.operationId,
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);

    const competing = await runNode(script, "login", env);
    assert.equal(competing.status, 1);
    assert.equal(competing.stdout, "");
    assert.match(competing.stderr, /sign-in is already in progress/);
    assert.equal(first.child.exitCode, null,
        "a competing helper must not disturb the owning login");

    const replacement = { ...firstRecord, operationId: "replacement-operation" };
    fs.writeFileSync(browserLoginPath, JSON.stringify(replacement) + "\n", { mode: 0o600 });
    const cancelled = await fetch(
        `http://127.0.0.1:${firstRecord.port}/oauth-callback`, {
            method: "POST",
            headers: {
                authorization: `Bearer ${firstRecord.callbackSecret}`,
                "content-type": "text/plain; charset=utf-8",
            },
            body: "t3code://app/?rotating_token_nonce=cancel",
        });
    assert.equal(cancelled.status, 200);
    await cancelled.text();
    const firstResult = await first.result;
    assert.equal(firstResult.status, 1);
    assert.deepEqual(JSON.parse(fs.readFileSync(browserLoginPath, "utf8")), replacement,
        "the old owner's finally block must leave a newer callback record intact");

    const pending = startProcess(process.execPath, [script, "login"], env);
    runningChildren.push(pending.child);
    const pendingRecord = await waitFor(() => {
        try {
            const record = JSON.parse(fs.readFileSync(browserLoginPath, "utf8"));
            return record.operationId !== replacement.operationId ? record : null;
        } catch {
            return null;
        }
    }, "a new owner did not replace the stale callback record");
    assert.notEqual(pendingRecord.operationId, firstRecord.operationId);

    const logout = await runNode(script, "logout", env);
    assert.equal(logout.status, 0, logout.stderr);
    assert.deepEqual(JSON.parse(logout.stdout), { status: "signed-out" });
    const pendingResult = await pending.result;
    assert.equal(pendingResult.status, 1);
    assert.equal(pendingResult.stdout, "");
    assert.match(pendingResult.stderr, /session changed while this request was running/);
    assert.equal(fs.existsSync(browserLoginPath), false,
        "logout must remove the pending callback record");
});

test("an expired T3 Connect session exits distinctly instead of failing transiently", async t => {
    const requests = [];
    const server = http.createServer((request, response) => {
        requests.push({ url: request.url, authorization: request.headers.authorization });
        const route = new URL(request.url, "http://127.0.0.1").pathname;
        if (request.method === "GET" && route === "/v1/client") {
            // A revoked native client is refused; a fresh one has no session.
            if (request.headers.authorization === "Bearer revoked-clerk-client") {
                response.writeHead(401, { "content-type": "application/json" });
                response.end('{"error":"unauthorized"}');
                return;
            }
            response.writeHead(200, {
                "content-type": "application/json",
                authorization: "Bearer anonymous-clerk-client",
            });
            response.end(JSON.stringify({
                response: { object: "client", sessions: [], last_active_session_id: null },
                client: null,
            }));
            return;
        }
        response.writeHead(404, { "content-type": "application/json" });
        response.end('{"error":"not_found"}');
    });
    await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", resolve);
    });
    t.after(() => new Promise(resolve => server.close(resolve)));

    const temporaryHome = fs.mkdtempSync(path.join(os.tmpdir(), "t3-panel-expired-"));
    t.after(() => fs.rmSync(temporaryHome, { recursive: true, force: true }));
    const script = path.join(shellDir, "scripts/t3-cloud.mjs");
    const stateRoot = path.join(temporaryHome, "state");
    const privateState = path.join(stateRoot, "t3code-cloud");
    const backend = `http://127.0.0.1:${server.address().port}`;
    const env = {
        ...process.env,
        HOME: temporaryHome,
        T3CODE_CLOUD_STATE_DIR: stateRoot,
        T3CODE_CLERK_URL: backend,
        T3CODE_RELAY_URL: backend,
        T3CODE_BROWSER_COMMAND: "/usr/bin/false",
        T3CODE_MIME_COMMAND: "/usr/bin/false",
    };
    const helper = await import(pathToFileURL(script).href + `?exit=${Date.now()}`);
    const connection = readShell("Common/T3Connection.qml");
    const declared = connection.match(/readonly property int signInRequiredExit: (\d+)/);
    assert.ok(declared, "the panel must name the helper's sign-in-required status");
    assert.equal(Number(declared[1]), helper.SIGN_IN_REQUIRED_EXIT);
    assert.notEqual(helper.SIGN_IN_REQUIRED_EXIT, 1,
        "a missing session must not look like an ordinary transient failure");

    // An expired environment token with a revoked browser session.
    fs.mkdirSync(privateState, { recursive: true, mode: 0o700 });
    fs.writeFileSync(path.join(privateState, "clerk-client.json"),
        JSON.stringify({ clientToken: "revoked-clerk-client" }), { mode: 0o600 });
    fs.writeFileSync(path.join(stateRoot, "t3code-bar.json"), JSON.stringify({
        authMode: "cloud",
        cloudStatus: "connected",
        httpBaseUrl: backend,
        wsBaseUrl: backend.replace("http:", "ws:"),
        accessToken: "expired-environment-token",
        tokenType: "DPoP",
        expiresAtEpochMs: Date.now() - 1000,
    }), { mode: 0o600 });
    const revoked = await runNode(script, "ticket", env);
    assert.equal(revoked.status, helper.SIGN_IN_REQUIRED_EXIT, revoked.stderr);
    assert.equal(revoked.stdout, "");
    assert.match(revoked.stderr, /Sign in to T3 Connect from the panel/);

    // The replacement anonymous client is still signed out on the next try.
    const anonymous = await runNode(script, "ticket", env);
    assert.equal(anonymous.status, helper.SIGN_IN_REQUIRED_EXIT, anonymous.stderr);
    assert.equal(requests.at(-1).authorization, "Bearer anonymous-clerk-client");
    assert.equal(requests.filter(item => new URL(item.url, backend).pathname
        !== "/v1/client").length, 0, "no relay or environment call without a session");

    // Anything else still fails as a transient, retried error.
    const unreachable = await runNode(script, "ticket", {
        ...env,
        T3CODE_CLERK_URL: "http://127.0.0.1:9",
    });
    assert.equal(unreachable.status, 1, unreachable.stderr);
});

test("the panel treats a missing T3 Connect session as signed out, not offline", () => {
    const connection = readShell("Common/T3Connection.qml");
    const popover = readShell("Popovers/T3CodePopover.qml");
    const inbox = readShell("Popovers/T3InboxPage.qml");

    const start = connection.indexOf("cloudTicketProc.lastExit === root.signInRequiredExit");
    assert.notEqual(start, -1, "the ticket helper's exit must be told apart");
    const branch = connection.slice(start, connection.indexOf("} else {", start));
    assert.match(branch, /root\.state = root\.stateWithoutCredential\(\);\s*return;/);
    assert.doesNotMatch(branch, /scheduleRetry/,
        "only a sign-in can end it, so no retry may be armed");

    // The inbox's Sign in shows for any signed-out state; the connection
    // menu, which stays up while the pairing does, must offer it too.
    assert.match(inbox, /visible: T3Code\.state === "signed-out" \|\| T3Code\.state === "cloud-empty"/);
    assert.match(inbox, /T3Code\.state === "signed-out" && T3Code\.paired/);
    assert.match(popover, /readonly property bool signIn: T3Code\.state === "signed-out"/);
    assert.match(popover, /if \(signIn\)\s*T3Code\.loginCloud\(\);\s*else\s*T3Code\.connect\(\);/);
    assert.match(popover, /text: reconnectItem\.signIn \? "Sign in" : "Reconnect"/);
});

test("the T3 Connect helper emits verifiable T3-compatible DPoP proofs", async () => {
    const script = path.join(shellDir, "scripts/t3-cloud.mjs");
    const helper = await import(pathToFileURL(script).href + `?dpop=${Date.now()}`);
    const generated = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const privateJwk = generated.privateKey.export({ format: "jwk" });
    const publicJwk = {
        kty: privateJwk.kty,
        crv: privateJwk.crv,
        x: privateJwk.x,
        y: privateJwk.y,
    };
    const proof = helper.createDpopProof({
        method: "post",
        url: "https://environment.example.test/api/auth/websocket-ticket?ignored=yes",
        accessToken: "environment-access-token",
        key: { privateKey: generated.privateKey, publicJwk },
        now: 1_800_000_000_000,
    });

    const [encodedHeader, encodedPayload, encodedSignature] = proof.split(".");
    const signature = Buffer.from(encodedSignature, "base64url");
    assert.deepEqual(decodeJwtPart(proof, 0), {
        typ: "dpop+jwt",
        alg: "ES256",
        jwk: publicJwk,
    });
    const payload = decodeJwtPart(proof, 1);
    assert.deepEqual(payload, {
        htm: "POST",
        htu: "https://environment.example.test/api/auth/websocket-ticket",
        jti: payload.jti,
        iat: 1_800_000_000,
        ath: createHash("sha256").update("environment-access-token").digest("base64url"),
    });
    assert.equal(verify("sha256", Buffer.from(`${encodedHeader}.${encodedPayload}`), {
        key: createPublicKey(generated.privateKey),
        dsaEncoding: "ieee-p1363",
    }, signature), true);
    const p256Order = BigInt(
        "0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551");
    assert.ok(BigInt(`0x${signature.subarray(32).toString("hex")}`) <= p256Order / 2n,
        "T3's noble-curves verifier requires canonical low-S signatures");
    assert.equal(helper.computeDpopThumbprint(publicJwk), createHash("sha256")
        .update(JSON.stringify({
            crv: publicJwk.crv,
            kty: publicJwk.kty,
            x: publicJwk.x,
            y: publicJwk.y,
        })).digest("base64url"));
});

test("the T3 Connect browser flow authorizes and tickets a linked environment", async t => {
    const requests = [];
    let signedIn = false;
    let ticketBarrier = null;
    const activeSession = {
        id: "session-browser",
        status: "active",
        user: {
            primary_email_address_id: "email-browser",
            email_addresses: [{
                id: "email-browser",
                email_address: "browser@example.test",
            }],
        },
    };
    const server = http.createServer((request, response) => {
        let body = "";
        request.setEncoding("utf8");
        request.on("data", chunk => body += chunk);
        request.on("end", () => {
            requests.push({
                method: request.method,
                url: request.url,
                headers: request.headers,
                body,
            });
            const address = server.address();
            const base = `http://127.0.0.1:${address.port}`;
            const parsed = new URL(request.url, base);
            const route = parsed.pathname;
            const clerkHeaders = route.startsWith("/v1/client")
                ? { authorization: "Bearer clerk-native-client-token" } : {};
            const json = value => {
                response.writeHead(200, {
                    "content-type": "application/json",
                    ...clerkHeaders,
                });
                response.end(JSON.stringify(value));
            };
            if (request.method === "GET" && route === "/v1/client") {
                json({
                    response: {
                        object: "client",
                        sessions: signedIn ? [activeSession] : [],
                        last_active_session_id: signedIn ? activeSession.id : null,
                    },
                    client: null,
                });
            } else if (request.method === "POST" && route === "/v1/client/sign_ins") {
                json({
                    response: {
                        id: "sign-in-browser",
                        status: "needs_identifier",
                        created_session_id: null,
                        first_factor_verification: {
                            status: "unverified",
                            strategy: "oauth_google",
                            external_verification_redirect_url:
                                "https://accounts.example.test/t3-connect",
                        },
                    },
                    client: null,
                });
            } else if (request.method === "GET"
                    && route === "/v1/client/sign_ins/sign-in-browser") {
                signedIn = true;
                json({
                    response: {
                        id: "sign-in-browser",
                        status: "complete",
                        created_session_id: activeSession.id,
                    },
                    client: {
                        object: "client",
                        sessions: [activeSession],
                        last_active_session_id: activeSession.id,
                    },
                });
            } else if (request.method === "POST"
                    && route === "/v1/client/sessions/session-browser/tokens/t3-relay") {
                json({ response: { jwt: "relay-clerk-template-token" }, client: null });
            } else if (request.method === "GET" && route === "/v1/environments") {
                json({ environments: [{
                    environmentId: "env-browser",
                    label: "Linked workstation",
                    endpoint: {
                        httpBaseUrl: base,
                        wsBaseUrl: base.replace("http:", "ws:"),
                        providerKind: "cloudflare",
                    },
                    linkedAt: "2026-08-19T18:00:00.000Z",
                }] });
            } else if (request.method === "POST" && route === "/v1/client/dpop-token") {
                json({
                    access_token: "relay-access-token",
                    issued_token_type: "urn:ietf:params:oauth:token-type:access_token",
                    token_type: "DPoP",
                    expires_in: 300,
                    scope: "environment:connect",
                });
            } else if (request.method === "POST"
                    && route === "/v1/environments/env-browser/connect") {
                json({
                    environmentId: "env-browser",
                    endpoint: {
                        httpBaseUrl: base,
                        wsBaseUrl: base.replace("http:", "ws:"),
                        providerKind: "cloudflare",
                    },
                    credential: "environment-bootstrap",
                    expiresAt: "2026-08-19T22:00:00.000Z",
                });
            } else if (request.method === "POST" && route === "/oauth/token") {
                json({
                    access_token: "environment-access-token",
                    issued_token_type: "urn:ietf:params:oauth:token-type:access_token",
                    token_type: "DPoP",
                    expires_in: 3600,
                    scope: "orchestration:read orchestration:operate terminal:operate review:write relay:read",
                });
            } else if (request.method === "POST"
                    && route === "/api/auth/websocket-ticket") {
                if (ticketBarrier === null) {
                    json({ ticket: "short-lived-ticket" });
                } else {
                    ticketBarrier.observed();
                    void ticketBarrier.release.then(() =>
                        json({ ticket: "short-lived-ticket" }));
                }
            } else {
                response.writeHead(404, { "content-type": "application/json" });
                response.end(JSON.stringify({ error: "not_found" }));
            }
        });
    });
    await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", resolve);
    });
    t.after(() => new Promise(resolve => server.close(resolve)));

    const temporaryHome = fs.mkdtempSync(path.join(os.tmpdir(), "t3-panel-cloud-"));
    t.after(() => fs.rmSync(temporaryHome, { recursive: true, force: true }));

    const address = server.address();
    const backend = `http://127.0.0.1:${address.port}`;
    const stateRoot = path.join(temporaryHome, "state");
    const privateState = path.join(stateRoot, "t3code-cloud");
    const binDir = path.join(temporaryHome, "bin");
    const browserOpened = path.join(temporaryHome, "browser-opened.json");
    const mimeCalled = path.join(temporaryHome, "mime-called");
    const browserCommand = path.join(binDir, "open-browser");
    const mimeCommand = path.join(binDir, "xdg-mime");
    fs.mkdirSync(binDir);
    fs.writeFileSync(browserCommand, `#!/usr/bin/env node
const fs = require("node:fs");
const net = require("node:net");
const { spawnSync } = require("node:child_process");
(async () => {
    const landing = process.argv[2];
    const local = new URL(landing);
    const speculativeSocket = net.connect(Number(local.port), local.hostname);
    await new Promise((resolve, reject) => {
        speculativeSocket.once("connect", resolve);
        speculativeSocket.once("error", reject);
    });
    const started = await fetch(new URL("/start?provider=google", landing), {
        redirect: "manual",
    });
    fs.writeFileSync(process.env.T3_TEST_BROWSER_OPENED, JSON.stringify({
        landing,
        providerRedirect: started.headers.get("location"),
    }));
    if (started.status !== 302)
        process.exit(2);
    const callback = spawnSync(process.execPath, [
        process.env.T3_TEST_HELPER,
        "oauth-callback",
        "t3code://app/?rotating_token_nonce=test-nonce",
    ], { env: process.env, encoding: "utf8" });
    if (callback.status !== 0)
        process.exit(callback.status || 3);
    await new Promise(resolve => speculativeSocket.once("close", resolve));
})().catch(() => process.exit(4));
`, { mode: 0o755 });
    fs.writeFileSync(mimeCommand, `#!/usr/bin/env node
require("node:fs").writeFileSync(
    process.env.T3_TEST_MIME_CALLED,
    process.argv.slice(2).join(" "),
);
`, { mode: 0o755 });
    const panelActivated = path.join(temporaryHome, "qs-argv.json");
    fs.writeFileSync(path.join(binDir, "qs"), `#!/usr/bin/env node
require("node:fs").writeFileSync(${JSON.stringify(panelActivated)},
    JSON.stringify(process.argv.slice(2)));
`, { mode: 0o755 });

    const script = path.join(shellDir, "scripts/t3-cloud.mjs");
    const env = {
        ...process.env,
        HOME: temporaryHome,
        PATH: `${binDir}:${process.env.PATH}`,
        T3_TEST_BROWSER_OPENED: browserOpened,
        T3_TEST_HELPER: script,
        T3_TEST_MIME_CALLED: mimeCalled,
        T3CODE_CLOUD_STATE_DIR: stateRoot,
        T3CODE_CLERK_URL: backend,
        T3CODE_RELAY_URL: backend,
        T3CODE_BROWSER_COMMAND: browserCommand,
        T3CODE_MIME_COMMAND: mimeCommand,
    };
    const connected = await runNode(script, "login", env);
    assert.equal(connected.status, 0, connected.stderr);
    assert.equal(connected.stderr, "");
    assert.deepEqual(JSON.parse(connected.stdout), {
        status: "connected",
        identity: "browser@example.test",
        environmentId: "env-browser",
        environmentLabel: "Linked workstation",
    });
    assert.doesNotMatch(connected.stdout,
        /clerk-native-client-token|relay-clerk-template-token|relay-access-token|environment-access-token|environment-bootstrap/);
    const opened = JSON.parse(fs.readFileSync(browserOpened, "utf8"));
    assert.match(opened.landing, /^http:\/\/127\.0\.0\.1:\d+\/$/);
    assert.equal(opened.providerRedirect, "https://accounts.example.test/t3-connect");
    assert.equal(fs.readFileSync(mimeCalled, "utf8"),
        "default t3code-nightly.desktop x-scheme-handler/t3code");
    const activation = await waitFor(() => {
        try {
            return JSON.parse(fs.readFileSync(panelActivated, "utf8"));
        } catch {
            return null;
        }
    }, "sign-in never asked the shell to reopen the panel");
    assert.deepEqual(activation, ["ipc", "--any-display", "-p", fs.realpathSync(shellDir),
        "call", "--", "popouts", "open", "t3code"]);

    const statePath = path.join(stateRoot, "t3code-bar.json");
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
    assert.deepEqual({
        authMode: state.authMode,
        cloudStatus: state.cloudStatus,
        cloudIdentity: state.cloudIdentity,
        environmentId: state.environmentId,
        environmentLabel: state.environmentLabel,
        httpBaseUrl: state.httpBaseUrl,
        wsBaseUrl: state.wsBaseUrl,
        accessToken: state.accessToken,
        tokenType: state.tokenType,
    }, {
        authMode: "cloud",
        cloudStatus: "connected",
        cloudIdentity: "browser@example.test",
        environmentId: "env-browser",
        environmentLabel: "Linked workstation",
        httpBaseUrl: backend,
        wsBaseUrl: backend.replace("http:", "ws:"),
        accessToken: "environment-access-token",
        tokenType: "DPoP",
    });
    assert.equal(fs.statSync(statePath).mode & 0o777, 0o600);
    assert.equal(fs.statSync(path.join(privateState, "clerk-client.json")).mode & 0o777, 0o600);
    assert.equal(fs.statSync(path.join(privateState, "dpop-key.json")).mode & 0o777, 0o600);
    assert.equal(fs.existsSync(path.join(privateState, "browser-login.json")), false);

    const initialClient = requests.find(item => item.method === "GET"
        && new URL(item.url, backend).pathname === "/v1/client");
    assert.equal(initialClient.headers.authorization, undefined,
        "the panel must create its own Clerk client instead of reading Nightly's session");
    const clerkSignIn = requests.find(item => item.method === "POST"
        && new URL(item.url, backend).pathname === "/v1/client/sign_ins");
    assert.equal(clerkSignIn.headers.authorization, "Bearer clerk-native-client-token");
    assert.equal(clerkSignIn.headers["content-type"], "application/x-www-form-urlencoded");
    assert.deepEqual(Object.fromEntries(new URLSearchParams(clerkSignIn.body)), {
        strategy: "oauth_google",
        redirect_url: "t3code://app/",
        action_complete_redirect_url: "t3code://app/",
    });
    const clerkCallback = requests.find(item =>
        new URL(item.url, backend).pathname === "/v1/client/sign_ins/sign-in-browser");
    assert.equal(new URL(clerkCallback.url, backend).searchParams.get("rotating_token_nonce"),
        "test-nonce");
    for (const clerkRequest of requests.filter(item => {
        const route = new URL(item.url, backend).pathname;
        return route !== "/v1/client/dpop-token"
            && (route === "/v1/client" || route.startsWith("/v1/client/"));
    })) {
        const params = new URL(clerkRequest.url, backend).searchParams;
        assert.equal(params.get("__clerk_api_version"), "2026-05-12");
        assert.equal(params.get("_clerk_js_version"), "6.29.2");
        assert.equal(params.get("_is_native"), "1");
    }

    const listed = requests.find(item => item.url === "/v1/environments");
    assert.equal(listed.headers.authorization, "Bearer relay-clerk-template-token");
    const clerkTemplate = requests.find(item =>
        new URL(item.url, backend).pathname
            === "/v1/client/sessions/session-browser/tokens/t3-relay");
    assert.equal(clerkTemplate.headers.authorization, "Bearer clerk-native-client-token");
    const relayExchange = requests.find(item => item.url === "/v1/client/dpop-token");
    assert.match(relayExchange.headers.dpop, /^[^.]+\.[^.]+\.[^.]+$/);
    const relayForm = new URLSearchParams(relayExchange.body);
    assert.equal(relayForm.get("client_id"), "t3-web");
    assert.equal(relayForm.get("scope"), "environment:connect");
    assert.equal(relayForm.get("subject_token"), "relay-clerk-template-token");
    const relayConnect = requests.find(item => item.url.endsWith("/connect"));
    assert.equal(relayConnect.headers.authorization, "DPoP relay-access-token");
    assert.equal(typeof JSON.parse(relayConnect.body).clientKeyThumbprint, "string");
    const environmentExchange = requests.find(item => item.url === "/oauth/token");
    assert.equal(new URLSearchParams(environmentExchange.body).get("subject_token"),
        "environment-bootstrap");

    const ticket = await runNode(script, "ticket", env);
    assert.equal(ticket.status, 0, ticket.stderr);
    assert.equal(ticket.stderr, "");
    assert.equal(new URL(JSON.parse(ticket.stdout).socketUrl).searchParams.get("wsTicket"),
        "short-lived-ticket");
    const ticketRequest = requests.find(item => item.url === "/api/auth/websocket-ticket");
    assert.equal(ticketRequest.headers.authorization, "DPoP environment-access-token");
    assert.match(ticketRequest.headers.dpop, /^[^.]+\.[^.]+\.[^.]+$/);

    let observeTicket;
    let releaseTicket;
    const ticketObserved = new Promise(resolve => observeTicket = resolve);
    const ticketRelease = new Promise(resolve => releaseTicket = resolve);
    ticketBarrier = { observed: observeTicket, release: ticketRelease };
    const staleTicket = runNode(script, "ticket", env);
    await ticketObserved;
    const logout = await runNode(script, "logout", env);
    assert.equal(logout.status, 0, logout.stderr);
    releaseTicket();
    const staleTicketResult = await staleTicket;
    assert.equal(staleTicketResult.status, 1,
        "a ticket request overtaken by logout must fail its final epoch check");
    assert.equal(staleTicketResult.stdout, "",
        "no credential-bearing ticket may reach stdout after logout");
    assert.match(staleTicketResult.stderr, /session changed while this request was running/);
});

test("the nightly launcher routes pending panel callbacks and preserves its fallback", () => {
    const updater = readRepo("roles/dotfiles/templates/t3code-update.j2");
    const launcher = readRepo("roles/dotfiles/templates/t3code-desktop.j2");
    const desktop = readRepo("roles/dotfiles/templates/t3code-nightly.desktop.j2");
    const mimeapps = readRepo("roles/dotfiles/templates/mimeapps.list.j2");
    const packages = readRepo("roles/desktop/tasks/main.yml");

    assert.match(updater, /select\(\.prerelease and \(\.tag_name \| contains\("-nightly\."\)\)\)/,
        "the updater must remain pinned to prerelease nightlies");
    assert.ok(launcher.includes(
        'exec "$appimage" --appimage-extract-and-run --password-store=gnome-libsecret "$@"'),
        "the launcher must preserve non-panel callback URL arguments");
    assert.match(launcher, /oauth-callback "\$1"/,
        "a pending browser sign-in must return to the panel instead of opening Nightly");
    assert.match(launcher, /\[\[ \$\{1-\} == t3code:\/\/app\/\* \]\]/);
    assert.match(desktop, /^Exec=\{\{ primary_home \}\}\/\.local\/bin\/t3code-desktop %U$/m);
    assert.match(desktop, /^MimeType=x-scheme-handler\/t3code;$/m);
    assert.doesNotMatch(desktop, /x-scheme-handler\/t3code-dev/,
        "nightly is packaged and therefore uses the production scheme");
    assert.match(mimeapps, /^x-scheme-handler\/t3code=t3code-nightly\.desktop$/m);
    assert.doesNotMatch(mimeapps, /^x-scheme-handler\/t3code-dev=/m);
    assert.match(packages, /^\s+- xdg-utils$/m,
        "the upstream Linux callback registration invokes xdg-mime");
    assert.match(packages, /^\s+- fuse-libs$/m,
        "the upstream-generated callback handler starts the AppImage directly");
});
