local Chatter = CreateFrame("Frame", "ChatterEventFrame")

Chatter.prefix = "CHATTER_ADDON "
Chatter.roster = {}
Chatter.pendingRoster = nil
Chatter.selectedGuid = nil
Chatter.pendingProfileGuid = nil
Chatter.pendingToneGuid = nil
Chatter.tonePollRemaining = 0
Chatter.pendingBackstoryGuid = nil
Chatter.backstoryPollRemaining = 0
-- Tone and backstory are both answered by the same `get`, so
-- the two polls share one request clock.
Chatter.pollElapsed = 0
Chatter.sendQueue = {}
Chatter.sendElapsed = 0
Chatter.saveLocked = false
Chatter.saveLockRemaining = 0
Chatter.uploadGuid = nil
-- nil, "sending" while commands are still leaving the queue,
-- "awaiting" once the last one is out and only the server's
-- answer is outstanding. Sending a commit and having it
-- applied are separate things, and the difference decides
-- when a timeout is meaningful.
Chatter.uploadState = nil
-- What the player typed for the bot being saved. Kept until
-- the server confirms the save so a rejection or a timeout
-- can hand the edit back instead of losing it.
Chatter.unsavedTraits = nil
-- The story the server last sent for the selected bot.
Chatter.loadedBackstory = nil
-- A story the player has typed and the server has not taken
-- yet: { guid, text }. It exists from the first keystroke
-- until the server confirms it or the player picks a bot
-- again, and while it exists nothing the server sends may
-- replace the text in the story boxes.
Chatter.storyEdit = nil
-- Which save the open upload is, "traits" or "story". Each
-- kind has its own acknowledgement, and one arriving late for
-- an upload that was given up must not close a newer upload of
-- the other kind.
Chatter.uploadKind = nil
-- Per bot, while a story generation this addon asked for may
-- still be about to run: { remaining, replaced }. `replaced`
-- is the story that was on record when it was asked for.
Chatter.storyHolds = {}

-- The client cuts an outgoing chat line at 255 characters.
local MAX_CHAT_LENGTH = 255
-- Longest percent-encoded payload carried by one `put`.
local CHUNK_BUDGET = 200
-- One message per interval keeps the upload clear of chat
-- flood protection.
local SEND_INTERVAL = 0.3
-- How long to wait for the server's answer once the whole
-- upload has been sent. It deliberately does not cover the
-- upload itself, which is paced at SEND_INTERVAL and takes as
-- long as it takes: a clock started earlier would be racing
-- the send queue rather than measuring the server.
local SAVE_LOCK_TIMEOUT = 20
-- Seconds between `get` requests while generated text is
-- awaited, and how long to keep asking before giving up.
local POLL_INTERVAL = 2
local POLL_TIMEOUT = 120
-- Server limits: characters, not bytes.
local MAX_STORY_CHARS = 1000
-- The server accepts at most this many chunks per field.
local MAX_CHUNKS = 64
-- A queued generation job starts by clearing the stored story,
-- so a story saved before it runs would be erased. Saving is
-- therefore held after anything that queues a job, however the
-- addon's own wait for the result ends, until the generated
-- story is seen. If it never is, the hold lapses after this
-- many seconds: the server stops handing out a job 120 seconds
-- after it was queued, and a commit may land a little after
-- the addon stopped waiting for it. That is a best effort, not
-- a guarantee. A job already handed out can still be waiting
-- its turn, and only the server could refuse to clear a story
-- saved in the meantime.
local STORY_HOLD = 150

local function trim(value)
    if not value then
        return ""
    end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Counts UTF-8 characters, matching SetMaxLetters on the
-- edit boxes and the VARCHAR(64) columns on the server.
-- Continuation bytes are 0x80-0xBF and are not counted.
local function utf8len(value)
    local _, count = string.gsub(value or "", "[^\128-\191]", "")
    return count
end

local function sanitizeInput(value)
    value = trim(value or "")
    value = value:gsub("[%c]", " ")
    value = value:gsub("%s+", " ")
    return trim(value)
end

-- The client replaces %f (focus name) and %t (target name) in
-- every outgoing chat line, case-insensitively, so an escape
-- must never read %F. Bytes 0xF0-0xFF, which only occur in
-- 4-byte UTF-8 characters, are written as ~FX instead, and ~
-- itself is always escaped so it can only start one of those.
function Chatter:Encode(value)
    value = sanitizeInput(value)
    if value == "" then
        return "-"
    end

    return (value:gsub("([^%w%-_%.])", function(char)
        local byte = string.byte(char)
        if byte >= 0xF0 then
            return string.format("~%02X", byte)
        end
        return string.format("%%%02X", byte)
    end))
end

function Chatter:Decode(value)
    if not value or value == "-" then
        return ""
    end

    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

function Chatter:GetActivePanel()
    if self.frame and self.frame:IsShown() then
        return self.frame
    end
    if self.traitsPanel and self.traitsPanel:IsShown() then
        return self.traitsPanel
    end
    return self.frame
end

function Chatter:SetStatus(text, r, g, b)
    local panels = {}
    if self.frame then
        table.insert(panels, self.frame)
    end
    if self.traitsPanel then
        table.insert(panels, self.traitsPanel)
    end
    if self.storiesPanel then
        table.insert(panels, self.storiesPanel)
    end
    for _, p in ipairs(panels) do
        if p.status then
            p.status:SetText(text or "")
            p.status:SetTextColor(
                r or 1, g or 0.82, b or 0
            )
        end
    end
end

function Chatter:SendCommand(command)
    SendChatMessage(".llmc " .. command, "SAY")
end

function Chatter:QueueCommand(command)
    table.insert(self.sendQueue, command)
end

function Chatter:FlushSendQueue()
    self.sendQueue = {}
    self.sendElapsed = 0
end

function Chatter:HandleSendQueue(elapsed)
    if #self.sendQueue == 0 then
        return
    end

    self.sendElapsed = self.sendElapsed + elapsed
    if self.sendElapsed < SEND_INTERVAL then
        return
    end

    self.sendElapsed = 0
    self:SendCommand(table.remove(self.sendQueue, 1))

    if #self.sendQueue == 0 and self.uploadState == "sending" then
        -- The commit has left, but the server has not said
        -- what it did with it. The upload stays open until it
        -- answers; only the wait for that answer is timed.
        self:BeginConfirmWait()
    end
