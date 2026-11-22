-- lib/params.lua — THE parameter table. One list, every consumer.
--
-- Every parameter's name, range, default and unit lives here and nowhere else.
-- norns-dirac.lua builds the params menu from it, Engine_Dirac.sc is checked against
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
--   short     the on-screen label, at most 5 characters (the page shows
--             label and value on one line; the full name flashes on the
--             page row while a param is being turned)
--   kind      "control" (default) | "option" | "toggle" | "trigger" | "macro"
--             | "text"
--
-- control:
--   min/max   the ER-301 dial's bias range
--   default   the ER-301 dial's initial bias
--   unit      display suffix, or nil
--   step      1 for the integer-stepping dials; the DSP rounds them anyway
--   warp      controlspec warp; 'lin' unless noted
--   detents   encoder detents across the whole range (default 200; norns-dirac.lua
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
-- trigger:  a momentary action; norns-dirac.lua sends 1 then 0.
-- file:     a path chosen in the norns file browser.
--
-- script = true marks a param the SCRIPT handles itself rather than sending
-- to an engine command of the same id (check-params.sh skips these).
return {
  -- ── input (norns-side; not an ER-301 control) ───────────────────────────
  -- The ER-301 sees ±1.0 = ±10 V; a norns line input arrives at whatever the
  -- source sends. Compress, the soft limit and the feedback ring all respond
  -- to level, so gain is a real control, not a convenience.
  { id = "ingain",     name = "input gain", short = "gain",  min = -24,   max = 24,   default = 0, unit = "dB", detents = 96 },
  -- L+R averages the pair (a centred stereo source stays at unity). L or R
  -- alone fixes the common case of a mono cable in one jack, which the
  -- average would drop by 6 dB.
  { id = "insrc",      name = "input", short = "input",       kind = "option", options = { "L+R", "L", "R" }, base = 1, default = 1 },

  -- ── the looper: Noether, BEFORE Dirac ─────────────────────────────────────
  -- The ER-301 unit's controls and defaults (noether/assets/Noether.lua),
  -- prefixed `l` so they never collide with Dirac's speed / level. Noether's
  -- stereo output is what Dirac granulates; with no loop it is a wire.
  -- One button, the pedal grammar: empty -> record -> close and play ->
  -- overdub in -> overdub out. K3 on the loop pages, K1 + K3 anywhere.
  { id = "lrec",       name = "rec", short = "rec",         kind = "trigger" },
  -- overdub in / out at once (the ER-301's dub button)
  { id = "ldub",       name = "dub", short = "dub",         kind = "trigger" },
  -- swaps the last overdub / extend pass out; again = redo
  { id = "lundo",      name = "undo", short = "undo",        kind = "trigger" },
  -- latched: fades the loop out and holds the head (K2 on the loop pages)
  { id = "lstop",      name = "stop", short = "stop",        kind = "toggle", default = 0 },
  -- latched: an overdub past the loop's end grows the loop
  { id = "lext",       name = "extend", short = "ext",      kind = "toggle", default = 0 },
  -- -2..+2, 0 = stopped, negative = reverse, pitch follows. Magnetic detents
  -- (engine) within 3 % of 1/4, 1/2, 1, 2 and 0. 160 detents = 0.025 each.
  { id = "lspeed",     name = "loop speed", short = "speed",  min = -2.0,  max = 2.0,  default = 1.0, unit = "x", detents = 160 },
  -- overdub crossfader: 0 replaces the loop with the input, 1 keeps it
  { id = "lsos",       name = "sos", short = "sos",         min = 0.0,   max = 1.0,  default = 0.5 },
  -- the live input level (forced to 1 while recording / overdubbing)
  { id = "ldry",       name = "dry", short = "dry",         min = 0.0,   max = 1.0,  default = 1.0 },
  { id = "llevel",     name = "loop level", short = "level",  min = 0.0,   max = 1.0,  default = 1.0 },
  { id = "lclear",     name = "clear loop", short = "clear",  kind = "trigger" },

  -- ── source: live input or a loaded sample ─────────────────────────────────
  { id = "source",     name = "source", short = "src",      kind = "option", options = { "live", "sample" }, base = 1, default = 1 },
  -- norns-dirac.lua converts non-48 kHz files with sox, then calls engine.load().
  { id = "sample",     name = "sample", short = "file",      kind = "file", script = true },
  { id = "unload",     name = "clear sample", short = "clear",kind = "trigger", script = true },
  -- Saves the live ring (2.73 s, feedback included) to
  -- ~/dust/audio/dirac/capture-YYMMDD_HHMMSS.wav. Also K1 + K3.
  { id = "capture",    name = "save capture", short = "save",kind = "trigger", script = true },

  -- ── source position ───────────────────────────────────────────────────────
  { id = "playhead",   name = "playhead", short = "head",    min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "speed",      name = "speed", short = "speed",       min = -4.0,  max = 4.0,  default = 0.0, detents = 320 },
  -- 0 = parked, and parked is the ER-301 default. In live mode it has no
  -- audible effect at all, which the wrapper's per-inlet test reports as
  -- INERT rather than pretending to have verified.

  -- ── the cloud ─────────────────────────────────────────────────────────────
  { id = "rate",       name = "density", short = "dens",     min = 0.0,   max = 32.0, default = 3.0, detents = 640 },
  -- Density IS the simultaneous grain count: the engine sets
  -- hop = grainLen / overlap with overlap = rate, so alive grains = rate.
  -- 32, not the ER-301's 16: built with DIRAC_MAX_GRAINS=32 (ugen/Makefile).
  -- Defaults are the ER-301's, so nothing sounds different below 16.
  { id = "grains",     name = "grains", short = "grns",      min = 1,     max = 32,   default = 12, step = 1 },
  -- Exponential: three decades in 200 detents is ~3.5% per detent everywhere,
  -- so 20 ms and 500 ms are equally easy to land on. Same range as the ER-301.
  { id = "grainlen",   name = "grain length", short = "len",min = 0.001, max = 1.0,  default = 0.050, unit = "s", warp = "exp" },
  { id = "posjtr",     name = "pos jitter", short = "jit",  min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "revprob",    name = "reverse prob", short = "rev",min = 0.0,   max = 1.0,  default = 0.0  },

  -- ── pitch ─────────────────────────────────────────────────────────────────
  { id = "semishift",  name = "transpose", short = "trans",   min = -24,   max = 24,   default = 0, step = 1, unit = "st" },
  { id = "voct",       name = "v/oct", short = "v/oct",       min = -2.0,  max = 2.0,  default = 0.0, unit = "v", detents = 400 },
  { id = "psprd",      name = "pitch scatter", short = "scat",min = 0.0,  max = 12.0, default = 0.0, unit = "st", detents = 240 },
  { id = "scale",      name = "scatter scale", short = "scale",kind = "option", base = 0, default = 1,
    options = { "off", "chromatic", "major", "minor", "pent major", "pent minor", "whole tone" } },

  -- ── grain envelope ────────────────────────────────────────────────────────
  { id = "window",     name = "shape", short = "shape",       kind = "option", base = 0, default = 1,
    options = { "normal", "bell", "sinc", "triangle", "decay", "ramp", "tukey", "square" } },
  { id = "texture",    name = "texture", short = "tex",     min = 0.0,   max = 1.0,  default = 0.5  },
  { id = "tilt",       name = "tilt", short = "tilt",        min = -1.0,  max = 1.0,  default = 0.0  },
  { id = "tiltspread", name = "tilt scatter", short = "tscat",min = 0.0,   max = 1.0,  default = 0.0  },

  -- ── playheads ─────────────────────────────────────────────────────────────
  { id = "heads",      name = "playheads", short = "heads",   min = 1,     max = 4,    default = 1, step = 1 },
  { id = "headspread", name = "head spread", short = "hsprd", min = 0.0,   max = 1.0,  default = 0.0  },
  -- Integer since 0.2.11 (setRounding(1) on the ER-301 dial).
  { id = "headtune",   name = "head tune", short = "htune",   min = -12,   max = 12,   default = 0, step = 1, unit = "st" },

  -- ── character ─────────────────────────────────────────────────────────────
  { id = "snap",       name = "snap", short = "snap",        min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "compress",   name = "compress", short = "comp",    min = 0.0,   max = 1.0,  default = 0.0  },

  -- ── stereo ────────────────────────────────────────────────────────────────
  { id = "spread",     name = "spread", short = "sprd",      min = 0.0,   max = 1.0,  default = 0.5  },
  { id = "detune",     name = "detune", short = "dtune",      min = 0.0,   max = 0.5,  default = 0.0, unit = "st" },
  { id = "binaural",   name = "binaural", short = "binau",    min = 0.0,   max = 1.0,  default = 0.0  },

  -- ── output ────────────────────────────────────────────────────────────────
  -- Dirac's wet/dry, applied in the SynthDef against Noether's STEREO output
  -- (the engine's own mix would collapse it to Dirac's mono input). Same
  -- linear blend as the engine's; now in sample mode too.
  { id = "mix",        name = "mix", short = "mix",         min = 0.0,   max = 1.0,  default = 1.0  },
  { id = "feedback",   name = "feedback", short = "fdbk",    min = 0.0,   max = 1.0,  default = 0.0  },
  { id = "level",      name = "level", short = "level",       min = 0.0,   max = 1.0,  default = 0.7  },

  -- ── delay: stereo, spread from twin echoes (0) to ping-pong (1) ──────────
  -- Time glides (lagged) rather than zippering. Feedback is darkened and
  -- softly limited in the loop, so 1 sustains rather than explodes.
  { id = "dtime",      name = "delay time",  short = "time",  min = 0.01,  max = 2.0,  default = 0.375, unit = "s", warp = "exp" },
  { id = "dfdbk",      name = "delay feedback", short = "fdbk", min = 0.0, max = 1.0,  default = 0.45 },
  { id = "dsprd",      name = "delay spread", short = "sprd", min = 0.0,  max = 1.0,  default = 0.5 },
  { id = "dmix",       name = "delay",       short = "mix",   min = 0.0,   max = 1.0,  default = 0.0 },

  -- ── the filter: Varia (ER-301, variable-bw), made multimode ─────────────
  -- Type sweeps the two band edges: 0 lowpass at freq, 0.5 Varia's band
  -- (freq +/- width), 1 highpass at freq; in between they glide. Resonance
  -- peaks the moving edge(s) and self-oscillates at 1; peaks adds Varia's
  -- interior resonators (2..7 peaks); phase swings the peaks across the
  -- stereo field. Width, resonance, peaks and phase are Varia's own ranges.
  { id = "ffreq",      name = "filter freq",  short = "freq",  min = 20,    max = 20000, default = 1000, unit = "Hz", warp = "exp", detents = 240 },
  { id = "fres",       name = "filter res",   short = "res",   min = 0.0,   max = 1.0,  default = 0.3 },
  { id = "ftype",      name = "filter type",  short = "type",  min = 0.0,   max = 1.0,  default = 0.0, fmt = "type", detents = 100 },
  { id = "fwidth",     name = "filter width", short = "width", min = 0.0,   max = 1.0,  default = 0.5 },
  { id = "fpeaks",     name = "filter peaks", short = "peaks", min = 0.0,   max = 1.0,  default = 0.0 },
  { id = "fphase",     name = "filter phase", short = "phase", min = -1.0,  max = 1.0,  default = 0.0 },
  { id = "fmix",       name = "filter",       short = "mix",   min = 0.0,   max = 1.0,  default = 0.0 },
  -- Drive: gain into a tanh saturator BEFORE the filter (0 .. +24 dB, half
  -- of it made up after), so resonance has something hot to ring against.
  -- At 0 the path is exact (the saturator is crossfaded out).
  { id = "fdrive",     name = "filter drive", short = "drive", min = 0.0,   max = 1.0,  default = 0.0 },

  -- ── macros: one knob, many params ─────────────────────────────────────────
  -- Each macro moves its targets, each between its own two values, in that
  -- param's own 0..1 space (so an exponential freq sweeps evenly in pitch).
  -- Targets are learned on the device (K3 on the macro page) and kept as
  -- text, "id=from>to;...", which PSETs save. The script handles all of it.
  -- M1 and M2 ship filled so the page is not empty; M3 and M4 are yours.
  { id = "m1map", name = "macro 1 targets", kind = "text", script = true,
    default = "fmix=0>1;ffreq=12000>300;fres=0.3>0.55;vdamp=0.3>0.85" },
  { id = "m2map", name = "macro 2 targets", kind = "text", script = true,
    default = "vmix=0>0.5;dmix=0>0.35;dsprd=0.5>1;vtime=2>6" },
  { id = "m3map", name = "macro 3 targets", kind = "text", script = true, default = "" },
  { id = "m4map", name = "macro 4 targets", kind = "text", script = true, default = "" },
  { id = "m1", name = "macro 1", short = "M1", kind = "macro", script = true, default = 0 },
  { id = "m2", name = "macro 2", short = "M2", kind = "macro", script = true, default = 0 },
  { id = "m3", name = "macro 3", short = "M3", kind = "macro", script = true, default = 0 },
  { id = "m4", name = "macro 4", short = "M4", kind = "macro", script = true, default = 0 },

  -- ── the chain: the order the five units run in ──────────────────────────
  -- Always all five, each once: one option over the 120 orders, so no order
  -- can be invalid. Set from the chain view (K1 held), saved in PSETs; the
  -- script sends it as one engine.chain.
  (function()
    local units, abbr = { "loop", "dirac", "filter", "delay", "verb" },
                        { loop = "lp", dirac = "dr", filter = "fl", delay = "dl", verb = "vb" }
    local orders, names = {}, {}
    local function permute(done, left)
      if #left == 0 then
        orders[#orders + 1] = done
        local a = {}
        for i, u in ipairs(done) do a[i] = abbr[u] end
        names[#names + 1] = table.concat(a, ">")
        return
      end
      for i, u in ipairs(left) do
        local d, l = { table.unpack(done) }, { table.unpack(left) }
        d[#d + 1] = u
        table.remove(l, i)
        permute(d, l)
      end
    end
    permute({}, units)
    return { id = "order", name = "chain", short = "chain", kind = "option", script = true,
             default = 1, options = names, orders = orders }
  end)(),

  -- ── reverb: JPverb (sc3-plugins), last in the chain ──────────────────────
  -- Wet/dry over everything before it; at 0 the output is exactly what it
  -- was without it. Engine_Dirac falls back to FreeVerb2 on a norns that has
  -- no sc3-plugins (size and damp then map onto room and damp).
  { id = "vmix",       name = "reverb", short = "verb",      min = 0.0,   max = 1.0,  default = 0.0 },
  -- T60: seconds for the tail to fall 60 dB. Exponential, like grain length.
  { id = "vtime",      name = "reverb time", short = "time", min = 0.1,   max = 60.0, default = 2.0, unit = "s", warp = "exp" },
  -- below 1 the space turns metallic (JPverb's own note); lagged, since the
  -- delay lines resize
  { id = "vsize",      name = "reverb size", short = "size", min = 0.5,   max = 5.0,  default = 1.5, detents = 180 },
  { id = "vdamp",      name = "reverb damp", short = "damp", min = 0.0,   max = 1.0,  default = 0.3 },

  -- ── gates and actions ─────────────────────────────────────────────────────
  { id = "hold",       name = "hold", short = "hold",        kind = "toggle", default = 0 },
  { id = "fire",       name = "fire", short = "fire",        kind = "trigger" },

  -- ── menus (od::Option on the ER-301; 1-based) ─────────────────────────────
  -- The enable for multi-playhead. Off hard-bypasses heads / head spread /
  -- head tune in the engine (mMultiHeadOpt), so the UI dims them while off.
  { id = "playheadsOpt", name = "multi", short = "multi",     kind = "option", options = { "off", "on" },        base = 1, default = 1 },
  { id = "diffuseOpt",   name = "diffuse", short = "diff",   kind = "option", options = { "off", "on" },        base = 1, default = 1 },
  -- off/on so it draws as a toggle like every other on/off control
  { id = "freezeOpt",    name = "freeze", short = "frz",    kind = "option", options = { "off", "on" },        base = 1, default = 1 },
}
