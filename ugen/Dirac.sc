// Dirac.sc - SuperCollider class for the Dirac UGen.
//
// Deliberately minimal, and ASCII-only. An earlier version of this file broke
// the SuperCollider class library outright (norns showed SUPERCOLLIDER FAIL and
// no script would load). Proven by A/B: with a zero-byte Dirac.sc the server
// booted; with that file present it did not. Two things in it were not in any
// working UGen class I could point to - a `name` override, and em-dashes in the
// comments - so both are gone. This file now follows the shape of
// sc3-plugins' FM7.sc, which is a MultiOutUGen wrapping a C++ plugin, exactly
// the case here.
//
// ARGUMENT ORDER IS LOAD-BEARING. It must match the enum in DiracUGen.cpp,
// which matches the engine's own addInput() order in Dirac::Dirac(). Three
// lists, one order; tools/check-ugen-names.sh compares them.
//
// Defaults are the ER-301 dials' own initial biases, from dirac/assets/Dirac.lua.
Dirac : MultiOutUGen {

	*ar { arg in = 0.0,
		playhead = 0.0, rate = 3.0, posJtr = 0.0, spread = 0.5, detune = 0.0,
		level = 0.7, revProb = 0.0, psprd = 0.0, texture = 0.5, grains = 12.0,
		fire = 0.0, hold = 0.0, semiShift = 0.0, grainLen = 0.05, mix = 1.0,
		feedback = 0.0, compress = 0.0, binaural = 0.0, scale = 0.0, voct = 0.0,
		speed = 0.0, heads = 1.0, headSpread = 0.0, headTune = 0.0, snap = 0.0,
		color = 0.0, tilt = 0.0, tiltSpread = 0.0, window = 0.0,
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
}
