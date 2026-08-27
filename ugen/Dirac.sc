// Dirac.sc — the SuperCollider class for the Dirac UGen.
//
// The argument ORDER here is load-bearing: it must match the enum in
// DiracUGen.cpp, which in turn matches the engine's own registration order in
// Dirac::Dirac(). Three lists, one order. Changing one without the others
// produces a synth that runs happily with every control on the wrong knob.
//
// Defaults are the ER-301 unit's defaults, so a bare Dirac.ar(in) sounds like
// the module does at startup rather than like silence or a wall of noise.
Dirac : MultiOutUGen {

	*ar { arg in = 0.0,
		playhead = 0.0, rate = 2.0, posJtr = 0.0, spread = 0.0, detune = 0.0,
		level = 0.8, revProb = 0.0, psprd = 0.0, texture = 0.0, grains = 8.0,
		fire = 0.0, hold = 0.0, semiShift = 0.0, grainLen = 0.08, mix = 1.0,
		feedback = 0.0, compress = 0.0, binaural = 0.0, scale = 0.0, voct = 0.0,
		speed = 1.0, heads = 1.0, headSpread = 0.0, headTune = 0.0, snap = 0.0,
		color = 0.0, tilt = 0.5, tiltSpread = 0.0, window = 0.0,
		// menu options, 1-based to match od::OptionControl on the device
		playheadsOpt = 1, diffuseOpt = 1, freezeOpt = 1;

		^this.multiNew('audio', in,
			playhead, rate, posJtr, spread, detune, level, revProb, psprd,
			texture, grains, fire, hold, semiShift, grainLen, mix, feedback,
			compress, binaural, scale, voct, speed, heads, headSpread,
			headTune, snap, color, tilt, tiltSpread, window,
			playheadsOpt, diffuseOpt, freezeOpt);
	}

	init { arg ... theInputs;
		inputs = theInputs;
		^this.initOutputs(2, rate);
	}

	// `In` and `Fire` are the only two inputs the engine reads per SAMPLE; the
	// other 28 it reads once per block. The wrapper fans a control-rate Fire
	// out to a full block rather than reading off the end of a one-float wire,
	// so passing a .kr gate is safe — but audio rate is the accurate one if the
	// gate's exact sample position matters.
	checkInputs {
		if (inputs.at(0).rate != 'audio') {
			^"Dirac: input 0 (in) must be audio rate";
		};
		^this.checkValidInputs;
	}

	name { ^"Dirac" }
}
