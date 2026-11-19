-- lib/params.lua — THE parameter table. One list, every consumer.
--
-- Every parameter's name, range, default and unit lives here and nowhere else.
-- dirac.lua builds the params menu from it, Engine_Dirac.sc is checked against
-- it (tools/check-params.sh), and the paged UI will index into it.
--
-- The ranges and defaults are the ER-301 unit's OWN, copied from
-- dirac/assets/Dirac.lua rather than invented. Writing them from memory got
-- Speed, Heads, Grains, Tilt, Level, Rate, Spread, Texture and GrainLen all
-- wrong on the first pass.
--
-- Fields:
--   id        engine command name; must match Engine_Dirac.sc's addCommand
--   name      what the params menu shows
--   kind      "control" (default) | "option" | "toggle" | "trigger"
--
-- control:
--   min/max   the ER-301 dial's bias range
--   default   the ER-301 dial's initial bias
--   unit      display suffix, or nil
--   step      1 for the integer-stepping dials; the DSP rounds them anyway
--   warp      controlspec warp; 'lin' unless noted
--   detents   encoder detents across the whole range (default 200; dirac.lua
--             turns this into norns' `quantum`, which is a FRACTION of the
--             range). Holding K1 makes every detent ten times finer.
--
--             Why 200: norns' default quantum is 0.01, i.e. 100 detents, so
--             grain length (0.001–1 s) moved in 10 ms jumps and the 10–100 ms
--             sweet spot had nine settings. The ER-301 dials these ranges at
--             0.001. 200 coarse + 2000 fine is close to that without making a
--             full sweep a chore (norns encoders accelerate on fast turns).
--
-- option:   a named choice. `options` are the labels; `base` is the value the
--           engine receives for the FIRST label (0 for the engine's integer
--           dials like Scale, 1 for the od::Option menus, which are 1-based:
--           the engine compares against literal 1/2/3).
-- toggle:   on/off; the engine receives 0 or 1. For controls the engine reads
--           as a gate (`> 0.5`), where a 0–1 dial only pretended to be more.
-- trigger:  a momentary action; dirac.lua sends 1 then 0.
-- file:     a path chosen in the norns file browser.
--
-- script = true marks a param the SCRIPT handles itself rather than sending
-- to an engine command of the same id (check-params.sh skips these).
return {
  -- ── input (norns-side; not an ER-301 control) ───────────────────────────
  -- The ER-301 sees ±1.0 = ±10 V; a norns line input arrives at whatever the
  -- source sends. Compress, the soft limit and the feedback ring all respond
  -- to level, so gain is a real control, not a convenience.
  { id = "ingain",     name = "input gain",  min = -24,   max = 24,   default = 0, unit = "dB", detents = 96 },
  -- L+R averages the pair (a centred stereo source stays at unity). L or R
  -- alone fixes the common case of a mono cable in one jack, which the
  -- average would drop by 6 dB.
  { id = "insrc",      name = "input",       kind = "option", options = { "L+R", "L", "R" }, base = 1, default = 1 },

  -- ── source: live input or a loaded sample ─────────────────────────────────
  { id = "source",     name = "source",      kind = "option", options = { "live", "sample" }, base = 1, default = 1 },
  -- dirac.lua converts non-48 kHz files with sox, then calls engine.load().
  { id = "sample",     name = "sample",      kind = "file", script = true },
  { id = "unload",     name = "clear sample",kind = "trigger", script = true },

  -- ── source position ───────────────────────────────────────────────────────
  { id = "playhead",   name = "playhead",    min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "speed",      name = "speed",       min = -4.0,  max = 4.0,  default = 0.0, detents = 320 },
  -- 0 = parked, and parked is the ER-301 default. In live mode it has no
  -- audible effect at all, which the wrapper's per-inlet test reports as
  -- INERT rather than pretending to have verified.

  -- ── the cloud ─────────────────────────────────────────────────────────────
  { id = "rate",       name = "density",     min = 0.0,   max = 32.0, default = 3.0, detents = 640 },
  -- Density IS the simultaneous grain count: the engine sets
  -- hop = grainLen / overlap with overlap = rate, so alive grains = rate.
  -- 32, not the ER-301's 16: built with DIRAC_MAX_GRAINS=32 (ugen/Makefile).
  -- Defaults are the ER-301's, so nothing sounds different below 16.
  { id = "grains",     name = "grains",      min = 1,     max = 32,   default = 12, step = 1 },
  -- Exponential: three decades in 200 detents is ~3.5% per detent everywhere,
  -- so 20 ms and 500 ms are equally easy to land on. Same range as the ER-301.
  { id = "grainlen",   name = "grain length",min = 0.001, max = 1.0,  default = 0.050, unit = "s", warp = "exp" },
  { id = "posjtr",     name = "pos jitter",  min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "revprob",    name = "reverse prob",min = 0.0,   max = 1.0,  default = 0.0  },

  -- ── pitch ─────────────────────────────────────────────────────────────────
  { id = "semishift",  name = "transpose",   min = -24,   max = 24,   default = 0, step = 1, unit = "st" },
  { id = "voct",       name = "v/oct",       min = -2.0,  max = 2.0,  default = 0.0, unit = "v", detents = 400 },
  { id = "psprd",      name = "pitch scatter",min = 0.0,  max = 12.0, default = 0.0, unit = "st", detents = 240 },
  { id = "scale",      name = "scatter scale",kind = "option", base = 0, default = 1,
    options = { "off", "chromatic", "major", "minor", "pent major", "pent minor", "whole tone" } },

  -- ── grain envelope ────────────────────────────────────────────────────────
  { id = "window",     name = "shape",       kind = "option", base = 0, default = 1,
    options = { "normal", "bell", "sinc", "triangle", "decay", "ramp", "tukey", "square" } },
  { id = "texture",    name = "texture",     min = 0.0,   max = 1.0,  default = 0.5  },
  { id = "tilt",       name = "tilt",        min = -1.0,  max = 1.0,  default = 0.0  },
  { id = "tiltspread", name = "tilt scatter",min = 0.0,   max = 1.0,  default = 0.0  },

  -- ── playheads ─────────────────────────────────────────────────────────────
  { id = "heads",      name = "playheads",   min = 1,     max = 4,    default = 1, step = 1 },
  { id = "headspread", name = "head spread", min = 0.0,   max = 1.0,  default = 0.0  },
  -- Integer since 0.2.11 (setRounding(1) on the ER-301 dial).
  { id = "headtune",   name = "head tune",   min = -12,   max = 12,   default = 0, step = 1, unit = "st" },

  -- ── character ─────────────────────────────────────────────────────────────
  { id = "snap",       name = "snap",        min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "compress",   name = "compress",    min = 0.0,   max = 1.0,  default = 0.0  },

  -- ── stereo ────────────────────────────────────────────────────────────────
  { id = "spread",     name = "spread",      min = 0.0,   max = 1.0,  default = 0.5  },
  { id = "detune",     name = "detune",      min = 0.0,   max = 0.5,  default = 0.0, unit = "st" },
  { id = "binaural",   name = "binaural",    min = 0.0,   max = 1.0,  default = 0.0  },

  -- ── output ────────────────────────────────────────────────────────────────
  { id = "mix",        name = "mix",         min = 0.0,   max = 1.0,  default = 1.0  },
  { id = "feedback",   name = "feedback",    min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "level",      name = "level",       min = 0.0,   max = 1.0,  default = 0.7  },

  -- ── gates and actions ─────────────────────────────────────────────────────
  { id = "hold",       name = "hold",        kind = "toggle", default = 0 },
  { id = "fire",       name = "fire",        kind = "trigger" },

  -- ── menus (od::Option on the ER-301; 1-based) ─────────────────────────────
  -- The enable for multi-playhead. Off hard-bypasses heads / head spread /
  -- head tune in the engine (mMultiHeadOpt), so the UI dims them while off.
  { id = "playheadsOpt", name = "multi",     kind = "option", options = { "off", "on" },        base = 1, default = 1 },
  { id = "diffuseOpt",   name = "diffuse",   kind = "option", options = { "off", "on" },        base = 1, default = 1 },
  -- off/on so it draws as a toggle like every other on/off control
  { id = "freezeOpt",    name = "freeze",    kind = "option", options = { "off", "on" },        base = 1, default = 1 },
}
