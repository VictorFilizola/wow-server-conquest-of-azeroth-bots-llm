-- Regression coverage for editing a bot's background story.
--
-- The rule is the one the trait upload follows: a story the
-- player typed is never lost silently. Until the server says
-- it stored the text, the text stays in the boxes, nothing the
-- server sends may replace it, and it can be saved again.

local stub = require("wow_stub")

-- Set by the runner, which knows where the addon lives.
local ROOT = "."
local GUID = 7
local BASE = {"steady", "wry", "loyal"}
local STORED = "Born in Elwynn Forest."

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
        C:Encode(traits[3]), C:Encode(tone or "dry")
    )
end

local function storyLine(C, text)
    return "BACKSTORY " .. GUID .. " " .. C:Encode(text)
end

-- A bot picked from the roster, profile and story loaded.
local function loadedBot()
    local C = stub.load(ROOT)
    C.roster = {{guid = GUID, name = "Testbot"}}
    C:SelectBot(GUID)
    stub.serverSays(C, profileLine(C, BASE))
    stub.serverSays(C, storyLine(C, STORED))
    stub.clearSent()
    return C
end

-- Types into the floating editor's story box the way the
-- client would report it.
local function typeStory(C, text)
    C.frame.backstory:SetText(text)
    C:StoryTyped(C.frame)
end

local function checkStory(C, expected, label)
    checkEqual(
        C.frame.backstory:GetText(), expected,
        label .. " (editor)"
    )
    checkEqual(
        C.storiesPanel.backstory:GetText(), expected,
        label .. " (Background Stories)"
    )
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

local function confirmSaved(C)
    stub.serverSays(
        C, "BACKSTORY_SAVED " .. GUID .. " " .. C:Encode("Testbot")
    )
end

tests["a loaded story can be edited, and typing enables Save"] = function()
    local C = loadedBot()

    checkStory(C, STORED, "after load")
    checkEqual(C.frame.backstory.editable, true, "editable")
    checkEqual(
        C.frame.saveStoryBtn.enabled, false,
        "nothing to save before typing"
    )

    typeStory(C, "Raised in Goldshire.")

    checkStory(C, "Raised in Goldshire.", "both boxes follow")
    checkEqual(C.frame.saveStoryBtn.enabled, true, "Save Story")
    checkEqual(
        C.storiesPanel.saveStoryBtn.enabled, true,
        "Save Story in Background Stories"
    )
    checkEqual(
        C.frame.storyCount:GetText(), "20/1000", "counter"
    )

    typeStory(C, STORED)
    checkEqual(
        C.frame.saveStoryBtn.enabled, false,
        "typing the stored text back is not an edit"
    )
end

tests["a short story goes up as one line"] = function()
    local C = loadedBot()
    typeStory(C, "Raised in Goldshire.")

    C:SaveStory()

    checkEqual(
        stub.lastCommand(),
        "setbackstory " .. GUID .. " Raised%20in%20Goldshire.",
        "command sent"
    )
    checkEqual(C.saveLocked, true, "locked until confirmed")
    checkEqual(
        C.frame.saveStoryBtn.enabled, false,
        "no second save while one is in flight"
    )
    checkEqual(
        C.frame.backstory.editable, false,
        "no typing while the save is in flight"
    )

    confirmSaved(C)
    stub.serverSays(C, profileLine(C, BASE))
    stub.serverSays(C, storyLine(C, "Raised in Goldshire."))

    checkEqual(C.uploadState, nil, "upload closed")
    checkEqual(C.storyEdit, nil, "the edit is the saved story now")
    checkEqual(C.saveLocked, false, "unlocked")
    checkStory(C, "Raised in Goldshire.", "after the save")
    checkEqual(
        C.loadedBackstory, "Raised in Goldshire.", "loaded story"
    )
    checkEqual(
        C.frame.status:GetText(), "Story saved for Testbot.",
        "status"
    )
    checkEqual(C.frame.backstory.editable, true, "editable again")
end