end

-- Splits an encoded value on a character budget without ever
-- cutting a %XX or ~FX escape in half.
local function startsEscape(char)
    return char == "%" or char == "~"
end

function Chatter:SplitEncoded(encoded, budget)
    local chunks = {}
    local total = string.len(encoded)
    local pos = 1

    while pos <= total do
        local stop = pos + budget - 1
        if stop >= total then
            stop = total
        elseif startsEscape(string.sub(encoded, stop, stop)) then
            stop = stop - 1
        elseif startsEscape(string.sub(encoded, stop - 1, stop - 1)) then
            stop = stop - 2
        end

        if stop < pos then
            return nil
        end

        table.insert(chunks, string.sub(encoded, pos, stop))
        pos = stop + 1
    end

    return chunks
end

function Chatter:LockSave()
    self.saveLocked = true
    self.saveLockRemaining = 0
    self:SetSaveEnabled(false)
    self:UpdateStoryControls()
end

-- The whole upload is out on the wire, so from here on
-- silence is the server failing to answer rather than the
-- queue still working through its chunks.
function Chatter:BeginConfirmWait()
    self.uploadState = "awaiting"
    self.saveLockRemaining = SAVE_LOCK_TIMEOUT
end

function Chatter:UnlockSave()
    self.saveLocked = false
    self.saveLockRemaining = 0
    self:UpdateSaveButton()
    self:UpdateStoryControls()
end

function Chatter:HandleSaveLock(elapsed)
    if not self.saveLocked or self.uploadState ~= "awaiting" then
        return
    end

    self.saveLockRemaining = self.saveLockRemaining - elapsed
    if self.saveLockRemaining <= 0 then
        self:AbortUpload(
            "The server did not answer. Your changes are"
                .. " still here — save again to retry.",
            1, 0.82, 0
        )
    end
end

-- Ends an upload that will not complete, whether the server
-- rejected it, never answered, or the player moved on.
-- Everything belonging to it goes at once: a queue left
-- draining would still send `commit` for an abandoned edit,
-- and a poll left running would pull the pre-save profile
-- back over the boxes.
function Chatter:AbortUpload(message, r, g, b)
    if self.uploadGuid then
        self:FlushSendQueue()
        -- Ignored by the server when it holds nothing staged,
        -- so it is safe from every abort path.
        self:SendCommand("cancel " .. self.uploadGuid)
    end
    self.uploadGuid = nil
    self.uploadState = nil
    self.uploadKind = nil
    self:StopTonePoll()
    self:StopBackstoryPoll()
    self:RestoreUnsavedTraits()
    self:RestoreStoryEdit()
    self:UnlockSave()
    if message then
        self:SetStatus(message, r, g, b)
    end
end

local function eachStoryPanel(self, fn)
    if self.frame and self.frame.backstory then
        fn(self.frame)
    end
    if self.storiesPanel and self.storiesPanel.backstory then
        fn(self.storiesPanel)
    end
end

-- Writes a story into both story boxes, as server text.
function Chatter:ShowStory(text, r, g, b)
    text = text or ""
    eachStoryPanel(self, function(p)
        -- Rewriting identical text would only throw the
        -- reader back to the top of a long story.
        if p.backstory:GetText() ~= text then
            p.backstory:SetText(text)
        end
        p.backstory:SetTextColor(r or 0.7, g or 0.7, b or 0.7)
    end)
end

-- The unsaved story for the selected bot, if there is one.
function Chatter:GetStoryEdit()
    local e = self.storyEdit
    if e and e.guid == self.selectedGuid then
        return e
    end
    return nil
end

-- Puts the story the player typed back into both boxes, so
-- an abandoned save can be corrected and retried.
function Chatter:RestoreStoryEdit()
    local e = self:GetStoryEdit()
    if e then
        self:ShowStory(e.text, 1, 1, 1)
    end
end

-- Called by the editor whenever the player types in a story
-- box. Both boxes follow each other, and the text becomes an
-- unsaved edit as soon as it differs from the server's story.
function Chatter:StoryTyped(source)
    if not self.selectedGuid or not source
        or not source.backstory then
        return
    end
    local text = source.backstory:GetText() or ""
    eachStoryPanel(self, function(p)
        if p ~= source then
            p.backstory:SetText(text)
        end
        p.backstory:SetTextColor(1, 1, 1)
    end)
    if sanitizeInput(text) ~= (self.loadedBackstory or "") then
        self.storyEdit = {guid = self.selectedGuid, text = text}
    else
        self.storyEdit = nil
    end
    self:UpdateStoryControls()
end

-- Starts (or restarts) the wait before a story may be saved
-- for this bot. Called for everything that queues a story
-- generation on the server.
function Chatter:HoldStorySave(guid)
    guid = tonumber(guid)
    if not guid then
        return
    end
    local hold = self.storyHolds[guid]
    if hold then
        -- Asked again before the first one finished: the
        -- story being replaced is still the earlier one.
        hold.remaining = STORY_HOLD
    else
        local replaced = nil
        if guid == self.selectedGuid then
            replaced = self.loadedBackstory
        end
        self.storyHolds[guid] = {
            remaining = STORY_HOLD,
            replaced = replaced,
        }
    end
    self:UpdateStoryControls()
end

function Chatter:HandleStoryHolds(elapsed)
    local released = false
    for guid, hold in pairs(self.storyHolds) do
        hold.remaining = hold.remaining - elapsed
        if hold.remaining <= 0 then
            self.storyHolds[guid] = nil
            released = true
        end
    end
    if released then
        self:UpdateStoryControls()
    end
end

