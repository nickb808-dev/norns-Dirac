// Engine_Dirac.sc — the norns engine wrapper around the Dirac UGen.
//
// One long-lived synth, one addCommand per parameter. Deliberately thin: it
// owns no DSP and no musical decisions, so the only way it can be wrong is by
// naming or routing something incorrectly, and both are checkable.
//
// The command names here MUST match lib/params.lua's `id` fields, because
// dirac.lua calls engine.<id>(value) by name and a missing command is a silent
// no-op — the param moves in the menu and nothing happens. tools/check-params.sh
// compares the two lists.
Engine_Dirac : CroneEngine {

	var <synth;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		SynthDef(\dirac, {
			arg out = 0, in = 0,
			    playhead = 0.0, speed = 0.0, rate = 3.0, grains = 12, grainlen = 0.05,
			    posjtr = 0.0, revprob = 0.0, semishift = 0, voct = 0.0, psprd = 0.0,
			    scale = 0, window = 0, texture = 0.5, tilt = 0.0, tiltspread = 0.0,
			    heads = 1, headspread = 0.0, headtune = 0, snap = 0.0, color = 0.0,
			    compress = 0.0, spread = 0.5, detune = 0.0, binaural = 0.0,
			    mix = 1.0, feedback = 0.0, level = 0.7, fire = 0.0, hold = 0.0,
			    playheadsOpt = 1, diffuseOpt = 1, freezeOpt = 1;

			// The engine's input is MONO — one od::Inlet. norns hands us a
			// stereo pair, so sum and halve rather than silently dropping the
			// right channel. Halving keeps a centred mono source at unity
			// instead of 6 dB hot into the capture ring, which matters because
			// the ring feeds the feedback path.
			var src = (In.ar(in, 2).sum) * 0.5;

			// Fire is one of the two inlets the engine reads per SAMPLE. Passing
			// it at audio rate means a gate lands on the sample it was sent on,
			// rather than being quantised to the block. K2Aization is explicit
			// so the intent is visible at the call site.
			var fireAr = K2A.ar(fire);

			var sig = Dirac.ar(src,
				playhead, rate, posjtr, spread, detune, level, revprob, psprd,
				texture, grains, fireAr, hold, semishift, grainlen, mix, feedback,
				compress, binaural, scale, voct, speed, heads, headspread,
				headtune, snap, color, tilt, tiltspread, window,
				playheadsOpt, diffuseOpt, freezeOpt);

			Out.ar(out, sig);
		}).add;

		context.server.sync;

		synth = Synth.new(\dirac, [
			\out, context.out_b.index,
			\in,  context.in_b.index
		], context.xg);

		// ── one command per parameter ────────────────────────────────────────
		// Written out rather than generated from a list, because SuperCollider
		// has no access to lib/params.lua. The check script is what keeps them
		// in step; see tools/check-params.sh.
		[
			\playhead, \speed, \rate, \grains, \grainlen, \posjtr, \revprob,
			\semishift, \voct, \psprd, \scale, \window, \texture, \tilt,
			\tiltspread, \heads, \headspread, \headtune, \snap, \color,
			\compress, \spread, \detune, \binaural, \mix, \feedback, \level,
			\fire, \hold
		].do { |name|
			this.addCommand(name, "f", { |msg| synth.set(name, msg[1]); });
		};

		// Menu options arrive as ints. They are 1-BASED to match
		// od::OptionControl on the device — the engine compares against literal
		// 1/2/3, so sending 0 would silently select nothing.
		[\playheadsOpt, \diffuseOpt, \freezeOpt].do { |name|
			this.addCommand(name, "i", { |msg| synth.set(name, msg[1]); });
		};
	}

	free {
		synth.free;
	}
}