tests["a long story goes up in chunks and commits"] = function()
    local C = loadedBot()
    local long = string.rep("Many winters passed. ", 40)
    long = long:sub(1, 799) .. "."
    typeStory(C, long)

    C:SaveStory()

    check(
        C.sendQueue[1] ~= nil
            and C.sendQueue[1]:sub(1, 9) == "put 7 bs ",
        "the story should be queued as bs chunks"
    )
    checkEqual(
        C.sendQueue[#C.sendQueue], "commit " .. GUID,
        "the commit closes the upload"
    )
    local total = #C.sendQueue - 1
    for i = 1, total do
        local seq, of, chunk = C.sendQueue[i]:match(
            "^put 7 bs (%d+) (%d+) (%S+)$"
        )
        checkEqual(tonumber(seq), i, "chunk order")
        checkEqual(tonumber(of), total, "chunk total")
        check(#chunk <= 200, "chunk within the server limit")
        check(
            #(".llmc " .. C.sendQueue[i]) <= 255,
            "line within the chat limit"
        )
    end

    stub.advance(C, total * 0.3 + 1)
    checkEqual(#C.sendQueue, 0, "everything sent")
    checkEqual(countSent("put 7 bs "), total, "chunks sent")
    checkEqual(countSent("commit "), 1, "commit sent")

    confirmSaved(C)
    stub.serverSays(C, profileLine(C, BASE))
    stub.serverSays(C, storyLine(C, long))
    checkEqual(C.uploadState, nil, "upload closed")
    checkEqual(C.storyEdit, nil, "the edit is the saved story now")
end

tests["a rejected story stays in the boxes"] = function()
    local C = loadedBot()
    typeStory(C, "Raised in Goldshire.")
    C:SaveStory()
    stub.clearSent()

    stub.serverSays(
        C,
        "ERROR validation "
            .. C:Encode("Bot has no traits yet.")
    )

    checkEqual(C.uploadState, nil, "upload closed")
    checkEqual(
        stub.sentCommand("cancel "), "cancel " .. GUID,
        "staged chunks are dropped server-side"
    )
    checkStory(C, "Raised in Goldshire.", "after rejection")
    checkEqual(
        C.frame.saveStoryBtn.enabled, true, "Save Story to retry"
    )
    checkEqual(
        C.frame.status:GetText(), "Bot has no traits yet.",
        "the reason is shown"
    )
end

-- An older server does not know the command at all.
tests["an unsupported server leaves the story recoverable"] = function()
    local C = loadedBot()
    typeStory(C, "Raised in Goldshire.")
    C:SaveStory()

    stub.serverSays(
        C,
        "ERROR usage " .. C:Encode(
            "Supported commands: roster, get, set, forget"
        )
    )

    checkEqual(C.uploadState, nil, "upload closed")
    checkStory(C, "Raised in Goldshire.", "after usage error")
    checkEqual(
        C.frame.saveStoryBtn.enabled, true, "Save Story to retry"
    )
end

tests["a silent server times out with the story intact"] = function()
    local C = loadedBot()
    typeStory(C, "Raised in Goldshire.")
    C:SaveStory()

    stub.advance(C, 21)

    checkEqual(C.uploadState, nil, "upload closed")
    checkEqual(C.saveLocked, false, "unlocked")
    checkStory(C, "Raised in Goldshire.", "after timeout")
    checkEqual(
        C.frame.saveStoryBtn.enabled, true, "Save Story to retry"
    )
    check(
        C.frame.status:GetText():find("still here", 1, true) ~= nil,
        "the player should be told the story survived"
    )
end

-- The save did land, but its confirmation came after the
-- timeout. The story is saved, so it stops being an edit.
tests["a late confirmation settles the edit"] = function()
    local C = loadedBot()
    typeStory(C, "Raised in Goldshire.")
    C:SaveStory()
    stub.advance(C, 21)

    confirmSaved(C)
    stub.serverSays(C, profileLine(C, BASE))
    stub.serverSays(C, storyLine(C, "Raised in Goldshire."))

    checkEqual(C.storyEdit, nil, "nothing left to save")
    checkEqual(
        C.frame.saveStoryBtn.enabled, false, "Save Story"
    )
    checkStory(C, "Raised in Goldshire.", "after late confirm")
end

-- Whatever the server sends while the player is editing, the
-- typed story stays.
tests["server lines do not replace a story being typed"] = function()
    local C = loadedBot()
    typeStory(C, "Raised in Gold")

    stub.serverSays(C, profileLine(C, BASE, "brisk"))
    stub.serverSays(C, storyLine(C, STORED))
    stub.serverSays(C, storyLine(C, "A different story."))

    checkStory(C, "Raised in Gold", "after server lines")
    checkEqual(
        C.loadedBackstory, "A different story.",
        "the server's story is still tracked"
    )
    checkEqual(C.frame.saveStoryBtn.enabled, true, "Save Story")
end

-- A profile line alone must not blank a story that is only
-- being read.
tests["a profile line leaves the story in place"] = function()
    local C = loadedBot()

    stub.serverSays(C, profileLine(C, BASE, "brisk"))

    checkStory(C, STORED, "after a profile line")
end

tests["an empty or oversized story is refused before sending"] = function()
    local C = loadedBot()

    typeStory(C, "   ")
    C:SaveStory()
    checkEqual(countSent("setbackstory"), 0, "empty story sent")
    check(
        C.frame.status:GetText():find("cannot be empty", 1, true)
            ~= nil,
        "empty story explained"
    )

    -- 1,001 two-byte characters: over the limit in characters.
    typeStory(C, string.rep("\195\169", 1001))
    C:SaveStory()
    checkEqual(countSent("put "), 0, "oversized story sent")
    checkEqual(C.uploadState, nil, "no upload started")
    check(
        C.frame.status:GetText():find("1000 characters", 1, true)
            ~= nil,
        "limit explained"
    )

    -- Exactly 1,000 two-byte characters is allowed: the limit
    -- counts characters, not bytes.
    typeStory(C, string.rep("\195\169", 1000))
    C:SaveStory()
    check(C.uploadState ~= nil, "a 1,000 character story uploads")
    check(#C.sendQueue - 1 <= 64, "within the server's chunk limit")
end

tests["switching bots abandons the story and its upload"] = function()
    local C = loadedBot()
    local long = string.rep("Many winters passed. ", 30)
    typeStory(C, long)
    C:SaveStory()
    stub.advance(C, 0.35)
    stub.clearSent()

    C.roster = {
        {guid = GUID, name = "Testbot"},
        {guid = 9, name = "Otherbot"},
    }
    C:SelectBot(9)

    checkEqual(
        stub.sentCommand("cancel "), "cancel " .. GUID,
        "the abandoned upload is cancelled"
    )
    checkEqual(C.uploadState, nil, "upload closed")
    checkEqual(#C.sendQueue, 0, "nothing left queued")
    checkEqual(C.storyEdit, nil, "the edit belonged to the other bot")
    checkStory(C, "", "the new bot starts empty")
    checkEqual(
        C.frame.backstory.editable, false,
        "no typing until the new profile loads"
    )
end

-- A new story replaces the one being typed, so the player is
-- asked first.
tests["regenerating over an unsaved story asks first"] = function()
    local C = loadedBot()
    typeStory(C, "Raised in Goldshire.")

    C:RegenBackstory()

    checkEqual(
        stub.popups[#stub.popups], "CHATTER_CONFIRM_REGEN_STORY",
        "confirmation"
    )
    checkEqual(countSent("regenbackstory"), 0, "nothing sent yet")
    checkStory(C, "Raised in Goldshire.", "while asking")

    C:DoRegenBackstory(GUID)

    checkEqual(
        stub.sentCommand("regenbackstory "),
        "regenbackstory " .. GUID, "after confirming"
    )
    checkEqual(C.storyEdit, nil, "the edit was given up")
    checkStory(C, "Creating background story...", "placeholder")
    checkEqual(
        C.frame.backstory.editable, false,
        "the placeholder is not text to edit"
    )
end

tests["regenerating without an edit needs no confirmation"] = function()
    local C = loadedBot()

    C:RegenBackstory()

    checkEqual(#stub.popups, 0, "no popup")
    checkEqual(
        stub.sentCommand("regenbackstory "),
        "regenbackstory " .. GUID, "sent"
    )

    stub.serverSays(C, storyLine(C, "A new tale."))
    checkStory(C, "A new tale.", "generated story shown")
    checkEqual(C.frame.backstory.editable, true, "editable again")
end

-- Changed traits make the server write a new story. A story
-- the player is editing survives that, but cannot be saved
-- until the generation is over: the worker clears the stored
-- story when it starts.
tests["a trait save keeps a story edit but holds its save"] = function()
    local C = loadedBot()
    typeStory(C, "Raised in Goldshire.")

    C.frame.trait3:SetText("restless")
    C.traitsPanel.trait3:SetText("restless")
    C:SaveProfile()
    C:DoSaveProfile()
    stub.serverSays(
        C,
        "UPDATED " .. GUID .. " " .. C:Encode("Testbot")
            .. " changed"
    )

    checkStory(C, "Raised in Goldshire.", "during generation")
    checkEqual(
        C.frame.saveStoryBtn.enabled, false,
        "Save Story waits for the generation"
    )
    C:SaveStory()
    checkEqual(countSent("setbackstory"), 0, "nothing sent early")

    stub.serverSays(C, storyLine(C, "A generated tale."))

    checkStory(C, "Raised in Goldshire.", "after generation")
    checkEqual(
        C.frame.saveStoryBtn.enabled, true,
        "Save Story once the generation is over"
    )
end

tests["traits cannot be saved while a story is going up"] = function()
    local C = loadedBot()
    local long = string.rep("Many winters passed. ", 30)
    typeStory(C, long)
    C:SaveStory()
    local queued = #C.sendQueue

    C.frame.trait3:SetText("restless")
    C.traitsPanel.trait3:SetText("restless")
    C:SaveProfile()
    C.pendingTraits = {
        guid = GUID, trait1 = "steady", trait2 = "wry",
        trait3 = "restless",
    }
    C:DoSaveProfile()

    checkEqual(#stub.popups, 0, "no trait confirmation")
    checkEqual(#C.sendQueue, queued, "the story upload is untouched")
    checkEqual(countSent("set "), 0, "no trait save sent")
    checkEqual(
        C.frame.saveBtn.enabled, false, "Save Traits while locked"
    )
end

-- The confirmation belongs to the bot it was asked about. If
-- the player picks another bot while it is open, confirming
-- must not regenerate that other bot's story.
tests["a regenerate confirmation cannot be retargeted"] = function()
    local C = loadedBot()
    typeStory(C, "Raised in Goldshire.")
    C:RegenBackstory()

    C.roster = {
        {guid = GUID, name = "Testbot"},
        {guid = 9, name = "Otherbot"},
    }
    C:SelectBot(9)
    stub.clearSent()

    -- What the dialog's Accept does with the guid it kept.
    C:DoRegenBackstory(GUID)

    checkEqual(
        countSent("regenbackstory"), 0,
        "nothing is regenerated for either bot"
    )
end

-- The addon gives up waiting after two minutes, but the job
-- queued on the server may only be starting, and it begins by
-- clearing the stored story. Saving stays held past the
-- addon's own timeout, and is released afterwards.
tests["Save Story stays held after the wait times out"] = function()
    local C = loadedBot()
    C:RegenBackstory()
    stub.advance(C, 121, 0.5)
    checkEqual(C.pendingBackstoryGuid, nil, "the wait has ended")

    typeStory(C, "Raised in Goldshire.")

    checkEqual(
        C.frame.backstory.editable, true, "typing is allowed"
    )
    checkEqual(
        C.frame.saveStoryBtn.enabled, false,
        "saving is still held"
    )
    stub.clearSent()
    C:SaveStory()
    checkEqual(countSent("setbackstory"), 0, "nothing sent")
    checkStory(C, "Raised in Goldshire.", "the text is kept")

    stub.advance(C, 30, 0.5)

    checkEqual(
        C.frame.saveStoryBtn.enabled, true,
        "saving is released once the job cannot start any more"
    )
    C:SaveStory()
    checkEqual(countSent("setbackstory"), 1, "now it is sent")
end

-- The generated story turns up after the addon stopped asking
-- (seen on a later Refresh, say). That is proof the job ran,
-- so saving is released without waiting out the clock.
tests["a generated story seen later releases Save Story"] = function()
    local C = loadedBot()
    C:RegenBackstory()
    stub.advance(C, 121, 0.5)
    typeStory(C, "Raised in Goldshire.")
    checkEqual(
        C.frame.saveStoryBtn.enabled, false, "held after timeout"
    )

    -- The old story proves nothing.
    stub.serverSays(C, storyLine(C, STORED))
    checkEqual(
        C.frame.saveStoryBtn.enabled, false,
        "the replaced story does not release it"
    )

    stub.serverSays(C, storyLine(C, "A new tale."))
    checkEqual(
        C.frame.saveStoryBtn.enabled, true,
        "the generated story does"
    )
    checkStory(C, "Raised in Goldshire.", "the typed text is kept")
end

-- Same when the wait ends on an error rather than a timeout.
tests["Save Story stays held after the wait ends in an error"] = function()
    local C = loadedBot()
    C:RegenBackstory()
    stub.serverSays(
        C, "ERROR missing " .. C:Encode("Could not load that bot profile")
    )
    checkEqual(C.pendingBackstoryGuid, nil, "the wait has ended")

    typeStory(C, "Raised in Goldshire.")

    checkEqual(
        C.frame.saveStoryBtn.enabled, false, "saving is held"
    )
end

-- A trait save that timed out can still have been applied,
-- and then it queued a story generation.
tests["a timed-out trait save still holds Save Story"] = function()
    local C = loadedBot()
    C.frame.trait3:SetText("restless")
    C.traitsPanel.trait3:SetText("restless")
    C:SaveProfile()
    C:DoSaveProfile()
    stub.advance(C, 21)
    checkEqual(C.uploadState, nil, "the trait save was given up")

    typeStory(C, "Raised in Goldshire.")

    checkEqual(
        C.frame.saveStoryBtn.enabled, false, "saving is held"
    )
end

-- A reply to a request made before Regenerate was clicked can
-- still carry the old story. It is not the new one.
tests["the replaced story is not taken for the new one"] = function()
    local C = loadedBot()
    C:RegenBackstory()

    stub.serverSays(C, storyLine(C, STORED))

    checkEqual(
        C.pendingBackstoryGuid, GUID, "still waiting"
    )
    checkStory(C, "Creating background story...", "placeholder")

    stub.serverSays(C, storyLine(C, "A new tale."))

    checkEqual(C.pendingBackstoryGuid, nil, "wait over")
    checkStory(C, "A new tale.", "new story shown")
end

-- A trait save timed out, the player moved on to saving a
-- story, and only then does the trait save's confirmation
-- arrive. It must not close the story upload.
tests["a late trait confirmation leaves a story upload alone"] = function()
    local C = loadedBot()
    C.frame.trait3:SetText("restless")
    C.traitsPanel.trait3:SetText("restless")
    C:SaveProfile()
    C:DoSaveProfile()
    stub.advance(C, 21)
    -- Past the hold, so a story may be saved again.
    stub.advance(C, 150, 0.5)

    local long = string.rep("Many winters passed. ", 30)
    typeStory(C, long)
    C:SaveStory()
    local queued = #C.sendQueue
    check(queued > 1, "the story upload should be queued")

    stub.serverSays(
        C,
        "UPDATED " .. GUID .. " " .. C:Encode("Testbot")
            .. " changed"
    )
    stub.serverSays(
        C, profileLine(C, {"steady", "wry", "restless"}, "")
    )

    checkEqual(C.uploadKind, "story", "the story upload is open")
    checkEqual(C.uploadState, "sending", "and still sending")
    checkEqual(#C.sendQueue, queued, "with its chunks intact")
    checkEqual(C.saveLocked, true, "and the editor locked")
    checkEqual(
        C.pendingToneGuid, nil,
        "no wait is started behind the upload"
    )
    checkStory(C, long, "story text")
end

-- The other way round: a story save timed out, a trait save
-- is in flight, and the story's confirmation turns up.
tests["a late story confirmation leaves a trait upload alone"] = function()
    local C = loadedBot()
    typeStory(C, "Raised in Goldshire.")
    C:SaveStory()
    stub.advance(C, 21)
    checkEqual(C.uploadState, nil, "the story save was given up")

    local edited = {
        string.rep("one ", 15):sub(1, 59),
        string.rep("two ", 15):sub(1, 59),
        string.rep("six ", 15):sub(1, 59),
    }
    for i = 1, 3 do
        C.frame["trait" .. i]:SetText(edited[i])
        C.traitsPanel["trait" .. i]:SetText(edited[i])
    end
    C:SaveProfile()
    C:DoSaveProfile()
    local queued = #C.sendQueue
    check(queued > 1, "the trait upload should be queued")

    confirmSaved(C)
    stub.serverSays(C, profileLine(C, BASE))
    stub.serverSays(C, storyLine(C, "Raised in Goldshire."))

    checkEqual(C.uploadKind, "traits", "the trait upload is open")
    checkEqual(C.uploadState, "sending", "and still sending")
    checkEqual(#C.sendQueue, queued, "with its chunks intact")
    checkEqual(C.saveLocked, true, "and the editor locked")
    checkEqual(
        C.frame.trait1:GetText(), edited[1],
        "the typed traits are untouched"
    )
end

-- The acknowledgement names no text, so on its own it proves
-- nothing about which save it belongs to. The save is settled
-- by the BACKSTORY line carrying the text that was sent,
-- tidied the way it was sent.
tests["only the stored text settles a story save"] = function()
    local C = loadedBot()
    typeStory(C, "Raised   in\nGoldshire.")
    C:SaveStory()

    confirmSaved(C)

    checkEqual(C.uploadKind, "story", "still open after the ack")
    checkEqual(C.saveLocked, true, "still locked after the ack")
    checkStory(C, "Raised   in\nGoldshire.", "typed text kept")

    stub.serverSays(C, profileLine(C, BASE))
    stub.serverSays(C, storyLine(C, "Raised in Goldshire."))

    checkEqual(C.uploadState, nil, "closed by the stored text")
    checkEqual(
        C.loadedBackstory, "Raised in Goldshire.", "story on record"
    )
    checkStory(C, "Raised in Goldshire.", "boxes")
    checkEqual(
        C.frame.saveStoryBtn.enabled, false, "nothing left to save"
    )
end

-- The reviewer's case. A story save times out, the player
-- types a different story and saves that, and only then does
-- the first save's confirmation arrive with the first text.
-- It must not close the second save or put the first text in
-- the boxes.
tests["a late story confirmation leaves a newer story save alone"] = function()
    local C = loadedBot()
    typeStory(C, "First story.")
    C:SaveStory()
    stub.advance(C, 21)
    checkEqual(C.uploadState, nil, "the first save was given up")

    typeStory(C, "Second story.")
    C:SaveStory()
    checkEqual(C.uploadState, "awaiting", "second save in flight")

    confirmSaved(C)
    stub.serverSays(C, profileLine(C, BASE))
    stub.serverSays(C, storyLine(C, "First story."))

    checkEqual(C.uploadKind, "story", "second save still open")
    checkEqual(C.uploadState, "awaiting", "and still awaited")
    checkEqual(C.saveLocked, true, "and the editor locked")
    check(C.storyEdit ~= nil, "the second story is still an edit")
    checkStory(C, "Second story.", "boxes hold the second story")

    confirmSaved(C)
    stub.serverSays(C, profileLine(C, BASE))
    stub.serverSays(C, storyLine(C, "Second story."))

    checkEqual(C.uploadState, nil, "closed by its own text")
    checkEqual(C.storyEdit, nil, "saved")
    checkStory(C, "Second story.", "after the second save")
end

-- The same with the newer save still going up in chunks.
tests["a late story confirmation leaves a draining story upload alone"] = function()
    local C = loadedBot()
    typeStory(C, "First story.")
    C:SaveStory()
    stub.advance(C, 21)

    local long = string.rep("Many winters passed. ", 30)
    typeStory(C, long)
    C:SaveStory()
    local queued = #C.sendQueue
    check(queued > 1, "the second save should be queued in chunks")

    confirmSaved(C)
    stub.serverSays(C, profileLine(C, BASE))
    stub.serverSays(C, storyLine(C, "First story."))

    checkEqual(C.uploadState, "sending", "still sending")
    checkEqual(#C.sendQueue, queued, "with its chunks intact")
    checkEqual(C.saveLocked, true, "and the editor locked")
    checkStory(C, long, "boxes hold the second story")

    -- And if the second save then fails, its text is still
    -- there to retry.
    stub.serverSays(
        C, "ERROR chunk " .. C:Encode("Upload is incomplete")
    )
    checkEqual(C.uploadState, nil, "aborted")
    checkStory(C, long, "text kept after the rejection")
    checkEqual(
        C.frame.saveStoryBtn.enabled, true, "Save Story to retry"
    )
end

-- Forgetting other bots has nothing to do with the story
-- being typed for the selected one. It stays through the
-- batch and through the roster refresh that follows it.
tests["forgetting another bot keeps the story being typed"] = function()
    local C = loadedBot()
    C.roster = {
        {guid = GUID, name = "Testbot"},
        {guid = 9, name = "Otherbot"},
    }
    typeStory(C, "My unsaved story.")

    C:StartForgetBatch({9})
    check(C.storyEdit ~= nil, "the edit survives the start")
    checkEqual(
        C.frame.backstory.editable, false,
        "no typing while bots are being forgotten"
    )

    stub.advance(C, 0.35)
    stub.serverSays(C, "FORGOTTEN 9 " .. C:Encode("Otherbot"))
    -- The batch ends by asking for the roster again.
    stub.serverSays(C, "ROSTER_BEGIN")
    stub.serverSays(C, "ROSTER " .. GUID .. " " .. C:Encode("Testbot"))
    stub.serverSays(C, "ROSTER_END")
    stub.serverSays(C, profileLine(C, BASE))
    stub.serverSays(C, storyLine(C, STORED))

    checkEqual(C.selectedGuid, GUID, "same bot selected")
    checkStory(C, "My unsaved story.", "after the refresh")
    checkEqual(
        C.frame.saveStoryBtn.enabled, true, "still saveable"
    )
    checkEqual(C.frame.backstory.editable, true, "editable again")
end

-- A batch that stops on an error refreshes the roster too.
tests["a failed forget batch keeps the story being typed"] = function()
    local C = loadedBot()
    C.roster = {
        {guid = GUID, name = "Testbot"},
        {guid = 9, name = "Otherbot"},
    }
    typeStory(C, "My unsaved story.")

    C:StartForgetBatch({9})
    stub.advance(C, 0.35)
    stub.serverSays(
        C, "ERROR access " .. C:Encode("That bot is not in your Chatter roster")
    )
    stub.serverSays(C, "ROSTER_BEGIN")
    stub.serverSays(C, "ROSTER " .. GUID .. " " .. C:Encode("Testbot"))
    stub.serverSays(C, "ROSTER " .. 9 .. " " .. C:Encode("Otherbot"))
    stub.serverSays(C, "ROSTER_END")
    stub.serverSays(C, profileLine(C, BASE))
    stub.serverSays(C, storyLine(C, STORED))

    checkStory(C, "My unsaved story.", "after the failed batch")
    checkEqual(
        C.frame.saveStoryBtn.enabled, true, "still saveable"
    )
end

-- Its own bot being forgotten is the one deletion that does
-- take the story with it.
tests["forgetting the story's own bot drops the story"] = function()
    local C = loadedBot()
    typeStory(C, "My unsaved story.")

    C:StartForgetBatch({GUID})

    checkEqual(C.storyEdit, nil, "the edit goes with its bot")
end

-- Refresh brings the roster back with the same bot selected.
-- That is not the player choosing the bot again.
tests["Refresh keeps the story being typed"] = function()
    local C = loadedBot()
    typeStory(C, "My unsaved story.")

    C:RequestRoster()
    stub.serverSays(C, "ROSTER_BEGIN")
    stub.serverSays(C, "ROSTER " .. GUID .. " " .. C:Encode("Testbot"))
    stub.serverSays(C, "ROSTER_END")
    checkStory(C, "My unsaved story.", "while the profile reloads")
    stub.serverSays(C, profileLine(C, BASE))
    stub.serverSays(C, storyLine(C, STORED))

    checkStory(C, "My unsaved story.", "after Refresh")
    checkEqual(
        C.frame.saveStoryBtn.enabled, true, "still saveable"
    )
end

-- Clicking the bot in the list is how an edit is given up.
tests["clicking the bot again discards the story being typed"] = function()
    local C = loadedBot()
    typeStory(C, "My unsaved story.")

    C:SelectBot(GUID)
    stub.serverSays(C, profileLine(C, BASE))
    stub.serverSays(C, storyLine(C, STORED))

    checkEqual(C.storyEdit, nil, "the edit was given up")
    checkStory(C, STORED, "the server's story is back")
end

-- Stories are switched off on the server. Regenerate Story is
-- refused at once, with the stored story left in place; the
-- addon must not sit on a placeholder for two minutes.
tests["a server with stories off ends Regenerate at once"] = function()
    local C = loadedBot()
    C:RegenBackstory()
    checkStory(C, "Creating background story...", "placeholder")

    stub.serverSays(
        C,
        "ERROR disabled " .. C:Encode(
            "Background stories are switched off on this server"
        )
    )

    checkEqual(C.pendingBackstoryGuid, nil, "the wait has ended")
    checkStory(C, STORED, "the stored story is back")
    checkEqual(
        C.frame.regenStoryBtn.enabled, true, "Regenerate usable"
    )
    checkEqual(
        C.frame.status:GetText(),
        "Background stories are switched off on this server",
        "the reason is shown"
    )
    stub.clearSent()
    stub.advance(C, 6)
    checkEqual(countSent("get "), 0, "nothing is asked afterwards")

    -- Nothing was queued, so a story of the player's own can
    -- be saved straight away.
    typeStory(C, "Raised in Goldshire.")
    checkEqual(
        C.frame.saveStoryBtn.enabled, true, "Save Story not held"
    )
end

-- The same switch on a trait change: the reply says that only
-- the tone is being regenerated.
tests["a trait change with stories off waits for the tone only"] = function()
    local C = loadedBot()
    C.frame.trait3:SetText("restless")
    C.traitsPanel.trait3:SetText("restless")
    C:SaveProfile()
    C:DoSaveProfile()

    stub.serverSays(
        C,
        "UPDATED " .. GUID .. " " .. C:Encode("Testbot")
            .. " changed nostory"
    )

    checkEqual(C.uploadState, nil, "the save is confirmed")
    checkEqual(C.pendingToneGuid, GUID, "the tone is awaited")
    checkEqual(C.pendingBackstoryGuid, nil, "no story is awaited")
    checkStory(C, "", "the cleared story, not a placeholder")
    checkEqual(
        C.frame.status:GetText(), "Saved. Regenerating tone...",
        "status"
    )
    checkEqual(
        C.frame.regenStoryBtn.enabled, true, "Regenerate usable"
    )

    typeStory(C, "Raised in Goldshire.")
    checkEqual(
        C.frame.saveStoryBtn.enabled, true, "Save Story not held"
    )
end

-- A story being typed is kept through that reply too.
tests["a trait change with stories off keeps a typed story"] = function()
    local C = loadedBot()
    typeStory(C, "Raised in Goldshire.")
    C.frame.trait3:SetText("restless")
    C.traitsPanel.trait3:SetText("restless")
    C:SaveProfile()
    C:DoSaveProfile()

    stub.serverSays(
        C,
        "UPDATED " .. GUID .. " " .. C:Encode("Testbot")
            .. " changed nostory"
    )

    checkStory(C, "Raised in Goldshire.", "typed story")
    checkEqual(
        C.frame.saveStoryBtn.enabled, true, "saveable at once"
    )
end

-- An ordinary error during the wait also takes the
-- placeholder down, but keeps saving held: a job may exist.
tests["an error during the wait restores the stored story"] = function()
    local C = loadedBot()
    C:RegenBackstory()

    stub.serverSays(
        C, "ERROR missing " .. C:Encode("Could not load that bot profile")
    )

    checkStory(C, STORED, "the story on record is shown")
    typeStory(C, "Raised in Goldshire.")
    checkEqual(
        C.frame.saveStoryBtn.enabled, false, "saving stays held"
    )
end

return function(root)
    ROOT = root
    return tests
end