-- Decides whether the story can be typed in and saved, and
-- keeps the character counter current.
function Chatter:UpdateStoryControls()
    local edit = self:GetStoryEdit()
    local idle = (
        self.loadedTraits ~= nil
        and self.loadedBackstory ~= nil
        and not self.pendingProfileGuid
        and not self.uploadState
        and not self.saveLocked
        and not self.forgetQueue
    )
    -- While a story is being generated the box shows a
    -- placeholder, which is not text to edit. An edit that
    -- already exists stays editable throughout.
    local canEdit = idle and (
        not self.pendingBackstoryGuid or edit ~= nil
    )
    -- Saving waits for a running generation to finish: the
    -- worker begins by clearing the stored story, so a save
    -- that lands first would be thrown away.
    local canSave = (
        idle and edit ~= nil and not self.pendingBackstoryGuid
        and not self.storyHolds[self.selectedGuid or 0]
    )
    eachStoryPanel(self, function(p)
        local box = p.backstory
        box.editable = canEdit
        if box.EnableMouse then
            box:EnableMouse(canEdit)
        end
        if not canEdit and box.ClearFocus then
            box:ClearFocus()
        end
        if p.saveStoryBtn then
            if canSave then
                p.saveStoryBtn:Enable()
            else
                p.saveStoryBtn:Disable()
            end
        end
        if p.storyCount then
            if edit then
                local count = utf8len(sanitizeInput(edit.text))
                p.storyCount:SetText(
                    count .. "/" .. MAX_STORY_CHARS
                )
                if count > MAX_STORY_CHARS then
                    p.storyCount:SetTextColor(1, 0.2, 0.2)
                else
                    p.storyCount:SetTextColor(0.7, 0.7, 0.7)
                end
            else
                p.storyCount:SetText("")
            end
        end
    end)
end

-- Puts the traits the player typed back into both editors so
-- an abandoned save can be corrected and retried rather than
-- silently reverting to what the server still holds.
function Chatter:RestoreUnsavedTraits()
    local t = self.unsavedTraits
    if not t or t.guid ~= self.selectedGuid then
        return
    end

    local function apply(p)
        if not p then return end
        if p.trait1 then p.trait1:SetText(t.trait1 or "") end
        if p.trait2 then p.trait2:SetText(t.trait2 or "") end
        if p.trait3 then p.trait3:SetText(t.trait3 or "") end
    end
    apply(self.frame)
    apply(self.traitsPanel)
end

function Chatter:StopTonePoll()
    self.pendingToneGuid = nil
    self.tonePollRemaining = 0
end

function Chatter:StartTonePoll(guid)
    guid = tonumber(guid)
    if not guid then
        return
    end

    self.pendingToneGuid = guid
    self.pollElapsed = 0
    self.tonePollRemaining = POLL_TIMEOUT

    local function applyPlaceholder(panel)
        if not panel then return end
        if panel.tone then
            panel.tone:SetTextColor(0.5, 0.5, 0.5)
            panel.tone:SetText("Generating tone...")
        end
    end
    applyPlaceholder(self.frame)
    applyPlaceholder(self.traitsPanel)
end

-- Drives both polls. Each `get` is answered with a PROFILE
-- and a BACKSTORY line, so one request per interval serves
-- whichever of the two is still awaited.
function Chatter:HandlePolls(elapsed)
    if not self.pendingToneGuid
        and not self.pendingBackstoryGuid then
        return
    end
    -- Replies are ignored while an upload is open, and a
    -- request sent now would only crowd the paced upload
    -- towards chat flood protection. UPDATED restarts the
    -- polls with a fresh clock once the save is confirmed.
    if self.uploadState then
        return
    end

    if self.pendingToneGuid then
        self.tonePollRemaining = self.tonePollRemaining - elapsed
        if self.tonePollRemaining <= 0 then
            self:SetStatus(
                "Tone generation is still pending. Use Refresh.",
                1, 0.82, 0
            )
            self:StopTonePoll()
        end
    end

    if self.pendingBackstoryGuid then
        self.backstoryPollRemaining =
            self.backstoryPollRemaining - elapsed
        if self.backstoryPollRemaining <= 0 then
            self:SetStatus(
                "Backstory generation still pending."
                .. " Use Refresh.",
                1, 0.82, 0
            )
            self:StopBackstoryPoll()
        end
    end

    local guid = self.pendingToneGuid or self.pendingBackstoryGuid
    if not guid then
        return
    end

    self.pollElapsed = self.pollElapsed + elapsed
    if self.pollElapsed < POLL_INTERVAL then
        return
    end

    self.pollElapsed = 0
    self:SendCommand("get " .. guid)
    if self.pendingBackstoryGuid
        and self.pendingBackstoryGuid ~= guid then
        self:SendCommand("get " .. self.pendingBackstoryGuid)
    end
end

function Chatter:SetRegenStoryEnabled(enabled)
    local function apply(p)
        if not p or not p.regenStoryBtn then
            return
        end
        if enabled then
            p.regenStoryBtn:Enable()
        else
            p.regenStoryBtn:Disable()
        end
    end
    apply(self.frame)
    apply(self.traitsPanel)
    apply(self.storiesPanel)
end

function Chatter:SetSaveEnabled(enabled)
    local function apply(p)
        if not p or not p.saveBtn then return end
        if enabled then
            p.saveBtn:Enable()
        else
            p.saveBtn:Disable()
        end
    end
    apply(self.frame)
    apply(self.traitsPanel)
end

function Chatter:UpdateSaveButton()
    if self.saveLocked then
        self:SetSaveEnabled(false)
        return
    end

    if self.pendingProfileGuid or self.forgetQueue then
        self:SetSaveEnabled(false)
        return
    end
    self:SetSaveEnabled(self:TraitsEdited())
end

-- True when the trait boxes hold something other than the
-- traits last loaded from the server.
function Chatter:TraitsEdited()
    local loaded = self.loadedTraits
    local p = self:GetActivePanel()
    if not loaded or not p then
        return false
    end
    local t1 = sanitizeInput(
        p.trait1 and p.trait1:GetText() or ""
    )
    local t2 = sanitizeInput(
        p.trait2 and p.trait2:GetText() or ""
    )
    local t3 = sanitizeInput(
        p.trait3 and p.trait3:GetText() or ""
    )
    return (
        t1 ~= (loaded.trait1 or "")
        or t2 ~= (loaded.trait2 or "")
        or t3 ~= (loaded.trait3 or "")
    )
end

function Chatter:StopBackstoryPoll()
    self.pendingBackstoryGuid = nil
    self.backstoryPollRemaining = 0
    self:SetRegenStoryEnabled(true)
    self:UpdateStoryControls()
end

