// Engine_ToneTest - the control experiment.
//
// If THIS is silent on the norns, then nothing about the Dirac port is at
// fault: a stock-shaped engine cannot make sound on that machine and the
// problem is the device's audio configuration.
//
// If this DOES make sound, then it is a working baseline and Engine_Dirac.sc
// can be brought towards it one change at a time - which is the order this
// should have been done in from the start, instead of debugging a 30-argument
// SynthDef, a C++ UGen, a plugin build and a params layer simultaneously.
//
// Deliberately the TestSine shape: {...}.play, no SynthDef, no sync, no
// explicit bus indices. Fewest possible things that can be wrong.
Engine_ToneTest : CroneEngine {

	var <synth;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		synth = {
			arg out, hz = 440, amp = 0.2;
			Out.ar(out, SinOsc.ar(hz, 0, amp).dup);
		}.play(args: [\out, context.out_b], target: context.xg);

		this.addCommand("hz", "f", { arg msg; synth.set(\hz, msg[1]); });
		this.addCommand("amp", "f", { arg msg; synth.set(\amp, msg[1]); });

		"Engine_ToneTest: loaded".postln;
	}

	free { synth.free; }
}
