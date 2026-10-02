-- Effect table for hat effects.
--
-- Most hat effects (data/luafiles514/lua files/hateffectinfo/hateffectinfo.lub) reference a
-- str file directly through "resourceFileName" and do not need an entry here.
-- The remaining ones only reference an effect id ("hatEffectID") of the client's internal
-- effect table. That table is compiled into the client executable, so the effects have to be
-- mapped to renderable resources here.
--
-- Run "dub run :hateffecttool -- --resourcepath=<path>" to list hat effects without an entry
-- together with candidate files found in your resources.
--
-- Format:
--   ZrEffectTable[<effect id>] = { <entry>, <entry>, ... }
--
-- Entry fields:
--   type     "STR"   str file relative to data/texture/effect (e.g. "sleep.str")
--            "SPR"   sprite relative to data/sprite/이팩트 without extension (spr + act)
--            "SCALE" scales the whole character by "scale"
--   file     File name (UTF-8, use "/" as separator)
--   behind   true to draw the effect behind the character
--   head     true to move the effect up by 100 pixels (head height)
--   xOffset  Horizontal offset in pixels
--   yOffset  Vertical offset in pixels (negative values move up)
--   scale    Scale factor used by "SCALE"
--
-- The position defined in hateffectinfo (hatEffectPos, hatEffectPosX) is applied as well.

ZrEffectTable = {
	[197] = { -- EF_SLEEPATTACK
		{ type = "STR", file = "sleep.str" }
	},
	[302] = { -- EF_DEMONSTRATION
		{ type = "SPR", file = "데몬스트레이션" }
	},
	[421] = { -- EF_BABYBODY2
		{ type = "SCALE", scale = 0.5 }
	},
	[423] = { -- EF_GIANTBODY2
		{ type = "SCALE", scale = 1.5 }
	},
	[1048] = { -- EF_WL_TELEKINESIS_INTENSE
		{ type = "STR", file = "wl_telekinesis_intense.str" }
	},
	[1057] = { -- EF_AB_OFFERTORIUM_RING
		{ type = "STR", file = "ab_offertorium_ring.str" }
	},
	[1130] = { -- EF_BAKURETSU_HADOU
		{ type = "SPR", file = "bakuretsu_hadou/bakuretsu_hadou", yOffset = -50 }
	},
	[1240] = { -- EF_DIGITAL_SPACE
		{ type = "SPR", file = "digital_space/digital_space", behind = true }
	},
}