function Chatter:StartBackstoryPoll(guid)
    guid = tonumber(guid)
    if not guid then
        return
    end

    -- The story on record when the wait begins is the one
    -- being replaced. A reply already on its way can still
    -- carry it, and must not be taken for the new story.
    if self.pendingBackstoryGuid ~= guid then
        local before = nil
        if guid == self.selectedGuid then
            before = self.loadedBackstory
        end
        self.replacedStory = (before and before ~= "") and before
            or nil
    end
    self.pendingBackstoryGuid = guid
    self.pollElapsed = 0
    self.backstoryPollRemaining = POLL_TIMEOUT

    self:SetRegenStoryEnabled(false)

    -- Show the placeholder, unless the boxes hold a story
    -- the player is still editing.
    if not self:GetStoryEdit() then
        self:ShowStory(
            "Creating background story...", 0.5, 0.5, 0.5
        )
    end
    self:UpdateStoryControls()
end

function Chatter:SaveWindowPosition()
    if not self.frame then
        return
    end

    local point, _, relPoint, x, y =
        self.frame:GetPoint(1)
    ChatterDB = ChatterDB or {}
    ChatterDB.point = point
    ChatterDB.relPoint = relPoint
    ChatterDB.x = x
    ChatterDB.y = y
end

function Chatter:RestoreWindowPosition()
    if not self.frame then
        return
    end

    self.frame:ClearAllPoints()
    if ChatterDB and ChatterDB.point then
        self.frame:SetPoint(
            ChatterDB.point,
            UIParent,
            ChatterDB.relPoint or ChatterDB.point,
            ChatterDB.x or 0,
            ChatterDB.y or 0
        )
    else
        self.frame:SetPoint("CENTER")
    end
end

-- `keepTraits` leaves the three trait boxes alone while still
-- refreshing tone and backstory, for profiles that arrive
-- when the player has edits the server has not accepted yet.
-- `keepStory` leaves the story box alone: a PROFILE line never
-- carries the story, which arrives on its own BACKSTORY line.
function Chatter:ApplyProfileToPanel(p, profile, keepTraits, keepStory)
    if not p then
        return
    end
    if p.trait1 and not keepTraits then
        p.trait1:SetText(profile.trait1 or "")
    end
    if p.trait2 and not keepTraits then
        p.trait2:SetText(profile.trait2 or "")
    end
    if p.trait3 and not keepTraits then
        p.trait3:SetText(profile.trait3 or "")
    end
    if p.tone then
        local toneText = profile.tone or ""
        -- Only overwrite if not currently showing
        -- a live placeholder (poll in progress)
        local polling = (
            self.pendingToneGuid
            and self.pendingToneGuid == profile.guid
        )
        if not polling or toneText ~= "" then
            p.tone:SetText(toneText)
            p.tone:SetTextColor(0.7, 0.7, 0.7)
        end
    end
    if p.backstory and not keepStory then
        local bsText = profile.backstory or ""
        -- Only overwrite if not currently showing
        -- a live placeholder (poll in progress)
        local polling = (
            self.pendingBackstoryGuid
            and self.pendingBackstoryGuid == profile.guid
        )
        if not polling or bsText ~= "" then
            p.backstory:SetText(bsText)
            p.backstory:SetTextColor(0.7, 0.7, 0.7)
        end
    end
end

function Chatter:ApplyProfile(profile)
    if profile.guid ~= self.selectedGuid or self.forgetQueue then
        return
    end
    -- Everything the server sends while an upload is open
    -- still describes the pre-save bot, down to the tone that
    -- is about to be regenerated, so none of it is applied.
    if self.uploadState and self.uploadGuid == profile.guid then
        return
    end
    -- Once the upload is over but the edit was never accepted
    -- — rejected, timed out — a late reply may still refresh
    -- tone and backstory, but the trait boxes belong to the
    -- player until they save successfully or pick another bot.
    local keepTraits = (
        self.unsavedTraits ~= nil
        and self.unsavedTraits.guid == profile.guid
    )
    -- The same goes for an edit that has not been saved at
    -- all: a poll reply, or any other repeat of a profile that
    -- is already loaded, must not wipe what is being typed.
    -- Only a fresh selection (pendingProfileGuid) starts the
    -- boxes over.
    if not self.pendingProfileGuid and self:TraitsEdited() then
        keepTraits = true
    end
    -- Only a profile that was asked for by selecting the bot
    -- announces itself; a repeat must not talk over the
    -- message of whatever caused it ("Story saved", say).
    local fresh = (self.pendingProfileGuid ~= nil)
    self.pendingProfileGuid = nil
    self:SetRegenStoryEnabled(not self.pendingBackstoryGuid)
    local awaitingTone = (
        self.pendingToneGuid == profile.guid
    )
    self.selectedGuid = profile.guid

    -- Store loaded traits for change detection
    self.loadedTraits = {
        trait1 = profile.trait1 or "",
        trait2 = profile.trait2 or "",
        trait3 = profile.trait3 or "",
    }

    self:ApplyProfileToPanel(
        self.frame, profile, keepTraits, true
    )
    self:ApplyProfileToPanel(
        self.traitsPanel, profile, keepTraits, true
    )
    self:ApplyProfileToPanel(
        self.storiesPanel, profile, keepTraits, true
    )
    self:UpdateStoryControls()

    if keepTraits then
        -- The boxes still hold an edit the server never took,
        -- so Save has to stay available to retry it.
        self:UpdateSaveButton()
    else
        -- Traits just loaded — no unsaved changes yet
        self:SetSaveEnabled(false)
    end

    ChatterDB = ChatterDB or {}
    ChatterDB.selectedGuid = profile.guid

    self:UpdateRosterViews()
    if awaitingTone then
        if profile.tone and profile.tone ~= "" then
            self:StopTonePoll()
            self:SetStatus(
                "Generated tone for "
                    .. (profile.name or "bot"),
                0.3, 1, 0.3
            )
        else
            self:SetStatus(
                "Generating tone...", 1, 0.82, 0
            )
        end
    elseif fresh then
        self:SetStatus(
            "Loaded " .. (profile.name or "bot"),
            0.3, 1, 0.3
        )
    end
end

