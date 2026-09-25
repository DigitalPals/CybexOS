const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "UsageLogic.js"), "utf8")
  .replace(/^\.pragma library\s*/m, "");
const context = { Array, Math, Number, String, isFinite };
vm.createContext(context);
vm.runInContext(source, context, { filename: "UsageLogic.js" });

const provider = (id, remaining, status = "ok") => ({
  id,
  name: id,
  status,
  windows: remaining === null ? [] : [{ remaining }],
});

assert.equal(context.minRemaining(provider("claude", 72)), 72);
assert.equal(context.minRemaining({ ...provider("codex", 44), windows: [{ remaining: 91 }, { remaining: 44 }] }), 44);
assert.equal(context.minRemaining({ ...provider("codex", 44), windows: { 0: { remaining: 62 }, length: 1 } }), 62);
assert.equal(context.minRemaining(provider("claude", null)), null);
assert.equal(context.minRemaining({ ...provider("codex", 44), windows: [{ remaining: null }] }), null);
assert.equal(context.severity(provider("kimi", 9), 25, 10), "critical");
assert.equal(context.severity(provider("kimi", 20), 25, 10), "warning");
assert.equal(context.severity(provider("kimi", 80), 25, 10), "ok");
assert.equal(context.severity(provider("kimi", null, "error"), 25, 10), "error");
const listLike = { 0: "first", 1: "second", length: 2 };
assert.equal(context.isListLike(listLike), true);
assert.equal(context.isListLike("not a list"), false);
assert.equal(context.isListLike({ length: 1.5 }), false);
assert.equal(context.contains(listLike, "second"), true);
assert.equal(context.contains(listLike, "missing"), false);
assert.equal(JSON.stringify(context.firstItems(listLike, 1)), '["first"]');
assert.equal(JSON.stringify(context.listOrEmpty(null)), "[]");
assert.equal(context.errorTitle({ id: "claude", name: "Claude Code", errorKind: "expired" }), "Claude Code sign-in expired");

const providers = [provider("claude", 72), provider("codex", 44), provider("kimi", null, "error")];
const selected = context.selectedProviders(providers, { 0: "codex", 1: "kimi", length: 2 });
assert.equal(selected.length, 2);
assert.equal(selected[0].id, "codex");
assert.equal(context.meaningfulProviders(selected).length, 1);
assert.equal(context.selectedProviders(providers, []).length, 0);
assert.equal(providers.length, 3);

const discovered = [
  { id: "claude", status: "ok", accounts: [{ status: "disabled" }, { status: "ok" }] },
  { id: "codex", status: "error", accounts: { 0: { status: "error", errorKind: "timeout" }, length: 1 } },
  { id: "xai", status: "disabled", accounts: [{ status: "disabled" }] },
  { id: "kimi", status: "error", errorKind: "no_credentials" },
  { id: "gemini", status: "unsupported", accounts: [{ status: "unsupported" }] },
];
assert.equal(JSON.stringify(context.availableProviders(discovered).map(row => row.id)),
  '["claude","codex","gemini"]', "hide unconnected or paused providers, retain active accounts even when quota checks fail");
assert.equal(context.availableProviders([{ id: "cliproxy", status: "error", errorKind: "no_credentials" }]).length,
  1, "proxy setup errors must remain visible");
assert.equal(context.availableProviders(null).length, 0);
assert.equal(discovered.length, 5, "filtering does not change backend discovery");

const priorAccount = { ...provider("antigravity", 75), accountId: "a", plan: "Pro", fetchedAt: "then" };
const oldProxy = { source: "cliproxy", providers: [{ ...priorAccount, accounts: [priorAccount] }] };
const failedAccount = { ...priorAccount, status: "error", windows: [], message: "Timeout" };
const stale = context.preserveProxyReadings(oldProxy, { source: "cliproxy",
  providers: [{ ...failedAccount, accounts: [failedAccount] }] });
assert.equal(stale.providers[0].accounts[0].windows[0].remaining, 75);
assert.equal(stale.providers[0].accounts[0].stale, true);
assert.equal(stale.providers[0].fetchedAt, "then");
const outage = context.preserveProxyReadings(oldProxy, { providers: [{ id: "cliproxy", status: "error", message: "Offline" }] });
assert.equal(outage.providers[0].id, "antigravity");
assert.equal(outage.providers[0].stale, true);
const paused = context.preserveProxyReadings(oldProxy, { providers: [{ ...priorAccount, status: "disabled", windows: [] }] });
assert.equal(paused.providers[0].status, "disabled");
assert.equal(paused.providers[0].windows.length, 0);

