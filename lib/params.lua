-- lib/params.lua — THE parameter table. One list, four consumers.
--
-- Every parameter's name, range, default and unit lives here and nowhere else.
-- dirac.lua builds the params menu from it, Engine_Dirac.sc is checked against
-- it, and (Phase 3) the cell UI pages index into it.
--
-- The ranges and defaults are the ER-301 unit's OWN, copied from
-- dirac/assets/Dirac.lua rather than invented. That matters more than it
-- sounds: this port's stated goal is to stay close to the module, and "close"
-- is only checkable if the numbers came from the module. Writing them from
-- memory got Speed, Heads, Grains, Tilt, Level, Rate, Spread, Texture and
-- GrainLen all wrong on the first pass.
--
-- Fields:
--   id        engine command name; must match Engine_Dirac.sc's addCommand
--   name      what the params menu shows
--   min/max   the ER-301 dial's bias range
--   default   the ER-301 dial's initial bias
--   unit      display suffix, or nil
--   step      1 for the integer-stepping dials (Grains, Heads, Window, Scale,
--             Semitone) — on the ER-301 these use setCoarseRadix and move in
--             whole units, because the DSP rounds them anyway
--   warp      controlspec warp; 'lin' unless noted
return {
  -- ── source position ───────────────────────────────────────────────────────
  { id = "playhead",   name = "playhead",    min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "speed",      name = "speed",       min = -4.0,  max = 4.0,  default = 0.0  },
  -- 0 = parked, and parked is the ER-301 default. Worth knowing before
  -- concluding the control does nothing: in live mode it has no audible effect
  -- at all, which the wrapper's per-inlet test reports as INERT rather than
  -- pretending to have verified.

  -- ── the cloud ─────────────────────────────────────────────────────────────
  { id = "rate",       name = "density",     min = 0.0,   max = 16.0, default = 3.0  },
  -- Density IS the simultaneous grain count: the engine sets
  -- hop = grainLen / overlap with overlap = rate, so alive grains = rate.
  -- Its max of 16 and kMaxGrains = 16 are the same number twice.
  { id = "grains",     name = "grains",      min = 1,     max = 16,   default = 12, step = 1 },
  { id = "grainlen",   name = "grain length",min = 0.001, max = 1.0,  default = 0.050, unit = "s" },
  { id = "posjtr",     name = "pos jitter",  min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "revprob",    name = "reverse prob",min = 0.0,   max = 1.0,  default = 0.0  },

  -- ── pitch ─────────────────────────────────────────────────────────────────
  { id = "semishift",  name = "transpose",   min = -24,   max = 24,   default = 0, step = 1, unit = "st" },
  { id = "voct",       name = "v/oct",       min = -2.0,  max = 2.0,  default = 0.0, unit = "v" },
  { id = "psprd",      name = "pitch scatter",min = 0.0,  max = 12.0, default = 0.0, unit = "st" },
  { id = "scale",      name = "scatter scale",min = 0,    max = 6,    default = 0, step = 1 },
  -- 0 off · 1 chromatic · 2 major · 3 minor · 4 pent maj · 5 pent min · 6 whole

  -- ── grain envelope ────────────────────────────────────────────────────────
  { id = "window",     name = "shape",       min = 0,     max = 7,    default = 0, step = 1 },
  -- 0 normal · 1 bell · 2 sinc · 3 tri · 4 decay · 5 ramp · 6 tukey · 7 square
  { id = "texture",    name = "texture",     min = 0.0,   max = 1.0,  default = 0.5  },
  { id = "tilt",       name = "tilt",        min = -1.0,  max = 1.0,  default = 0.0  },
  { id = "tiltspread", name = "tilt scatter",min = 0.0,   max = 1.0,  default = 0.0  },

  -- ── playheads ─────────────────────────────────────────────────────────────
  { id = "heads",      name = "playheads",   min = 1,     max = 4,    default = 1, step = 1 },
  { id = "headspread", name = "head spread", min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "headtune",   name = "head tune",   min = -12,   max = 12,   default = 0, unit = "st" },

  -- ── character ─────────────────────────────────────────────────────────────
  { id = "snap",       name = "snap",        min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "color",      name = "colour",      min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "compress",   name = "compress",    min = 0.0,   max = 1.0,  default = 0.0  },

  -- ── stereo ────────────────────────────────────────────────────────────────
  { id = "spread",     name = "spread",      min = 0.0,   max = 1.0,  default = 0.5  },
  { id = "detune",     name = "detune",      min = 0.0,   max = 0.5,  default = 0.0, unit = "st" },
  { id = "binaural",   name = "binaural",    min = 0.0,   max = 1.0,  default = 0.0  },

  -- ── output ────────────────────────────────────────────────────────────────
  { id = "mix",        name = "mix",         min = 0.0,   max = 1.0,  default = 1.0  },
  { id = "feedback",   name = "feedback",    min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "level",      name = "level",       min = 0.0,   max = 1.0,  default = 0.7  },

  -- ── gates ─────────────────────────────────────────────────────────────────
  { id = "fire",       name = "fire",        min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "hold",       name = "hold",        min = 0.0,   max = 1.0,  default = 0.0  },
}
