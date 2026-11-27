-- Regression coverage for the wait on generated tone and
-- backstory: how often the addon asks the server, when it
-- stays quiet, and what a reply may and may not touch.
--
-- Every `get` is answered with both a PROFILE and a BACKSTORY
-- line, and each one costs the server several database reads,
-- so the two waits share a single request rather than asking
-- twice. A reply only ever fills in the generated text: the
-- trait boxes belong to the player once a profile is loaded.

local stub = require("wow_stub")

-- Set by the runner, which knows where the addon lives.
local ROOT = "."
local GUID = 7
local BASE = {"steady", "wry", "loyal"}

local tests = {}

local function check(condition, message)
    if not condition then
        error(message, 2)
    end
end

local function checkEqual(actual, expected, label)
    if actual ~= expected then
        error(string.format(
            "%s: expected %s, got %s",
            label, tostring(expected), tostring(actual)
        ), 2)
    end
end

local function profileLine(C, traits, tone)
    return string.format(
        "PROFILE %d %s %s %s %s %s",
        GUID, C:Encode("Testbot"),
        C:Encode(traits[1]), C:Encode(traits[2]),
        C:Encode(traits[3]), C:Encode(tone or "")
    )
end

local function loadedBot()
    local C = stub.load(ROOT)
    C.roster = {{guid = GUID, name = "Testbot"}}
    C:SelectBot(GUID)
    stub.serverSays(C, profileLine(C, BASE, "dry"))
    stub.clearSent()
    return C
end

local function typeTraits(C, traits)
    for i = 1, 3 do
        C.frame["trait" .. i]:SetText(traits[i])
        C.traitsPanel["trait" .. i]:SetText(traits[i])
    end
end

