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
--   action   Action of the sprite used by "SPR" (default 0)
--            "COLOR" multiplies the color of the character (not of the effects)
--   r, g, b  Color used by "COLOR" (0 - 255, default 255)
--   alpha    Opacity used by "COLOR" (0 - 255, default 255)
--
-- The position defined in hateffectinfo (hatEffectPos, hatEffectPosX) is applied as well.
--
-- The sprite entries below are taken from the client's sprite effect code (2025-07-16 Ragexe):
-- the client places them 4, 6, 8 or 12 height units above the feet (7 pixels per unit) and
-- chooses the action per effect id for the subject auras. Their depth bias puts them behind the
-- character.

ZrEffectTable = {
	[120] = { -- EF_CLOAKING: the client sets the alpha of the actor to 50
		{ type = "COLOR", alpha = 50 }
	},
	[197] = { -- EF_SLEEPATTACK
		{ type = "STR", file = "sleep.str" }
	},
	[302] = { -- EF_DEMONSTRATION
		{ type = "SPR", file = "데몬스트레이션" }
	},
	[396] = { -- EF_PINKBODY: the client sets the color of the actor
		{ type = "COLOR", r = 255, g = 89, b = 182 }
	},
	[421] = { -- EF_BABYBODY2
		{ type = "SCALE", scale = 0.5 }
	},
	[423] = { -- EF_GIANTBODY2
		{ type = "SCALE", scale = 1.5 }
	},
	[1004] = { -- EF_KAGEMUSYA: color and alpha of the actor (the client also draws shadow clones)
		{ type = "COLOR", r = 192, g = 192, b = 192, alpha = 100 }
	},
	[1048] = { -- EF_WL_TELEKINESIS_INTENSE
		{ type = "STR", file = "wl_telekinesis_intense.str" }
	},
	[1057] = { -- EF_AB_OFFERTORIUM_RING
		{ type = "STR", file = "ab_offertorium_ring.str" }
	},
	[1065] = { -- EF_WHITEBODY: the client sets the color of the actor to white, which is unchanged
		{ type = "COLOR" }
	},
	[1130] = { -- EF_BAKURETSU_HADOU
		{ type = "SPR", file = "bakuretsu_hadou/bakuretsu_hadou", yOffset = -56, behind = true }
	},
	[1211] = { -- Subject aura (gold)
		{ type = "SPR", file = "subject_aura/subject_aura", yOffset = -56, action = 2, behind = true }
	},
	[1212] = { -- Subject aura (white)
		{ type = "SPR", file = "subject_aura/subject_aura", yOffset = -56, action = 0, behind = true }
	},
	[1213] = { -- Subject aura (red)
		{ type = "SPR", file = "subject_aura/subject_aura", yOffset = -56, action = 1, behind = true }
	},
	[1240] = { -- EF_DIGITAL_SPACE
		{ type = "SPR", file = "digital_space/digital_space", behind = true }
	},
	[1377] = { -- Valkyrie wing
		{ type = "SPR", file = "valkyrie_wing/valkyrie_wing", yOffset = -42, behind = true }
	},
	[2346] = { -- Black thunder
		{ type = "SPR", file = "Black_Thunder/Black_Thunder", yOffset = -28 }
	},
	[2347] = { -- Black thunder (dark)
		{ type = "SPR", file = "Black_Thunder/Black_Thunder_Dark", yOffset = -28 }
	},
	[2394] = { -- Serpent shadow
		{ type = "SPR", file = "Serpent_Shadow/Serpent_Shadow", yOffset = -28, behind = true }
	},
	[2424] = { -- Aura of ghost
		{ type = "SPR", file = "C_Aura_Of_Ghost_S/C_Aura_Of_Ghost_S", yOffset = -28, behind = true }
	},
	[2428] = { -- Atque poenitentia
		{ type = "SPR", file = "Atque_Poenitentia/Atque_Poenitentia", yOffset = -28, behind = true }
	},
	[2429] = { -- Perm frost oblivion
		{ type = "SPR", file = "Perm_Frost_Oblivion/Perm_Frost_Oblivion", yOffset = -28, behind = true }
	},
	[2430] = { -- Guide of dead text
		{ type = "SPR", file = "C_Guide_Of_Dead_Text/C_Guide_Of_Dead_Text", yOffset = -84, behind = true }
	},
	[2431] = { -- Medjed text
		{ type = "SPR", file = "C_Medjed_Text/C_Medjed_Text", yOffset = -84, behind = true }
	},
}