-- `keepStory` is for a selection the player did not make: the
-- roster coming back with the same bot still selected. A
-- story being typed for that bot stays.
function Chatter:SelectBot(guid, keepStory)
    if self.forgetQueue then return end
    guid = tonumber(guid)
    if not guid then
        return
    end

    if self.pendingToneGuid and self.pendingToneGuid ~= guid then
        self:StopTonePoll()
    end
    if self.pendingBackstoryGuid
        and self.pendingBackstoryGuid ~= guid then
        self:StopBackstoryPoll()
    end

    -- An edit belongs to the bot it was written for, so
    -- moving to a different one drops it rather than carrying
    -- it across, and leaves nothing half-staged behind.
    if self.unsavedTraits and self.unsavedTraits.guid ~= guid then
        self.unsavedTraits = nil
    end
    if self.uploadGuid and self.uploadGuid ~= guid then
        self:AbortUpload()
    end
    -- Picking a bot starts its story over from what the server
    -- holds, except for a story that is on its way up to that
    -- very bot right now.
    if self.storyEdit and self.storyEdit.guid ~= guid then
        self.storyEdit = nil
    elseif not keepStory
        and not (self.uploadState and self.uploadGuid == guid) then
        self.storyEdit = nil
    end

    self.selectedGuid = guid
    self.pendingProfileGuid = guid
    self.loadedTraits = nil
    self.loadedBackstory = nil
    self:SetSaveEnabled(false)
    self:SetRegenStoryEnabled(false)
    local empty = {trait1 = "", trait2 = "", trait3 = "",
        tone = "", backstory = ""}
    -- A story edit that survives the selection keeps its text
    -- in the boxes while the profile reloads.
    local keptStory = (self:GetStoryEdit() ~= nil)
    self:ApplyProfileToPanel(self.frame, empty, false, keptStory)
    self:ApplyProfileToPanel(
        self.traitsPanel, empty, false, keptStory
    )
    self:ApplyProfileToPanel(
        self.storiesPanel, empty, false, keptStory
    )
    self:UpdateStoryControls()
    self:UpdateRosterViews()
    self:SetStatus("Loading bot profile...", 1, 0.82, 0)
    self:SendCommand("get " .. guid)
end

function Chatter:RequestRoster()
    if self.forgetQueue or self.pendingRoster then return end
    self.pendingRoster = {}
    self.rosterElapsed = 0
    self:UpdateRosterViews()
    self:SetStatus("Requesting roster...", 1, 0.82, 0)
    self:SendCommand("roster")
end

function Chatter:SaveProfile()
    if self.pendingProfileGuid or self.forgetQueue
        or self.uploadState then
        return
    end
    if not self.selectedGuid then
        self:SetStatus("Select a bot first.", 1, 0.2, 0.2)
        return
    end

    local p = self:GetActivePanel()
    if not p then
        self:SetStatus("No panel open.", 1, 0.2, 0.2)
        return
    end

    local trait1 = sanitizeInput(p.trait1:GetText())
    local trait2 = sanitizeInput(p.trait2:GetText())
    local trait3 = sanitizeInput(p.trait3:GetText())

    p.trait1:SetText(trait1)
    p.trait2:SetText(trait2)
    p.trait3:SetText(trait3)

    if trait1 == "" or trait2 == "" or trait3 == "" then
        self:SetStatus("All three traits are required.", 1, 0.2, 0.2)
        return
    end

    if utf8len(trait1) > 64 or utf8len(trait2) > 64
        or utf8len(trait3) > 64 then
        self:SetStatus("Traits must stay under 64 characters.", 1, 0.2, 0.2)
        return
    end

    -- Store pending traits for use after confirm
    self.pendingTraits = {
        guid = self.selectedGuid,
        trait1 = trait1,
        trait2 = trait2,
        trait3 = trait3,
    }

    local loaded = self.loadedTraits or {}
    local changed = (
        trait1 ~= (loaded.trait1 or "")
        or trait2 ~= (loaded.trait2 or "")
        or trait3 ~= (loaded.trait3 or "")
    )

    if changed then
        StaticPopup_Show(
            "CHATTER_CONFIRM_SAVE_TRAITS"
        )
    else
        -- Nothing changed — no server round-trip
        self:SetStatus(
            "Traits unchanged.", 0.3, 1, 0.3
        )
    end
end

-- Uploads the traits one `put` per chunk, then commits.
-- Returns false if a trait somehow refuses to split.
function Chatter:QueueChunkedSave(guid, t)
    local fields = {
        { "t1", t.trait1 },
        { "t2", t.trait2 },
        { "t3", t.trait3 },
    }

    local queued = {}
    for _, field in ipairs(fields) do
        local chunks = self:SplitEncoded(
            self:Encode(field[2]), CHUNK_BUDGET
        )
        if not chunks then
            return false
        end
        for i = 1, #chunks do
            table.insert(queued, string.format(
                "put %d %s %d %d %s",
                guid, field[1], i, #chunks, chunks[i]
            ))
        end
    end

    for _, command in ipairs(queued) do
        self:QueueCommand(command)
    end
    self:QueueCommand(string.format("commit %d", guid))
    self.uploadGuid = guid
    self.uploadState = "sending"
    return true
end

function Chatter:DoSaveProfile()
    local t = self.pendingTraits
    if not t or t.guid ~= self.selectedGuid
        or self.pendingProfileGuid or self.forgetQueue
        or self.uploadState then
        return
    end

    local guid = self.selectedGuid
    self:StopTonePoll()
    self:StopBackstoryPoll()
    self:FlushSendQueue()
    -- Changed traits queue a story generation. Held from the
    -- moment of sending: the commit can land even if its
    -- confirmation never reaches the addon.
    self:HoldStorySave(guid)

    local line = string.format(
        "set %d %s %s %s",
        guid,
        self:Encode(t.trait1),
        self:Encode(t.trait2),
        self:Encode(t.trait3)
    )

    -- Remember what the player typed before anything can
    -- overwrite the boxes: until the server confirms the save
    -- this is the only copy of the edit that exists.
    self.unsavedTraits = {
        guid = guid,
        trait1 = t.trait1,
        trait2 = t.trait2,
        trait3 = t.trait3,
    }
    self.pendingTraits = nil

    if string.len(".llmc " .. line) <= MAX_CHAT_LENGTH then
        self.uploadGuid = guid
        self.uploadState = "sending"
        self.uploadKind = "traits"
        self:SendCommand(line)
        self:LockSave()
        -- A single line is already gone, so the wait for the
        -- answer starts immediately.
        self:BeginConfirmWait()
    elseif self:QueueChunkedSave(guid, t) then
        self.uploadKind = "traits"
        self:LockSave()
    else
        self.unsavedTraits = nil
        self:SetStatus(
            "Could not send these traits.", 1, 0.2, 0.2
        )
        return
    end

    -- Start polls immediately so placeholders appear
    -- without waiting for the server round-trip
    self:StartTonePoll(guid)
    self:StartBackstoryPoll(guid)
    self:SetStatus(
        "Saving traits and regenerating tone"
            .. " and backstory...",
        1, 0.82, 0
    )