local function countSent(prefix)
    local count = 0
    for _, command in ipairs(stub.commands()) do
        if command:sub(1, #prefix) == prefix then
            count = count + 1
        end
    end
    return count
end

-- After a trait change both tone and backstory are awaited.
-- One request per interval answers both.
tests["both waits share one request"] = function()
    local C = loadedBot()
    C:StartTonePoll(GUID)
    C:StartBackstoryPoll(GUID)

    stub.advance(C, 10.1)

    checkEqual(
        countSent("get " .. GUID), 5,
        "requests in ten seconds with both waits running"
    )
end

-- Losing one of the two waits must not stop the other.
tests["the backstory wait carries on alone"] = function()
    local C = loadedBot()
    C:StartTonePoll(GUID)
    C:StartBackstoryPoll(GUID)

    stub.serverSays(C, profileLine(C, BASE, "brisk"))
    checkEqual(C.pendingToneGuid, nil, "tone wait after its reply")
    checkEqual(
        C.pendingBackstoryGuid, GUID, "backstory wait"
    )
    stub.clearSent()

    stub.advance(C, 4.1)
    checkEqual(
        countSent("get " .. GUID), 2,
        "requests in four seconds with one wait left"
    )

    stub.serverSays(
        C, "BACKSTORY " .. GUID .. " " .. C:Encode("Born in Elwynn.")
    )
    checkEqual(
        C.pendingBackstoryGuid, nil,
        "backstory wait after its reply"
    )
    stub.clearSent()

    stub.advance(C, 6)
    checkEqual(
        countSent("get "), 0,
        "nothing is asked once both have arrived"
    )
end

-- While a save is still going up, every reply is discarded as
-- stale, and an extra request would share the chat line budget
-- with the paced chunks. Asking starts once the save is
-- confirmed.
tests["nothing is asked while a save is in flight"] = function()
    local C = loadedBot()
    local long = string.rep("word ", 12):sub(1, 59)
    typeTraits(C, {long .. "a", long .. "b", long .. "c"})
    C:SaveProfile()
    C:DoSaveProfile()
    check(
        C.uploadState ~= nil, "the save should be in flight"
    )

    stub.advance(C, 12)
    checkEqual(
        countSent("get "), 0,
        "requests while the server has not confirmed the save"
    )

    stub.clearSent()
    stub.serverSays(
        C,
        "UPDATED " .. GUID .. " " .. C:Encode("Testbot")
            .. " changed"
    )
    stub.advance(C, 2.1)
    checkEqual(
        countSent("get " .. GUID), 1,
        "requests once the save is confirmed"
    )
end

-- The reviewer's case: generation is still running, the player
-- starts typing the next change, and a poll reply arrives with
-- the traits the server holds. The reply may bring the tone;
-- it may not take the typing away.
tests["a poll reply does not wipe what is being typed"] = function()
    local C = loadedBot()
    C:StartTonePoll(GUID)
    C:StartBackstoryPoll(GUID)

    local typing = {"steady", "wry", "restless"}
    typeTraits(C, typing)

    stub.serverSays(C, profileLine(C, BASE, ""))
    stub.serverSays(C, profileLine(C, BASE, "brisk"))

    for _, panel in ipairs({C.frame, C.traitsPanel}) do
        for i = 1, 3 do
            checkEqual(
                panel["trait" .. i]:GetText(), typing[i],
                "trait" .. i .. " after the poll replies"
            )
        end
    end
    checkEqual(
        C.frame.tone:GetText(), "brisk",
        "the generated tone should still be shown"
    )
    checkEqual(
        C.frame.saveBtn.enabled, true,
        "the typed change should be saveable"
    )
end

-- With nothing typed, a repeated profile still refreshes the
-- boxes, so a change made elsewhere shows up.
tests["an untouched editor follows the server"] = function()
    local C = loadedBot()

    local elsewhere = {"gruff", "wry", "loyal"}
    stub.serverSays(C, profileLine(C, elsewhere, "dry"))

    checkEqual(
        C.frame.trait1:GetText(), "gruff",
        "trait1 after the server's traits changed"
    )
    checkEqual(
        C.frame.saveBtn.enabled, false,
        "nothing is unsaved"
    )
end

-- Picking a bot always starts from what the server holds,
-- whatever was typed for the previous selection.
tests["a fresh selection replaces typed text"] = function()
    local C = loadedBot()
    typeTraits(C, {"one", "two", "three"})

    C:SelectBot(GUID)
    stub.serverSays(C, profileLine(C, BASE, "dry"))

    checkEqual(
        C.frame.trait1:GetText(), BASE[1],
        "trait1 after reselecting the bot"
    )
end

-- A bot can leave the roster on the server while it is still
-- listed here: memories of a session too short to keep are
-- discarded. The refusal ends the wait instead of being asked
-- for again every two seconds until the timeout.
tests["a refused request ends the wait"] = function()
    local C = loadedBot()
    C:StartTonePoll(GUID)
    C:StartBackstoryPoll(GUID)

    stub.serverSays(
        C,
        "ERROR access "
            .. C:Encode("That bot is not in your Chatter roster")
    )

    checkEqual(C.pendingToneGuid, nil, "tone wait")
    checkEqual(C.pendingBackstoryGuid, nil, "backstory wait")
    checkEqual(
        C.frame.status:GetText(),
        "That bot is not in your Chatter roster",
        "the reason should be shown"
    )

    stub.clearSent()
    stub.advance(C, 6)
    checkEqual(
        countSent("get "), 0, "requests after the refusal"
    )
end

-- A profile that will never load must not leave the editor
-- waiting for it.
tests["a refused load is not left pending"] = function()
    local C = stub.load(ROOT)
    C.roster = {{guid = GUID, name = "Testbot"}}
    C:SelectBot(GUID)
    checkEqual(C.pendingProfileGuid, GUID, "load in progress")

    stub.serverSays(
        C,
        "ERROR access "
            .. C:Encode("That bot is not in your Chatter roster")
    )

    checkEqual(C.pendingProfileGuid, nil, "load after refusal")
    checkEqual(
        C.frame.regenStoryBtn.enabled, false,
        "no story to regenerate for a bot that did not load"
    )
    checkEqual(
        C.frame.saveBtn.enabled, false,
        "nothing to save for a bot that did not load"
    )
end

return function(root)
    ROOT = root
    return tests
end
