// Engine_Dirac.sc - the norns engine wrapper around the Dirac UGen.
//
// ASCII ONLY. tools/check-sc-collisions.sh enforces it; run `make check`
// before this file leaves the repo.
//
// Structured after Engine_Pappus.sc, a working engine on the same machine,
// rather than after assumptions. Two things that file already knew:
//
// 1. AN UNCAUGHT ERROR IN alloc HANGS THE SCRIPT SILENTLY.
//    alloc runs in a Routine and doneCallback only fires when it returns.
//    Throw, and matron's engine table stays empty, the script sits on
//    "loading..." forever, and nothing appears in maiden, journalctl, matron
//    or crone. Hence the try/catch.
//
// 2. context.in_b IS AN ARRAY OF BUSES, ONE PER CHANNEL.
//    context.out_b is a single bus and responds to .index. context.in_b does
//    not - index the channel first. Writing context.in_b.index throws
//    doesNotUnderstand, which by (1) is invisible. That was a real bug here.
//
// SILENCE, 2026-08-27, and what the control experiment showed. This engine
// loaded and its commands worked, but produced NO AUDIO. Bisected on-device:
// a SynthDef containing only SinOsc -> Out.ar, Dirac removed from the graph
// entirely, was ALSO silent - so the ported engine and the UGen wrapper were
// never implicated.
//
// test/minimal/ then established that a stock-shaped engine DOES make sound on
// this machine. The one thing that differed was group placement: TestSine gets
// \addToHead from .play(target: context.xg); this had \addToTail, copied from
// Engine_Pappus without asking whether it applied. See the note at Synth.new.
Engine_Dirac : CroneEngine {

	var <synth;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		try {
			this.prAlloc;
			"Engine_Dirac: loaded".postln;
		} { arg err;
			"### Engine_Dirac: alloc failed ###".postln;
			err.reportError;
		};
	}

	prAlloc {
		var srv = context.server;

		// Built as a FUNCTION-SYNTH via .play, not SynthDef + sync + Synth.new.
		//
		// This is the exact form of Engine_TestSine, which test/minimal/ proved
		// makes sound on this device. The SynthDef form did not, and rather than
		// keep guessing at which of its differences mattered - bus object vs
		// .index, group placement, the sync - this adopts the shape that is known
		// to work here and changes nothing else about the DSP.
		//
		// srv is still used: .play needs the SynthDef sent, and CroneEngine's
		// Routine makes that safe.
		srv.sync;

		synth = {
			arg out = 0, inbusl = 0, inbusr = 1,
			    playhead = 0.0, speed = 0.0, rate = 3.0, grains = 12, grainlen = 0.05,
			    posjtr = 0.0, revprob = 0.0, semishift = 0, voct = 0.0, psprd = 0.0,
			    scale = 0, window = 0, texture = 0.5, tilt = 0.0, tiltspread = 0.0,
			    heads = 1, headspread = 0.0, headtune = 0, snap = 0.0, color = 0.0,
			    compress = 0.0, spread = 0.5, detune = 0.0, binaural = 0.0,
			    mix = 1.0, feedback = 0.0, level = 0.7, fire = 0.0, hold = 0.0,
			    playheadsOpt = 1, diffuseOpt = 1, freezeOpt = 1;

			// The engine's input is MONO - one od::Inlet. Sum the pair and halve
			// rather than dropping the right channel: halving keeps a centred
			// mono source at unity instead of 6 dB hot into the capture ring,
			// which feeds the feedback path.
			var src = (In.ar(inbusl, 1) + In.ar(inbusr, 1)) * 0.5;

			// Fire is one of only two inlets the engine reads PER SAMPLE, so
			// expand it explicitly: a gate then lands on the sample it was sent
			// on rather than at a block boundary.
			var fireAr = K2A.ar(fire);

			Out.ar(out, Dirac.ar(src,
				playhead, rate, posjtr, spread, detune, level, revprob, psprd,
				texture, grains, fireAr, hold, semishift, grainlen, mix, feedback,
				compress, binaural, scale, voct, speed, heads, headspread,
				headtune, snap, color, tilt, tiltspread, window,
				playheadsOpt, diffuseOpt, freezeOpt));

		}.play(args: [
			\out,    context.out_b,
			\inbusl, context.in_b[0].index,
			\inbusr, context.in_b[1].index
		], target: context.xg);

		// One command per parameter. tools/check-params.sh reads these symbols
		// and compares them against lib/params.lua.
		[
			\playhead, \speed, \rate, \grains, \grainlen, \posjtr, \revprob,
			\semishift, \voct, \psprd, \scale, \window, \texture, \tilt,
			\tiltspread, \heads, \headspread, \headtune, \snap, \color,
			\compress, \spread, \detune, \binaural, \mix, \feedback, \level,
			\fire, \hold
		].do { |name|
			this.addCommand(name, "f", { |msg| synth.set(name, msg[1]); });
		};

		// Menu options arrive as ints, 1-BASED to match od::OptionControl on the
		// device - the engine compares against literal 1/2/3, so 0 selects
		// nothing at all.
		[\playheadsOpt, \diffuseOpt, \freezeOpt].do { |name|
			this.addCommand(name, "i", { |msg| synth.set(name, msg[1]); });
		};
	}

	free {
		synth.free;
	}
}
