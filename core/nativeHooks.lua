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
		-- or ProjectEbonhold hasn't loaded. Nothing to hook (yet).
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
		ExtBank.closingFromNative = true
		if type(previousClose) == 'function' then
			previousClose(...)
		end
		ExtBank:OnNativeClose()
		ExtBank.closingFromNative = false
	end

	hooked = true
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