end

function Chatter:GetSelectedName()
    if not self.selectedGuid then
        return nil
    end
    local guid = tonumber(self.selectedGuid)
    if not guid then return nil end
    for _, entry in ipairs(self.roster or {}) do
        if entry.guid == guid then
            return entry.name
        end
    end
    return nil
end

-- Validates the typed story and sends it. Nothing else is
-- regenerated by a story save, so it asks no confirmation.
function Chatter:SaveStory()
    if self.pendingProfileGuid or self.forgetQueue
        or self.uploadState then
        return
    end
    if not self.selectedGuid or not self.loadedTraits then
        self:SetStatus("Select a bot first.", 1, 0.2, 0.2)
        return
    end
    if self.pendingBackstoryGuid
        or self.storyHolds[self.selectedGuid] then
        self:SetStatus(
            "The server may still be writing a story for this"
                .. " bot. Save yours in a moment.",
            1, 0.82, 0
        )
        return
    end

    local edit = self:GetStoryEdit()
    local text = sanitizeInput(edit and edit.text or "")
    if not edit or text == (self.loadedBackstory or "") then
        self.storyEdit = nil
        self:UpdateStoryControls()
        self:SetStatus("Story unchanged.", 0.3, 1, 0.3)
        return
    end
    if text == "" then
        self:SetStatus(
            "The story cannot be empty. Use Regenerate Story"
                .. " for a new one.",
            1, 0.2, 0.2
        )
        return
    end
    if utf8len(text) > MAX_STORY_CHARS then
        self:SetStatus(
            "The story must stay within " .. MAX_STORY_CHARS
                .. " characters (now " .. utf8len(text) .. ").",
            1, 0.2, 0.2
        )
        return
    end

    local guid = self.selectedGuid
    local encoded = self:Encode(text)
    local line = string.format("setbackstory %d %s", guid, encoded)

    self:FlushSendQueue()
    if string.len(".llmc " .. line) <= MAX_CHAT_LENGTH then
        self.uploadGuid = guid
        self.uploadState = "sending"
        self.uploadKind = "story"
        self.uploadStory = text
        self:SendCommand(line)
        self:LockSave()
        self:BeginConfirmWait()
    else
        local chunks = self:SplitEncoded(encoded, CHUNK_BUDGET)
        if not chunks or #chunks > MAX_CHUNKS then
            self:SetStatus(
                "Could not send this story.", 1, 0.2, 0.2
            )
            return
        end
        for i = 1, #chunks do
            self:QueueCommand(string.format(
                "put %d bs %d %d %s", guid, i, #chunks, chunks[i]
            ))
        end
        self:QueueCommand(string.format("commit %d", guid))
        self.uploadGuid = guid
        self.uploadState = "sending"
        self.uploadKind = "story"
        self.uploadStory = text
        self:LockSave()
    end
    self:SetStatus("Saving story...", 1, 0.82, 0)
end

function Chatter:RegenBackstory()
    if self.pendingProfileGuid or self.forgetQueue
        or self.uploadState then
        return
    end
    if not self.selectedGuid then
        self:SetStatus("Select a bot first.", 1, 0.2, 0.2)
        return
    end

    -- A new story replaces the one being edited, so that is
    -- the player's call to make.
    if self:GetStoryEdit() then
        -- The dialog owns the bot it asked about: picking
        -- another bot while it is open cannot retarget it.
        local popup = StaticPopup_Show(
            "CHATTER_CONFIRM_REGEN_STORY"
        )
        if popup then popup.data = self.selectedGuid end
        return
    end
    self:DoRegenBackstory(self.selectedGuid)
end

function Chatter:DoRegenBackstory(guid)
    guid = tonumber(guid)
    if not guid or guid ~= self.selectedGuid
        or self.pendingProfileGuid or self.forgetQueue
        or self.uploadState then
        return
    end

    self.storyEdit = nil
    self:StopBackstoryPoll()
    self:HoldStorySave(guid)
    self:SendCommand("regenbackstory " .. guid)
    self:StartBackstoryPoll(guid)
    self:SetStatus(
        "Regenerating backstory...", 1, 0.82, 0
    )
end

function Chatter:Toggle()
    self:BuildFrame()

    if self.frame:IsShown() then
        self.frame:Hide()
        return
    end

    self.frame:Show()
    self.frame:Raise()
    self:RequestRoster()
end

function Chatter:HandleRosterEntry(guidToken, nameToken)
    local guid = tonumber(guidToken)
    local name = self:Decode(nameToken)
    if not guid or name == "" then
        return
    end

    table.insert(self.pendingRoster, {
        guid = guid,
        name = name
    })
end

