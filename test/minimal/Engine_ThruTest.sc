// Engine_ThruTest - the control experiment for the INPUT path.
//
// ToneTest answered "can a stock-shaped engine make sound here?" It proved the
// OUTPUT path and nothing else: a SinOsc needs no input, so it would have
// sounded identical on a norns whose audio input was disconnected, muted, or
// routed away from SuperCollider. Dirac is a PROCESSOR. Between ToneTest and
// Dirac sits an entire untested link - jack -> scsynth's hardware in ->
// CroneAudioContext's \adc synths -> context.in_b -> In.ar - and a fault
// anywhere along it produces exactly what Dirac produces: an engine that loads,
// takes commands, reports no error, and is silent.
//
// So this is ToneTest's sibling for the other half. Same .play form, same
// target group, same bus arguments as Engine_Dirac.sc. The ONLY difference from
// Dirac is that the DSP is a wire instead of a granulator:
//
//   Dirac:    Out.ar(out, Dirac.ar(src, ...30 args...))
//   ThruTest: Out.ar(out, src.dup)
//
// If this passes audio, the input path is sound and the fault is in the UGen,
// the plugin build, or the engine's own DSP.
// If this is SILENT, no amount of work on Dirac can help: the engine is being
// handed nothing to process, and the fix is in the norns' audio routing.
//
// The meter is the second half of the answer. It reports the two input busses
// SEPARATELY, at control rate, so the script can show a number even when the
// output path is the broken one - "input arriving, output silent" and "no input
// at all" are different diagnoses and they must not look alike on screen.
//
// ASCII ONLY, same as lib/Engine_Dirac.sc.
Engine_ThruTest : CroneEngine {

	var <synth;
	var <meter;
	var <ampL = 0, <ampR = 0;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		try {
			this.prAlloc;
			"Engine_ThruTest: loaded".postln;
		} { arg err;
			// Same guard as Engine_Dirac: an uncaught error in alloc leaves the
			// script on "loading..." forever with nothing in any log.
			"### Engine_ThruTest: alloc failed ###".postln;
			err.reportError;
		};
	}

	prAlloc {
		var srv = context.server;

		srv.sync;

		synth = {
			arg out = 0, inbusl = 0, inbusr = 1, amp = 1.0;
			var inl = In.ar(inbusl, 1);
			var inr = In.ar(inbusr, 1);
			// Identical to Engine_Dirac's source stage: sum and halve, so a
			// centred mono source arrives at unity rather than 6 dB hot.
			var src = (inl + inr) * 0.5;

			// Per-channel, pre-sum: L and R are reported separately because
			// "only one jack is connected" and "nothing is connected" must be
			// distinguishable on screen.
			SendReply.kr(Impulse.kr(15), '/thru_amp',
				[Amplitude.kr(inl), Amplitude.kr(inr)]);

			Out.ar(out, (src * amp).dup);

		}.play(args: [
			\out,    context.out_b,
			\inbusl, context.in_b[0].index,
			\inbusr, context.in_b[1].index
		], target: context.xg);

		// SendReply -> OSCFunc -> cached value -> addPoll. Bus.getSynchronous
		// would be shorter, but it needs sclang's shared-memory interface to the
		// server, and sclang did not boot scsynth here. This route works on any
		// server, local or not.
		meter = OSCFunc({ arg msg;
			ampL = msg[3];
			ampR = msg[4];
		}, '/thru_amp', srv.addr);

		this.addPoll(\amp_l, { ampL });
		this.addPoll(\amp_r, { ampR });

		this.addCommand("amp", "f", { arg msg; synth.set(\amp, msg[1]); });
	}

	free {
		meter.free;
		synth.free;
	}
}