const accountPool = { ...provider("codex", 90), accounts: [
  { ...provider("codex", 90), accountId: "one", account: "one@example.invalid" },
  { ...provider("codex", 23), accountId: "two", account: "two@example.invalid" },
] };
const recent = [{ id: "codex", status: "ok", accountId: "two", lastUsedAt: 123 }];
let lastAccount = context.lastUsedAccount(accountPool, recent, true);
assert.equal(lastAccount.label, "Account 2");
assert.equal(context.minRemaining(lastAccount.reading), 23, "quota must belong to the last account, not the best account");
assert.equal(lastAccount.lastUsedAt, 123);
assert.equal(context.lastUsedAccount(accountPool, recent, false).label, "two@example.invalid");
assert.equal(context.lastUsedAccount(accountPool, [{ ...recent[0], accountId: "one" }], true).label, "Account 1");
assert.equal(context.lastUsedAccount(accountPool, [], true).reading, null);
assert.equal(context.lastUsedAccount(accountPool, [{ ...recent[0], accountId: "removed" }], true).reading, null);
assert.equal(context.lastUsedAccount(accountPool, [{ ...recent[0], status: "ambiguous" }], true).label, "Multiple accounts");
assert.equal(context.lastUsedAccount({ ...accountPool, accounts: { 0: accountPool.accounts[1], length: 1 } }, recent, true).label, "Account 1");
assert.equal(context.minRemaining(context.lastUsedAccount({ ...accountPool, accounts: [
  { ...accountPool.accounts[1], status: "disabled", windows: [] }
] }, recent, true).reading), null);
console.log("UsageLogic.js: all assertions passed");

const codexWindows = [
  {id: "additional-secondary", label: "Code review · Weekly limit", windowSeconds: 604800},
  {id: "codex-primary", label: "5 hour limit", windowSeconds: 18000},
  {id: "codex-secondary", label: "Weekly limit", windowSeconds: 604800}
];
assert.equal(context.accountWindows({windows: codexWindows}, false).length, 1);
assert.equal(context.accountWindows({windows: codexWindows}, false)[0].id, "codex-secondary");
assert.equal(context.accountWindows({windows: codexWindows}, true).length, 3);
assert.equal(context.accountWindows({windows: [{label: "Monthly limit"}]}, false)[0].label, "Monthly limit");
assert.equal(context.accountWindows({windows: []}, false).length, 0);
assert.equal(context.accountPlanLabel({id: "codex", planType: "pro"}), "Codex Pro · 20×");
assert.equal(context.accountPlanLabel({id: "codex", planType: "prolite"}), "Codex Pro · 5×");
assert.equal(context.accountPlanLabel({id: "codex", plan: "ChatGPT Pro"}), "Codex Pro · 20×");

const resetAccount = { ...provider("codex", 55), accountId: "reset-account", credits: { resetCreditsAvailable: 2 } };
assert.equal(context.accountResetLabel(resetAccount), "2 banked resets");
assert.equal(context.accountResetLabel({ ...resetAccount, credits: { resetCreditsAvailable: 1 } }), "1 banked reset");
assert.equal(context.accountResetLabel({ ...resetAccount, credits: { resetCreditsAvailable: 0 } }), "0 banked resets");
for (const count of [undefined, null, -1, 1.5, true, "2", NaN, Infinity])
  assert.equal(context.accountResetLabel({ ...resetAccount, credits: { resetCreditsAvailable: count } }), "");
assert.equal(context.accountResetLabel({ ...resetAccount, credits: null }), "");
assert.equal(context.accountResetLabel({ ...resetAccount, id: "claude" }), "");
assert.equal(context.accountResetLabel({ ...resetAccount, status: "disabled" }), "");
const resetFailure = { ...resetAccount, status: "error", credits: null, message: "Timeout" };
const resetStale = context.preserveProxyReadings({ source: "cliproxy", providers: [{ ...resetAccount, accounts: [resetAccount] }] },
  { source: "cliproxy", providers: [{ ...resetFailure, accounts: [resetFailure] }] });
assert.equal(context.accountResetLabel(resetStale.providers[0].accounts[0]), "2 banked resets");
assert.equal(resetStale.providers[0].accounts[0].stale, true);

const customRows = [{model: " vendor/Model[1m] ", inputCostPerMillionTokens: "2",
  outputCostPerMillionTokens: "8", cacheReadCostPerMillionTokens: "0", cacheWriteCostPerMillionTokens: ""}];
const customJson = context.encodeCostPrices(customRows);
assert.deepEqual(JSON.parse(customJson), {"vendor/Model[1m]": {
  inputCostPerMillionTokens: 2, outputCostPerMillionTokens: 8, cacheReadCostPerMillionTokens: 0}});
assert.equal(context.encodeCostPrices(context.decodeCostPrices(customJson)), customJson);
assert.equal(context.encodeCostPrices([]), "{}");
for (const value of ["", "-1", "Infinity", "NaN", "0x10", "true", "1e10"])
  assert.throws(() => context.encodeCostPrices([{...customRows[0], inputCostPerMillionTokens: value}]));
assert.throws(() => context.encodeCostPrices([customRows[0], customRows[0]]));
assert.throws(() => context.encodeCostPrices([{...customRows[0], model: "<unattributed>"}]));
for (const raw of ["null", "[]", "{", '{"x":{"inputCostPerMillionTokens":true,"outputCostPerMillionTokens":2}}',
  '{"x":{"inputCostPerMillionTokens":2}}', '{"x":{"inputCostPerMillionTokens":2,"outputCostPerMillionTokens":2,"extra":2}}'])
  assert.throws(() => context.decodeCostPrices(raw));
const specialId = context.encodeCostPrices([{...customRows[0], model: "__proto__"}]);
assert.ok(Object.prototype.hasOwnProperty.call(JSON.parse(specialId), "__proto__"));
console.log("Custom cost price validation: passed");