function Chatter:FinishRoster()
    self.roster = self.pendingRoster or {}
    self.pendingRoster = nil

    table.sort(self.roster, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)

    self:UpdateRosterViews()

    if #self.roster == 0 then
        self.selectedGuid = nil
        self.pendingProfileGuid = nil
        self.loadedTraits = nil
        self.loadedBackstory = nil
        self.storyEdit = nil
        ChatterDB.selectedGuid = nil
        self:StopTonePoll()
        self:StopBackstoryPoll()
        self:SetSaveEnabled(false)
        self:SetRegenStoryEnabled(false)
        self:UpdateRosterViews()
        local empty = {
            trait1 = "", trait2 = "", trait3 = "",
            tone = "", backstory = "",
        }
        self:ApplyProfileToPanel(self.frame, empty)
        self:ApplyProfileToPanel(self.traitsPanel, empty)
        self:ApplyProfileToPanel(self.storiesPanel, empty)
        self:SetStatus("No known bots yet.", 1, 0.82, 0)
        return
    end

    local preferredGuid = self.selectedGuid
    if not preferredGuid and ChatterDB then
        preferredGuid = ChatterDB.selectedGuid
    end

    local found = nil
    for _, bot in ipairs(self.roster) do
        if bot.guid == preferredGuid then
            found = bot.guid
            break
        end
    end

    if not found then
        found = self.roster[1].guid
    end

    -- The roster returning with the same bot is not the player
    -- choosing it again.
    self:SelectBot(found, found == self.selectedGuid)
end

function Chatter:HandleProfilePayload(rest)
    -- Parse 6 fields: guid name t1 t2 t3 tone
    -- Backstory arrives as a separate BACKSTORY message
    local guid, name, trait1, trait2, trait3, tone =
        string.match(
            rest,
            "^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)"
            .. "%s+(%S+)%s+(%S+)$"
        )
    if not guid then
        return
    end

    self:ApplyProfile({
        guid = tonumber(guid),
        name = self:Decode(name),
        trait1 = self:Decode(trait1),
        trait2 = self:Decode(trait2),
        trait3 = self:Decode(trait3),
        tone = self:Decode(tone),
    })
end

function Chatter:HandleBackstoryPayload(rest)
    local guid, encoded = string.match(
        rest, "^(%d+)%s+(.+)$"
    )
    if not guid then
        return
    end

    local numGuid = tonumber(guid)
    local text = self:Decode(encoded or "-")

    if self.uploadState and self.uploadGuid == numGuid then
        if self.uploadKind ~= "story"
            or text ~= self.uploadStory then
            -- Stale while an upload is still open: the story
            -- a trait save is about to regenerate, or the
            -- text of an earlier story save, not this one.
            return
        end
        -- The server holds exactly the story that was sent.
        -- Only now is the upload over.
        self:FlushSendQueue()
        self.uploadGuid = nil
        self.uploadState = nil
        self.uploadKind = nil
        self.uploadStory = nil
        if self.storyEdit and self.storyEdit.guid == numGuid then
            self.storyEdit = nil
        end
        self:UnlockSave()
        if self.selectedGuid == numGuid then
            self.loadedBackstory = text
            self:ShowStory(text)
            self:SetStatus(
                "Story saved for "
                    .. (self:GetSelectedName() or "bot") .. ".",
                0.3, 1, 0.3
            )
        end
        self:UpdateStoryControls()
        return
    end

    local polling = (self.pendingBackstoryGuid == numGuid)

    -- Still the story that is being replaced: a reply to a
    -- request made before the generation was asked for.
    if polling and text ~= "" and text == self.replacedStory then
        return
    end

    -- A story other than the one that was being replaced means
    -- the generation has run, whenever it is seen, so nothing
    -- is left that could clear a saved story.
    local hold = self.storyHolds[numGuid]
    if hold and text ~= "" and text ~= hold.replaced then
        self.storyHolds[numGuid] = nil
    end

    if self.selectedGuid == numGuid then
        self.loadedBackstory = text
        -- An edit the server now holds word for word is not
        -- an edit any more (a save confirmed late, say).
        local edit = self:GetStoryEdit()
        if edit and sanitizeInput(edit.text) == text then
            self.storyEdit = nil
            edit = nil
        end
        -- The boxes follow the server unless the player is
        -- editing. An empty story during generation leaves the
        -- "Creating background story..." placeholder up.
        if not edit and (text ~= "" or not polling) then
            self:ShowStory(text)
        end
    end

    -- If we were polling for backstory, check
    -- if it arrived
    if self.pendingBackstoryGuid == numGuid then
        if text and text ~= "" then
            self:StopBackstoryPoll()
            -- Only show backstory status if tone
            -- poll is already done
            if not self.pendingToneGuid then
                self:SetStatus(
                    "Backstory generated.",
                    0.3, 1, 0.3
                )
            end
        end
    end
    self:UpdateStoryControls()
end

