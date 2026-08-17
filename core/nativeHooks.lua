--[[
	nativeHooks.lua
		Everything that reaches into ProjectEbonhold's own vault module:
		chaining onto the global callbacks it owns (so we see the same
		packets and the same open/close it does), and suppressing the two
		frames it draws its content into.
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')
local ExtBank = Bagnon.ExtBank


--[[ Safe hook of the ProjectEbonhold-owned global callbacks ]]--
-- ExtBank_OnPacket / ExtBank_Open / ExtBank_Close are bare globals,
-- unconditionally assigned by modules/extBank/extBank.lua with no
-- existence check -- only one function can ever own each name. Never
-- assign at file-load time: addon load order between "Bagnon" and
-- "ProjectEbonhold" is not guaranteed. Wait for PLAYER_LOGIN (by then
-- every addon's top-level chunk has already run -- addon loading always
-- finishes before PLAYER_LOGIN fires) and chain through whatever is
-- already installed. main.lua's OnEnable is what arranges that.
--
-- ExtBank_Open/ExtBank_Close are what the addon's own "Void Storage"
-- toggle button (pinned to the bank window) and its /extbank slash
-- command both call -- and what extBank.lua itself calls internally on
-- BANKFRAME_CLOSED, so leaving the bank is covered too. That button
-- widget is unreachable from outside (created via CreateFrame("Button",
-- nil, parent), so it's never given a global name -- the only reference
-- to it is a `local` upvalue inside extBank.lua's own chunk, same as its
-- bags/cells/unlockedBags model). Hooking ExtBank_Open/Close instead
-- catches every way the player can trigger it, with no button of our own
-- and no reference to theirs needed.

local hooked = false

function ExtBank:HookNativeGlobals()
	if hooked then return end

	if type(_G.ExtBankOpen) ~= 'function' then
		-- ebonhold.dll natives aren't present -- not the Ebonhold client,
		-- or ProjectEbonhold hasn't loaded. Nothing to hook yet, and "yet" is
		-- load-bearing: main.lua registers this for PLAYER_ENTERING_WORLD as well as
		-- PLAYER_LOGIN, so a DLL that arms late gets picked up on the next loading
		-- screen. Left on PLAYER_LOGIN alone this return was terminal -- the event
		-- fires once, nothing re-armed, and the addon spent the session inert with
		-- nothing on screen to say why.
		return
	end

	local previousOnPacket = _G.ExtBank_OnPacket
	_G.ExtBank_OnPacket = function(hex)
		if type(previousOnPacket) == 'function' then
			previousOnPacket(hex)
		end
		ExtBank:ParsePacket(hex)
	end

	local previousOpen = _G.ExtBank_Open
	_G.ExtBank_Open = function(...)
		if type(previousOpen) == 'function' then
			previousOpen(...)
		end
		ExtBank:OnNativeOpen()
	end

	local previousClose = _G.ExtBank_Close
	_G.ExtBank_Close = function(...)
		-- Set for the duration of this call so components/frame.lua's own
		-- OnHide sync (see its "Native close sync" section) can tell "we're
		-- hiding because the native side just closed" apart from "we're hiding
		-- for some other reason (X button, Escape, ...) and need to *tell* the
		-- native side about it" -- without this flag, a native-triggered
		-- close would loop back into calling ExtBank_Close() a second,
		-- redundant (if harmless) time.
		-- The flag has to stay true across BOTH calls below -- OnNativeClose
		-- hides our frame, which runs components/frame.lua's OnHide, and that
		-- is the reader it exists for. Clearing it any earlier would have OnHide
		-- call _G.ExtBank_Close() straight back into this same wrapper.
		--
		-- So the calls are pcall'd instead. previousClose is ProjectEbonhold's
		-- code, not ours, and OnNativeClose reaches the whole teardown funnel;
		-- a plain set/clear pair around them strands the flag true for the rest
		-- of the session the first time anything in there throws. From that
		-- point OnHide takes the `not closingFromNative` branch as false forever
		-- and stops telling extBank.lua's isOpen upvalue anything on an X-button
		-- or Escape close -- silently reinstating the exact "click Void Storage
		-- twice to reopen it" bug this flag exists to prevent, with no visible
		-- cause and no way back short of /reload.
		--
		-- Errors are handed to geterrorhandler() rather than swallowed: the
		-- point is to guarantee the flag is cleared, not to hide breakage. That
		-- is also how the client itself reports an error out of a script
		-- handler, so this reads no differently to the player or to BugSack.
		-- Saved and restored, not set-then-cleared. The flag encodes a stack fact
		-- ("we are somewhere inside a native close"), and a bare false on the way out
		-- is only correct at depth one: anything reachable from previousClose that
		-- synchronously calls _G.ExtBank_Close again would clear it while the OUTER
		-- call is still running, so that call's own OnNativeClose -> FrameSettings:Hide
		-- -> Frame:OnHide would read it false and call _G.ExtBank_Close a third time,
		-- re-entering the funnel this flag exists to break. No such nesting is
		-- reachable in the current ProjectEbonhold build -- its ExtBank_Close body
		-- traces clean -- so this is a latent case, and two lines is a cheap way to
		-- stop it depending on somebody else's file staying that way.
		local wasClosingFromNative = ExtBank.closingFromNative
		ExtBank.closingFromNative = true

		local previousOk, previousErr
		if type(previousClose) == 'function' then
			previousOk, previousErr = pcall(previousClose, ...)
		else
			previousOk = true
		end

		local ourOk, ourErr = pcall(ExtBank.OnNativeClose, ExtBank)

		-- Restored BEFORE anything is reported. geterrorhandler() returns whatever
		-- error addon is installed (BugSack, Swatter, _ERRORMESSAGE), which is not our
		-- code and can itself throw -- and a throw here used to escape the wrapper
		-- with the flag still true, which is the one outcome the pcalls above were
		-- added to prevent. From that point Frame:OnHide stops telling extBank.lua's
		-- isOpen upvalue anything on an X or Escape close, silently reinstating the
		-- "click Void Storage twice to reopen it" bug with no visible cause.
		ExtBank.closingFromNative = wasClosingFromNative

		if not previousOk then geterrorhandler()(previousErr) end
		if not ourOk then geterrorhandler()(ourErr) end
	end

	hooked = true

	-- Nothing left to retry for -- drop both registrations so a zone change stops
	-- calling back in here for the rest of the session.
	ExtBank:UnregisterEvent('PLAYER_LOGIN')
	ExtBank:UnregisterEvent('PLAYER_ENTERING_WORLD')
end


--[[ Suppress the native window ]]--
-- Ours is meant to fully replace the native content window, not sit next to
-- it -- the player should only ever see one. Everything else about the
-- native module stays untouched: the "Void Storage" toggle button pinned to
-- the bank window, its opcodes/model, and its personal-bank-panel swap all
-- keep working exactly as before (all of that lives in extBank.lua's own
-- ExtBank_Open, not in these two frames) -- only the two frames it actually
-- draws its content into are hidden:
--   ExtBankFrame     -- the main content window
--   ExtBankBagFrame  -- its bag-slot side panel
-- Both are plain globals (named via CreateFrame's second argument) but don't
-- exist until the native module's own BuildUI() runs, which only happens
-- lazily on its first-ever ExtBank_Open() call -- so this can't be set up
-- until at least one open has already happened. The _G.ExtBank_Open wrapper
-- above already guarantees previousOpen() (the real ExtBank_Open, which calls
-- BuildUI()) runs before ExtBank:OnNativeOpen(), so by the time main.lua's
-- OnNativeOpen calls this the globals are guaranteed to exist.
--
-- hooksecurefunc'ing Show straight to Hide, rather than a one-off Hide()
-- call here, is what makes this stick for every later open too: the native
-- module calls frame:Show()/sideFrame:Show() itself on every single open
-- (and sideFrame:Show() again on its own from inside ExtBank_Redraw), and a
-- one-off Hide() here would only catch the open that installed it.

local nativeWindowHooked = false

function ExtBank:HideNativeWindow()
	if nativeWindowHooked then return end

	local native = _G.ExtBankFrame
	local nativeSide = _G.ExtBankBagFrame
	if not native then return end -- BuildUI() somehow hasn't run yet -- try again next open

	hooksecurefunc(native, 'Show', native.Hide)
	native:Hide() -- catch the Show() that just already happened, above the hook

	if nativeSide then
		hooksecurefunc(nativeSide, 'Show', nativeSide.Hide)
		nativeSide:Hide()
	end

	-- Set unconditionally, and deliberately NOT moved inside `if nativeSide`:
	-- BuildUI creates both native frames or neither, and re-entering would
	-- stack a second hook on the main frame. See docs/non-issues.md §3.
	nativeWindowHooked = true
end
