pragma Singleton
import QtQuick
import Quickshell
import "T3CodeHelpers.js" as Helpers

// Everything the user has typed but not yet sent: per-thread composer drafts
// with their provider/model/runtime selection, the new-thread draft, and the
// answers being assembled for a structured input request.
//
// A singleton on purpose, and it must stay one. T3CodePopover is rebuilt from
// scratch every time the dropdown opens (see the note at the top of that
// file), so anything held there would be discarded mid-sentence. Drafts live
// out here precisely so they survive that teardown.
//
// Pure state: it computes selections and assembles payloads, and hands them to
// T3Rpc to send. Nothing here talks to the socket.
Singleton {
    id: root

    // Server configuration, bound in from T3Code. Read-only in spirit: the
    // protocol layer owns these, this layer only selects against them.
    property var providerConfigurations: []
    property bool configReady: false
    property bool hasReadyProvider: false

    property var userInputDrafts: ({})
    property var userInputQuestionIndices: ({})

    // Composer state belongs to the process-wide singleton so Loader teardown,
    // navigation, and reconnects never discard text or selections.
    property var threadDrafts: ({})
    property var newThreadDraft: ({})
    property var pendingDraftMessages: ({})
    property string pendingNewThreadId: ""
    property string pendingNewThreadActionKey: ""
    readonly property string newThreadDefaultModel: "gpt-5.6-sol"
    readonly property string newThreadDefaultEffort: "high"

    signal newThreadConfirmed(string threadId)


    // ---- composer drafts and provider selection --------------------------

    function providerConfiguration(instanceId) {
        return Helpers.findProvider(providerConfigurations, instanceId);
    }

    function providerIcon(instanceId) {
        const provider = providerConfiguration(instanceId);
        return Helpers.providerIconName(provider ? provider.driver : instanceId);
    }

    function threadProviderIcon(threadId) {
        return Helpers.threadProviderIconName(T3Threads.rawThread(threadId), providerConfigurations);
    }

    function threadSelectionLabel(threadId) {
        return Helpers.threadSelectionLabel(T3Threads.rawThread(threadId), providerConfigurations);
    }

    function modelConfiguration(instanceId, model) {
        return Helpers.findModel(providerConfiguration(instanceId), model);
    }

    function canonicalOptions(raw) {
        if (Array.isArray(raw))
            return raw.filter(option => option && typeof option.id === "string"
                && (typeof option.value === "string" || typeof option.value === "boolean"))
                .map(option => ({ id: option.id, value: option.value }));
        const result = [];
        if (raw && typeof raw === "object") {
            for (const id in raw) {
                if (typeof raw[id] === "string" || typeof raw[id] === "boolean")
                    result.push({ id: id, value: raw[id] });
            }
        }
        return result;
    }

    function normalizedOptions(instanceId, model, raw) {
        const config = modelConfiguration(instanceId, model);
        if (!config)
            return canonicalOptions(raw);
        return Helpers.traitSelections(Helpers.normalizeTraits(config.optionDescriptors, raw));
    }

    function selectionFromDraft(draft) {
        if (!draft)
            return null;
        const provider = providerConfiguration(draft.instanceId);
        const model = Helpers.findModel(provider, draft.model);
        if (!provider || provider.ready !== true || !model)
            return null;
        return {
            instanceId: provider.instanceId,
            model: model.slug,
            options: normalizedOptions(provider.instanceId, model.slug, draft.options)
        };
    }

    function defaultNewThreadSelection(project) {
        return Helpers.selectionForNewThread(project, providerConfigurations, {
            model: newThreadDefaultModel,
            effort: newThreadDefaultEffort
        });
    }

    function reconcileDraftSelections() {
        let draftsChanged = false;
        const drafts = Object.assign({}, threadDrafts);
        for (const threadId in drafts) {
            const draft = drafts[threadId];
            let selection = selectionFromDraft(draft);
            if (!selection)
                selection = Helpers.selectionForThread(T3Threads.threadMap[threadId], providerConfigurations);
            if (!selection)
                continue;
            const current = {
                instanceId: draft.instanceId ?? "",
                model: draft.model ?? "",
                options: canonicalOptions(draft.options)
            };
            if (!Helpers.sameSelection(current, selection)) {
                drafts[threadId] = Object.assign({}, draft, {
                    instanceId: selection.instanceId,
                    model: selection.model,
                    options: selection.options ?? [],
                    traitError: ""
                });
                draftsChanged = true;
            }
        }
        if (draftsChanged)
            threadDrafts = drafts;

        if (newThreadDraft && typeof newThreadDraft.projectId === "string"
                && newThreadDraft.projectId !== "") {
            let newSelection = selectionFromDraft(newThreadDraft);
            if (!newSelection)
                newSelection = defaultNewThreadSelection(T3Threads.projectMap[newThreadDraft.projectId]);
            if (newSelection) {
                const currentNew = {
                    instanceId: newThreadDraft.instanceId ?? "",
                    model: newThreadDraft.model ?? "",
                    options: canonicalOptions(newThreadDraft.options)
                };
                if (!Helpers.sameSelection(currentNew, newSelection)) {
                    newThreadDraft = Object.assign({}, newThreadDraft, {
                        instanceId: newSelection.instanceId,
                        model: newSelection.model,
                        options: newSelection.options ?? [],
                        traitError: ""
                    });
                }
            }
        }
    }

    function makeThreadDraft(thread) {
        const persisted = thread && thread.modelSelection ? thread.modelSelection : {};
        const resolved = Helpers.selectionForThread(thread, providerConfigurations);
        const selection = resolved ?? persisted;
        return {
            prompt: "",
            instanceId: selection.instanceId ?? thread?.session?.providerInstanceId ?? "",
            model: selection.model ?? "",
            options: normalizedOptions(selection.instanceId ?? "", selection.model ?? "",
                selection.options),
            runtimeMode: thread?.runtimeMode ?? "full-access",
            interactionMode: thread?.interactionMode ?? "default",
            traitError: ""
        };
    }

    function ensureThreadDraft(threadId) {
        if (threadDrafts[threadId] !== undefined)
            return threadDrafts[threadId];
        const thread = T3Threads.threadMap[threadId];
        if (!thread)
            return null;
        const next = Object.assign({}, threadDrafts);
        next[threadId] = makeThreadDraft(thread);
        threadDrafts = next;
        return next[threadId];
    }

    function threadDraft(threadId) {
        return threadDrafts[threadId] ?? ({ prompt: "", instanceId: "", model: "",
            options: [], runtimeMode: "full-access", interactionMode: "default",
            traitError: "" });
    }

    function updateThreadDraft(threadId, fields) {
        const current = ensureThreadDraft(threadId);
        if (!current)
            return;
        const drafts = Object.assign({}, threadDrafts);
        drafts[threadId] = Object.assign({}, current, fields);
        threadDrafts = drafts;
    }

    function setThreadPrompt(threadId, prompt) {
        updateThreadDraft(threadId, { prompt: typeof prompt === "string" ? prompt : "" });
    }

    function setThreadProvider(threadId, instanceId) {
        const thread = T3Threads.threadMap[threadId];
        const allowed = Helpers.selectableProvidersForThread(thread, providerConfigurations,
            T3Detail.detailThreadId === threadId ? T3Detail.detailMessages.length : 0);
        const provider = Helpers.findProvider(allowed, instanceId);
        if (!provider)
            return;
        const model = Helpers.defaultModel(provider);
        if (!Helpers.modelChangeAllowed(thread, { instanceId: instanceId, model: model },
                providerConfigurations, T3Detail.detailThreadId === threadId ? T3Detail.detailMessages.length : 0)) {
            updateThreadDraft(threadId, {
                traitError: "This provider requires a new thread to change models"
            });
            return;
        }
        const modelConfig = Helpers.findModel(provider, model);
        updateThreadDraft(threadId, {
            instanceId: provider.instanceId,
            model: model,
            options: normalizedOptions(provider.instanceId, model,
                modelConfig ? null : []),
            traitError: ""
        });
    }

    function setThreadModel(threadId, model) {
        const thread = T3Threads.threadMap[threadId];
        const draft = threadDraft(threadId);
        const provider = providerConfiguration(draft.instanceId);
        const config = Helpers.findModel(provider, model);
        if (!config)
            return;
        const nextSelection = { instanceId: draft.instanceId, model: model };
        if (!Helpers.modelChangeAllowed(thread, nextSelection, providerConfigurations,
                T3Detail.detailThreadId === threadId ? T3Detail.detailMessages.length : 0)) {
            updateThreadDraft(threadId, {
                traitError: "This provider requires a new thread to change models"
            });
            return;
        }
        updateThreadDraft(threadId, {
            model: model,
            options: normalizedOptions(draft.instanceId, model, null),
            traitError: ""
        });
    }

    function setThreadRuntime(threadId, runtimeMode) {
        updateThreadDraft(threadId, { runtimeMode: runtimeMode });
    }

    function setThreadInteraction(threadId, interactionMode) {
        updateThreadDraft(threadId, { interactionMode: interactionMode });
    }

    function threadProviderChoices(threadId) {
        const thread = T3Threads.threadMap[threadId];
        const detailCount = T3Detail.detailThreadId === threadId ? T3Detail.detailMessages.length : 0;
        const currentInstanceId = thread?.session?.providerInstanceId
            ?? thread?.modelSelection?.instanceId ?? "";
        return Helpers.selectableProvidersForThread(thread, providerConfigurations, detailCount)
            .filter(provider => provider.instanceId === currentInstanceId
                || Helpers.modelChangeAllowed(thread, {
                    instanceId: provider.instanceId,
                    model: Helpers.defaultModel(provider)
                }, providerConfigurations, detailCount));
    }

    function threadModelChoices(threadId) {
        const draft = threadDraft(threadId);
        const provider = providerConfiguration(draft.instanceId);
        if (!provider)
            return [];
        return provider.models.filter(model => Helpers.modelChangeAllowed(T3Threads.threadMap[threadId],
            { instanceId: provider.instanceId, model: model.slug }, providerConfigurations,
            T3Detail.detailThreadId === threadId ? T3Detail.detailMessages.length : 0));
    }

    // The composer picks a provider and a model with one gesture, so the two
    // travel as a single choice. Keeping the pair joined also sidesteps a real
    // trap: stepping through a provider's *default* model can trip a
    // per-thread guard that the model the user actually asked for would pass.
    readonly property string selectionSeparator: "::"

    function selectionId(instanceId, model) {
        return String(instanceId ?? "") + selectionSeparator + String(model ?? "");
    }

    function setThreadSelection(threadId, instanceId, model) {
        const thread = T3Threads.threadMap[threadId];
        const detailCount = T3Detail.detailThreadId === threadId
            ? T3Detail.detailMessages.length : 0;
        const provider = Helpers.findProvider(
            Helpers.selectableProvidersForThread(thread, providerConfigurations, detailCount),
            instanceId);
        if (!provider || !Helpers.findModel(provider, model))
            return;
        if (!Helpers.modelChangeAllowed(thread, { instanceId: instanceId, model: model },
                providerConfigurations, detailCount)) {
            updateThreadDraft(threadId, {
                traitError: "This provider requires a new thread to change models"
            });
            return;
        }
        updateThreadDraft(threadId, {
            instanceId: provider.instanceId,
            model: model,
            options: normalizedOptions(provider.instanceId, model, null),
            traitError: ""
        });
    }

    function setNewSelection(instanceId, model) {
        const provider = Helpers.findProvider(providerConfigurations, instanceId);
        if (!provider || provider.ready !== true || !Helpers.findModel(provider, model))
            return;
        updateNewThreadDraft({ instanceId: provider.instanceId, model: model,
            options: normalizedOptions(provider.instanceId, model, null), traitError: "" });
    }

    // ---- model picker ----------------------------------------------------

    function providerRail() {
        return Helpers.providerRailEntries(providerConfigurations);
    }

    // A model the thread's guard rejects is listed with its reason rather
    // than dropped: an option that silently disappears reads as a bug in the
    // server, not as a rule.
    function threadModelChangeReason(threadId, instanceId, model) {
        const thread = T3Threads.threadMap[threadId];
        const detailCount = T3Detail.detailThreadId === threadId
            ? T3Detail.detailMessages.length : 0;
        return Helpers.modelChangeAllowed(thread, { instanceId: instanceId, model: model },
            providerConfigurations, detailCount)
            ? "" : "Start a new thread to use this model";
    }

    function threadPickerRows(threadId, railId, query, legacyExpanded) {
        return Helpers.assignPickerShortcuts(Helpers.modelPickerRows({
            providers: providerConfigurations,
            favorites: T3Favorites.favorites,
            railId: railId,
            query: query,
            legacyExpanded: legacyExpanded,
            allow: (instanceId, model) =>
                threadModelChangeReason(threadId, instanceId, model)
        }));
    }

    function newPickerRows(railId, query, legacyExpanded) {
        return Helpers.assignPickerShortcuts(Helpers.modelPickerRows({
            providers: providerConfigurations,
            favorites: T3Favorites.favorites,
            railId: railId,
            query: query,
            legacyExpanded: legacyExpanded
        }));
    }

    function draftTraitDescriptors(draft) {
        const model = draft ? modelConfiguration(draft.instanceId, draft.model) : null;
        return Helpers.traitsForPrompt(model ? model.optionDescriptors : [],
            draft ? draft.options : [], draft ? draft.prompt : "");
    }

    function updateThreadTrait(threadId, descriptorId, value) {
        const draft = threadDraft(threadId);
        const result = Helpers.applyTraitValue(draftTraitDescriptors(draft), descriptorId,
            value, draft.prompt);
        updateThreadDraft(threadId, { options: result.selections, prompt: result.prompt,
            traitError: result.error });
    }

    function defaultProjectId(contextThreadId) {
        const context = T3Threads.threadMap[contextThreadId];
        if (context && T3Threads.projectMap[context.projectId])
            return context.projectId;
        const projects = T3Threads.sortedProjects();
        return projects.length > 0 ? projects[0].id : "";
    }

    function buildNewDraft(projectId, prompt, sourceProposedPlan, projectFixed, modeFixed) {
        const project = T3Threads.projectMap[projectId];
        const selection = defaultNewThreadSelection(project);
        return {
            projectId: projectId,
            projectFixed: projectFixed === true,
            modeFixed: modeFixed === true,
            prompt: typeof prompt === "string" ? prompt : "",
            instanceId: selection ? selection.instanceId : "",
            model: selection ? selection.model : "",
            options: selection && Array.isArray(selection.options) ? selection.options : [],
            runtimeMode: "full-access",
            interactionMode: "default",
            sourceProposedPlan: sourceProposedPlan ?? null,
            traitError: ""
        };
    }

    function ensureNewThreadDraft(contextThreadId) {
        if (newThreadDraft && typeof newThreadDraft.projectId === "string"
                && newThreadDraft.projectId !== "")
            return newThreadDraft;
        const projectId = defaultProjectId(contextThreadId);
        newThreadDraft = buildNewDraft(projectId, "", null, false, false);
        return newThreadDraft;
    }

    function updateNewThreadDraft(fields) {
        newThreadDraft = Object.assign({}, newThreadDraft, fields);
    }

    function setNewPrompt(prompt) {
        updateNewThreadDraft({ prompt: typeof prompt === "string" ? prompt : "" });
    }

    function setNewProject(projectId) {
        if (newThreadDraft.projectFixed === true || !T3Threads.projectMap[projectId])
            return;
        const replacement = buildNewDraft(projectId, newThreadDraft.prompt, null, false, false);
        newThreadDraft = replacement;
    }

    function setNewProvider(instanceId) {
        const provider = Helpers.findProvider(providerConfigurations, instanceId);
        if (!provider || provider.ready !== true)
            return;
        const model = Helpers.defaultModel(provider);
        updateNewThreadDraft({ instanceId: instanceId, model: model,
            options: normalizedOptions(instanceId, model, null), traitError: "" });
    }

    function setNewModel(model) {
        const provider = providerConfiguration(newThreadDraft.instanceId);
        if (!Helpers.findModel(provider, model))
            return;
        updateNewThreadDraft({ model: model,
            options: normalizedOptions(newThreadDraft.instanceId, model, null),
            traitError: "" });
    }

    function setNewRuntime(runtimeMode) {
        updateNewThreadDraft({ runtimeMode: runtimeMode });
    }

    function setNewInteraction(interactionMode) {
        if (newThreadDraft.modeFixed !== true)
            updateNewThreadDraft({ interactionMode: interactionMode });
    }

    function updateNewTrait(descriptorId, value) {
        const result = Helpers.applyTraitValue(draftTraitDescriptors(newThreadDraft),
            descriptorId, value, newThreadDraft.prompt);
        updateNewThreadDraft({ options: result.selections, prompt: result.prompt,
            traitError: result.error });
    }

    function newProviderChoices() {
        return providerConfigurations.filter(provider => provider.ready === true
            && provider.models.length > 0);
    }

    function newModelChoices() {
        const provider = providerConfiguration(newThreadDraft.instanceId);
        return provider ? provider.models : [];
    }

    function providerShowsInteraction(instanceId) {
        const provider = providerConfiguration(instanceId);
        return provider ? provider.showInteractionModeToggle !== false : true;
    }

    function prepareNewThreadForPlan(sourceThreadId, plan) {
        const source = T3Threads.threadMap[sourceThreadId];
        if (!source || !plan)
            return false;
        newThreadDraft = buildNewDraft(source.projectId,
            Helpers.buildPlanImplementationPrompt(plan.planMarkdown),
            { threadId: sourceThreadId, planId: plan.id }, true, true);
        return true;
    }

    function putPendingDraftMessage(threadId, value) {
        const next = Object.assign({}, pendingDraftMessages);
        if (value === null)
            delete next[threadId];
        else
            next[threadId] = value;
        pendingDraftMessages = next;
    }

    function confirmDraftMessage(threadId, messageId) {
        const pending = pendingDraftMessages[threadId];
        if (!pending || pending.messageId !== messageId)
            return;
        if (pending.clearDraft === true) {
            const current = threadDraft(threadId);
            if (current.prompt === pending.prompt)
                updateThreadDraft(threadId, Helpers.draftAfterOutcome(current, "confirmed"));
        }
        putPendingDraftMessage(threadId, null);
    }

    function submitExisting(threadId, overrideText, interactionOverride, sourceProposedPlan,
            clearDraft) {
        const thread = T3Threads.threadMap[threadId];
        const draft = threadDraft(threadId);
        const key = T3Rpc.actionKey("prompt", threadId, "");
        const text = typeof overrideText === "string" ? overrideText : draft.prompt;
        if (!thread || text.trim() === "")
            return T3Rpc.rejectAction(key, "Write a message first", false);
        if (text.length > Helpers.MAX_PROMPT_CHARS)
            return T3Rpc.rejectAction(key, "Prompt exceeds T3 Code's 120,000 character limit", false);
        if (!Helpers.canOperateLifecycle(thread, Date.now()))
            return T3Rpc.rejectAction(key, "Wait for the thread to become idle", false);
        const interactionMode = interactionOverride ?? draft.interactionMode;
        if (!sourceProposedPlan && thread.hasActionableProposedPlan === true
                && interactionMode !== "plan")
            return T3Rpc.rejectAction(key, "Choose a plan action before continuing", false);
        const selection = selectionFromDraft(draft);
        if (!selection)
            return T3Rpc.rejectAction(key, "Choose a ready provider and model", false);
        if (!Helpers.modelChangeAllowed(thread, selection, providerConfigurations,
                T3Detail.detailThreadId === threadId ? T3Detail.detailMessages.length : 0))
            return T3Rpc.rejectAction(key, "Start a new thread to change this model", false);
        const createdAt = new Date().toISOString();
        const messageId = T3Rpc.genId();
        const commands = Helpers.buildExistingTurnCommands({
            currentThread: thread,
            modelSelection: selection,
            runtimeMode: draft.runtimeMode,
            interactionMode: interactionMode,
            text: text,
            messageId: messageId,
            sourceProposedPlan: sourceProposedPlan ?? null,
            createdAt: createdAt,
            nextId: () => T3Rpc.genId()
        });
        putPendingDraftMessage(threadId, { messageId: messageId, prompt: text,
            clearDraft: clearDraft !== false });
        return T3Rpc.dispatchBatch(commands, key, {
            // RPC acceptance is not the same as seeing the persisted message.
            // Keep the draft until the detail event (or a reconnect snapshot)
            // confirms this exact message id.
            onSuccess: () => {},
            onFailure: () => { /* draft and correlation stay for reconnect reconciliation */ }
        });
    }

    function startTurn(threadId, text) {
        setThreadPrompt(threadId, text);
        return submitExisting(threadId, undefined, undefined, null, true);
    }

    function implementPlanHere(threadId, plan) {
        if (!plan)
            return "";
        updateThreadDraft(threadId, { interactionMode: "default" });
        return submitExisting(threadId, Helpers.buildPlanImplementationPrompt(plan.planMarkdown),
            "default", { threadId: threadId, planId: plan.id }, false);
    }

    function refinePlan(threadId) {
        updateThreadDraft(threadId, { interactionMode: "plan" });
    }

    function submitNewThread() {
        const draft = newThreadDraft;
        const key = T3Rpc.actionKey("new", "", "");
        const text = draft && typeof draft.prompt === "string" ? draft.prompt : "";
        if (!hasReadyProvider)
            return T3Rpc.rejectAction(key, configReady ? "No provider with an advertised model is ready"
                : "Provider configuration is not ready", false);
        if (!draft || !T3Threads.projectMap[draft.projectId])
            return T3Rpc.rejectAction(key, "Choose a project", false);
        if (text.trim() === "")
            return T3Rpc.rejectAction(key, "Write the first prompt", false);
        if (text.length > Helpers.MAX_PROMPT_CHARS)
            return T3Rpc.rejectAction(key, "Prompt exceeds T3 Code's 120,000 character limit", false);
        const selection = selectionFromDraft(draft);
        if (!selection)
            return T3Rpc.rejectAction(key, "Choose a ready provider and model", false);
        const threadId = T3Rpc.genId();
        const createdAt = new Date().toISOString();
        const command = Helpers.buildNewThreadCommand({
            threadId: threadId,
            projectId: draft.projectId,
            text: text,
            modelSelection: selection,
            runtimeMode: draft.runtimeMode,
            interactionMode: draft.modeFixed === true ? "default" : draft.interactionMode,
            sourceProposedPlan: draft.sourceProposedPlan,
            messageId: T3Rpc.genId(),
            createdAt: createdAt,
            nextId: () => T3Rpc.genId()
        });
        pendingNewThreadId = threadId;
        pendingNewThreadActionKey = key;
        const dispatched = T3Rpc.dispatchBatch([command], key, {
            holdAfterSuccess: true,
            onSuccess: () => {
                const current = T3Rpc.actionStates[key];
                if (current)
                    T3Rpc.putActionState(key, Object.assign({}, current, {
                        pending: true, startedAt: Date.now(), phase: "awaiting-shell"
                    }));
            }
        });
        if (dispatched === "") {
            pendingNewThreadId = "";
            pendingNewThreadActionKey = "";
        }
        return dispatched;
    }

    function reconcileNewThreadCreation(candidateId) {
        if (pendingNewThreadId === "")
            return;
        if (candidateId !== undefined && candidateId !== pendingNewThreadId)
            return;
        if (!T3Threads.threadMap[pendingNewThreadId])
            return;
        const confirmed = pendingNewThreadId;
        if (pendingNewThreadActionKey !== "")
            T3Rpc.clearAction(pendingNewThreadActionKey);
        pendingNewThreadId = "";
        pendingNewThreadActionKey = "";
        newThreadDraft = ({});
        newThreadConfirmed(confirmed);
    }

    // ---- structured-input drafts ----------------------------------------

    function inputRequestKey(threadId, requestId) {
        return threadId + "|" + requestId;
    }

    function inputDraftKey(threadId, requestId, questionId) {
        return inputRequestKey(threadId, requestId) + "|" + questionId;
    }

    function inputDraft(threadId, requestId, questionId) {
        return userInputDrafts[inputDraftKey(threadId, requestId, questionId)] ?? {
            selected: [], custom: ""
        };
    }

    function inputSelectedLabels(threadId, requestId, questionId) {
        const selected = inputDraft(threadId, requestId, questionId).selected;
        return Array.isArray(selected) ? selected : [];
    }

    function inputCustomAnswer(threadId, requestId, questionId) {
        const custom = inputDraft(threadId, requestId, questionId).custom;
        return typeof custom === "string" ? custom : "";
    }

    function toggleInputOption(threadId, requestId, questionId, label, multiSelect) {
        if (typeof label !== "string" || label.trim() === "")
            return;
        const key = inputDraftKey(threadId, requestId, questionId);
        const current = inputDraft(threadId, requestId, questionId);
        let selected = Array.isArray(current.selected) ? current.selected.slice() : [];
        if (multiSelect === true) {
            const at = selected.indexOf(label);
            if (at >= 0)
                selected.splice(at, 1);
            else
                selected.push(label);
        } else {
            selected = [label];
        }
        const next = Object.assign({}, userInputDrafts);
        next[key] = { selected: selected, custom: "" };
        userInputDrafts = next;
    }

    function setInputCustomAnswer(threadId, requestId, questionId, value) {
        const key = inputDraftKey(threadId, requestId, questionId);
        const current = inputDraft(threadId, requestId, questionId);
        const custom = typeof value === "string" ? value : "";
        const next = Object.assign({}, userInputDrafts);
        next[key] = {
            selected: custom.trim() !== "" ? []
                : (Array.isArray(current.selected) ? current.selected : []),
            custom: custom
        };
        userInputDrafts = next;
    }

    function inputQuestionIndex(threadId, requestId) {
        const value = userInputQuestionIndices[inputRequestKey(threadId, requestId)];
        return typeof value === "number" && isFinite(value) ? Math.max(0, Math.floor(value)) : 0;
    }

    function setInputQuestionIndex(threadId, requestId, value) {
        const next = Object.assign({}, userInputQuestionIndices);
        next[inputRequestKey(threadId, requestId)] = Math.max(0, Math.floor(value));
        userInputQuestionIndices = next;
    }

    function resolvedInputAnswer(threadId, requestId, question) {
        if (!question || typeof question.id !== "string")
            return null;
        const draft = inputDraft(threadId, requestId, question.id);
        const custom = typeof draft.custom === "string" ? draft.custom.trim() : "";
        if (custom !== "")
            return custom;
        const selected = Array.isArray(draft.selected)
            ? draft.selected.filter(label => typeof label === "string" && label.trim() !== "") : [];
        if (question.multiSelect === true)
            return selected.length > 0 ? selected : null;
        return selected.length > 0 ? selected[0] : null;
    }

    function inputQuestionAnswered(threadId, requestId, question) {
        return resolvedInputAnswer(threadId, requestId, question) !== null;
    }

    function buildInputAnswers(threadId, pendingInput) {
        if (!pendingInput || !Array.isArray(pendingInput.questions)
                || pendingInput.questions.length === 0)
            return null;
        const answers = {};
        for (const question of pendingInput.questions) {
            const answer = resolvedInputAnswer(threadId, pendingInput.requestId, question);
            if (answer === null)
                return null;
            answers[question.id] = answer;
        }
        return answers;
    }

    function clearUserInputDraft(threadId, requestId) {
        const requestKey = inputRequestKey(threadId, requestId);
        const prefix = requestKey + "|";
        const drafts = Object.assign({}, userInputDrafts);
        let changed = false;
        for (const key in drafts) {
            if (key.indexOf(prefix) === 0) {
                delete drafts[key];
                changed = true;
            }
        }
        if (changed)
            userInputDrafts = drafts;
        if (userInputQuestionIndices[requestKey] !== undefined) {
            const indices = Object.assign({}, userInputQuestionIndices);
            delete indices[requestKey];
            userInputQuestionIndices = indices;
        }
    }
}