function Chatter:HandleSystemMessage(message)
    if not string.find(message, "^" .. self.prefix) then
        return
    end

    local payload = string.sub(message, string.len(self.prefix) + 1)
    local command, rest = string.match(payload, "^(%S+)%s*(.-)$")

    if command == "ROSTER_BEGIN" then
        self.pendingRoster = {}
        return
    end

    if command == "ROSTER" then
        local guid, name = string.match(rest, "^(%d+)%s+(%S+)$")
        if guid and name and self.pendingRoster then
            self:HandleRosterEntry(guid, name)
        end
        return
    end

    if command == "ROSTER_END" then
        self:FinishRoster()
        return
    end

    if command == "PROFILE" then
        self:HandleProfilePayload(rest)
        return
    end

    if command == "BACKSTORY" then
        self:HandleBackstoryPayload(rest)
        return
    end

    if command == "UPDATED" then
        local guid, name, flag, extra = string.match(
            rest, "^(%d+)%s+(%S+)%s+(%S+)%s*(%S*)"
        )
        -- "nostory": stories are switched off on the server, so
        -- the changed traits regenerate the tone only.
        local noStory = (extra == "nostory")
        if guid and name and tonumber(guid) == self.selectedGuid
            and not self.forgetQueue then
            if self.uploadState and self.uploadKind == "story" then
                -- A trait save that was given up on has been
                -- applied after all. The story upload now in
                -- flight is not its business; only the story
                -- generation those traits queued is noted.
                if flag == "changed" and not noStory then
                    self:HoldStorySave(guid)
                end
                return
            end
            self.selectedGuid = tonumber(guid)
            -- The server applied the edit. Only now is the
            -- upload over and the typed text the saved text.
            self:FlushSendQueue()
            self.uploadGuid = nil
            self.uploadState = nil
            self.uploadKind = nil
            self.unsavedTraits = nil
            self:UnlockSave()
            local changed = (flag == "changed")
            if changed and noStory then
                -- No story is coming. The new traits cleared
                -- the old one, so the box shows what the
                -- server holds: nothing, unless the player is
                -- writing one, which can be saved right away.
                self:StartTonePoll(guid)
                self:StopBackstoryPoll()
                self.storyHolds[tonumber(guid)] = nil
                self.loadedBackstory = ""
                if not self:GetStoryEdit() then
                    self:ShowStory("")
                end
                self:UpdateStoryControls()
                self:SetStatus(
                    "Saved. Regenerating tone...", 1, 0.82, 0
                )
            elseif changed then
                -- Polls were started in DoSaveProfile;
                -- restart here to reset the 120s clock
                -- now that the server confirmed the save
                self:HoldStorySave(guid)
                self:StartTonePoll(guid)
                self:StartBackstoryPoll(guid)
                self:SetStatus(
                    "Saved. Regenerating tone"
                        .. " and backstory...",
                    1, 0.82, 0
                )
            else
                self:StopTonePoll()
                self:StopBackstoryPoll()
                self:SetStatus(
                    "Traits saved for "
                        .. self:Decode(name) .. ".",
                    0.3, 1, 0.3
                )
                -- Reload profile to restore
                -- tone/backstory after optimistic polls
                self:SendCommand(
                    "get " .. tonumber(guid)
                )
            end
        end
        return
    end

    if command == "BACKSTORY_SAVED" then
        -- Says that a story was stored, not which one: it
        -- names no text, so it cannot tell the save in flight
        -- from an earlier one that was given up on and landed
        -- late. The BACKSTORY line that follows carries the
        -- stored text, and that is what settles a save.
        return
    end

    if command == "BACKSTORY_REGEN" then
        local guid, name = string.match(
            rest, "^(%d+)%s+(%S+)$"
        )
        if guid and name then
            self:SetStatus(
                "Regenerating backstory for "
                    .. self:Decode(name) .. "...",
                1, 0.82, 0
            )
        end
        return
    end

    if command == "FORGOTTEN" then
        self:HandleForgotten(tonumber(string.match(rest, "^(%d+)%s")))
        return
    end

    if command == "ERROR" then
        if self.forgetQueue then
            self:FinishForgetBatch("Stopped: " .. self:Decode(
                string.match(rest, "^%S+%s*(.-)$") or rest))
            return
        end
        self.pendingRoster = nil
        local category, encoded = string.match(
            rest, "^(%S+)%s*(.-)$"
        )
        local text = self:Decode(encoded)
        if self.uploadState then
            -- The rejection belongs to the save in flight, so
            -- the whole save ends here — queue, polls and all
            -- — with the player's traits handed back.
            self:AbortUpload(text, 1, 0.2, 0.2)
        else
            -- Whatever was being loaded or awaited will not
            -- arrive: a poll left running would repeat the
            -- same refused request for two minutes, and a
            -- profile load left pending would never finish.
            local awaitedStory = self.pendingBackstoryGuid
            self:StopTonePoll()
            self:StopBackstoryPoll()
            self.pendingProfileGuid = nil
            if awaitedStory then
                -- "disabled" means the server queued nothing,
                -- so there is no generation left that a saved
                -- story would have to wait for.
                if category == "disabled" then
                    self.storyHolds[awaitedStory] = nil
                end
                -- The story that was being waited for is not
                -- coming; put back the one on record instead
                -- of leaving the placeholder up.
                if awaitedStory == self.selectedGuid
                    and not self:GetStoryEdit() then
                    self:ShowStory(self.loadedBackstory or "")
                end
            end
            self:SetRegenStoryEnabled(self.loadedTraits ~= nil)
            self:UnlockSave()
            self:SetStatus(text, 1, 0.2, 0.2)
        end
    end
end

local function chatterSystemFilter(_, _, message, ...)
    if type(message) == "string"
        and string.find(message, "^" .. Chatter.prefix) then
        return true
    end
    return false
end

StaticPopupDialogs["CHATTER_CONFIRM_SAVE_TRAITS"] = {
    text = "These traits are different from the saved ones. Saving will regenerate this bot's tone and background story. Continue?",
    button1 = "Save",
    button2 = "Cancel",
    OnAccept = function()
        Chatter:DoSaveProfile()
    end,
    timeout = 0,
    whileDead = false,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["CHATTER_CONFIRM_REGEN_STORY"] = {
    text = "You have an unsaved story for this bot. Regenerating will replace it with a newly written one. Continue?",
    button1 = "Regenerate",
    button2 = "Cancel",
    OnAccept = function(self)
        Chatter:DoRegenBackstory(self.data)
    end,
    timeout = 0,
    whileDead = false,
    hideOnEscape = true,
    preferredIndex = 3,
}

SLASH_CHATTER1 = "/chatter"
SLASH_CHATTER2 = "/llmc"
SlashCmdList["CHATTER"] = function()
    Chatter:Toggle()
end

Chatter:SetScript("OnUpdate", function(self, elapsed)
    self:HandleSendQueue(elapsed)
    self:HandleSaveLock(elapsed)
    if self.pendingRoster then
        self.rosterElapsed = (self.rosterElapsed or 0) + elapsed
        if self.rosterElapsed >= 10 then
            self.pendingRoster = nil
            self:UpdateRosterViews()
            self:SetStatus("Roster request timed out. Use Refresh.", 1, 0.4, 0.3)
        end
    end
    self:HandleForgetQueue(elapsed)
    self:HandlePolls(elapsed)
    self:HandleStoryHolds(elapsed)
end)

Chatter:SetScript("OnEvent", function(self, event, message)
    if event == "PLAYER_LOGIN" then
        ChatterDB = ChatterDB or {}
        self:BuildOptionsPanel()
        self:BuildFrame()
        ChatFrame_AddMessageEventFilter(
            "CHAT_MSG_SYSTEM",
            chatterSystemFilter
        )
    elseif event == "PLAYER_LOGOUT" then
        self:SaveWindowPosition()
    elseif event == "CHAT_MSG_SYSTEM" then
        -- Filters run once per chat window; process each response only once.
        self:HandleSystemMessage(message)
    end
end)

Chatter:RegisterEvent("PLAYER_LOGIN")
Chatter:RegisterEvent("PLAYER_LOGOUT")
Chatter:RegisterEvent("CHAT_MSG_SYSTEM")
