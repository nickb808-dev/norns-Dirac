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
	// Meter state. Written by the OSCFunc below, read by the polls.
	var <meter;
	// Display data from the UGen (SendNodeReply), forwarded to matron.
	var <vizFwd, <waveFwd, <matron;
	// Sample mode: the buffer the synth is reading, and a generation count so
	// a slow peak scan of an old file cannot overwrite a newer one's.
	var <sampleBuf, loadGen = 0;
	// Capture: one mono buffer the size of the engine's ring, allocated once;
	// the UGen copies the ring into it on a trigger and replies.
	var <capBuf, capFwd, capPath;
	var <inAmp = 0, <outAmp = 0;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		try {
			// prAlloc answers false when the UGen is not installed yet; it
			// has already said why, so do not also claim to have loaded.
			if (this.prAlloc != false) { "Engine_Dirac: loaded".postln };
		} { arg err;
			"### Engine_Dirac: alloc failed ###".postln;
			err.reportError;
		};
	}

	prAlloc {
		var srv = context.server;
		// The UGen class lives in Extensions/Dirac/Dirac.sc, installed by
		// norns-dirac.lua on its first run. It is looked up at RUN time, never named
		// in source: if this class named `Dirac` directly and a tester
		// restarted before that install, sclang would fail to compile the
		// WHOLE class library and every engine on the norns would break. This
		// way only Dirac fails, with a message saying what to do.
		var diracUGen = \Dirac.asClass;
		if (diracUGen.isNil) {
			"### Engine_Dirac: the Dirac UGen is not installed yet. Load the dirac script once (it installs it), then SYSTEM > RESTART.".postln;
			^false;
		};

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
		// 131072 = Dirac::kCapBufSize, the engine's live ring (2.73 s at 48k).
		// The UGen refuses a buffer smaller than its ring, so a mismatch here
		// shows up as "capture failed", never as a short or corrupt file.
		capBuf = Buffer.alloc(srv, 131072, 1);
		srv.sync;

		synth = {
			arg out = 0, inbusl = 0, inbusr = 1,
			    ingain = 0, insrc = 1,
			    playhead = 0.0, speed = 0.0, rate = 3.0, grains = 12, grainlen = 0.05,
			    posjtr = 0.0, revprob = 0.0, semishift = 0, voct = 0.0, psprd = 0.0,
			    scale = 0, window = 0, texture = 0.5, tilt = 0.0, tiltspread = 0.0,
			    heads = 1, headspread = 0.0, headtune = 0, snap = 0.0,
			    compress = 0.0, spread = 0.5, detune = 0.0, binaural = 0.0,
			    mix = 1.0, feedback = 0.0, level = 0.7, fire = 0.0, hold = 0.0,
			    playheadsOpt = 1, diffuseOpt = 1, freezeOpt = 1,
			    source = 1, buf = -1, t_capture = 0, capbuf = -1;

			// The engine's input is MONO - one od::Inlet. insrc picks how the
			// pair becomes one channel:
			//   1 L+R  average; a centred stereo source stays at unity rather
			//          than 6 dB hot into the capture ring, which feeds the
			//          feedback path
			//   2 L    left alone, at unity - a mono cable in one jack would
			//   3 R    lose 6 dB to the average
			var inl = In.ar(inbusl, 1);
			var inr = In.ar(inbusr, 1);
			// LeakDC: the ER-301 chain is DC-free by construction; a norns
			// codec is not, and DC parked in a feedback ring pumps.
			// Lag on the gain so turning it does not zipper.
			var src = LeakDC.ar(Select.ar((insrc - 1).clip(0, 2),
				[(inl + inr) * 0.5, inl, inr])) * Lag.kr(ingain.dbamp, 0.05);

			// Fire is one of only two inlets the engine reads PER SAMPLE, so
			// expand it explicitly: a gate then lands on the sample it was sent
			// on rather than at a block boundary.
			var fireAr = K2A.ar(fire);

			// Held in a var rather than passed straight to Out.ar so the meter
			// can tap the ACTUAL output, not a second evaluation of it.
			var sig = diracUGen.ar(src,
				playhead, rate, posjtr, spread, detune, level, revprob, psprd,
				texture, grains, fireAr, hold, semishift, grainlen, mix, feedback,
				compress, binaural, scale, voct, speed, heads, headspread,
				headtune, snap, tilt, tiltspread, window,
				playheadsOpt, diffuseOpt, freezeOpt,
				// source 1 = live, 2 = sample. A sample that is selected but
				// not loaded (buf -1) is live too: the UGen treats any invalid
				// buffer as live.
				Select.kr(source > 1.5, [-1, buf]),
				// t_ = a trigger control: high for one block, then 0
				t_capture, capbuf);

			// METERS, and the reason they are worth the two UGens.
			//
			// This engine has now been silent twice for reasons that were
			// INVISIBLE from the norns: an alloc error that never reached a log,
			// and a signal path that could not be told apart from a working one
			// without headphones and a guess. An engine that processes an input
			// must be able to say whether it is receiving anything - "input
			// arriving, output silent" and "no input at all" are different bugs
			// with different fixes, and they look identical when the only
			// instrument is your ears.
			//
			// Control rate, 15 Hz, two Amplitude followers: the cost is
			// negligible next to 16 grains, and it is always on because a
			// diagnostic you have to switch on is one you do not have when the
			// thing breaks.
			SendReply.kr(Impulse.kr(15), '/dirac_amp',
				[Amplitude.kr(src), Amplitude.kr(sig[0] + sig[1])]);

			Out.ar(out, sig);

		}.play(args: [
			\out,    context.out_b,
			\inbusl, context.in_b[0].index,
			\inbusr, context.in_b[1].index,
			\capbuf, capBuf.bufnum
		], target: context.xg);

		// SendReply -> OSCFunc -> cached value -> addPoll. Bus.getSynchronous
		// would be shorter, but it wants sclang's shared-memory interface to
		// the server, and sclang did not boot scsynth here. This route works
		// either way.
		meter = OSCFunc({ arg msg;
			inAmp  = msg[3];
			outAmp = msg[4];
		}, '/dirac_amp', srv.addr);

		// The grain field. The UGen sends /dirac_viz (~30 Hz) and /dirac_wave
		// (~4 Hz) to sclang; matron, the Lua process, listens for OSC on
		// 10111 and hands it to the script's osc.event. A reply arrives as
		// [path, nodeID, replyID, values...], so strip the first three.
		// Payload layout: see ugen/DiracUGen.cpp, "display data".
		matron = NetAddr("127.0.0.1", 10111);
		vizFwd = OSCFunc({ arg msg;
			matron.sendMsg('/dirac/viz', *msg.copyToEnd(3));
		}, '/dirac_viz', srv.addr);
		waveFwd = OSCFunc({ arg msg;
			matron.sendMsg('/dirac/wave', *msg.copyToEnd(3));
		}, '/dirac_wave', srv.addr);

		this.addPoll(\in_amp,  { inAmp });
		this.addPoll(\out_amp, { outAmp });

		// Sample mode. Not params: these carry a path and a lifecycle, not a
		// value (norns-dirac.lua's `sample` file param drives them).
		// NOT "load"/"unload": matron's engine table already has engine.load
		// (load an engine by name), so engine.load(path) never reached here -
		// norns tried to load an engine called "<path>". check-params.sh now
		// rejects any command named after an engine-table function.
		this.addCommand("loadsample", "s", { arg msg; this.loadSample(msg[1].asString); });
		this.addCommand("clearsample", "", { this.unloadSample; });

		// Capture the ring to ~/dust/audio/dirac/capture-YYMMDD_HHMMSS.wav.
		// The UGen copies the ring (oldest first) into capBuf and replies; the
		// file is written only on an ok reply, then matron is told where.
		this.addCommand("capture", "", {
			capPath = "/home/we/dust/audio/dirac/capture-" ++ Date.localtime.stamp ++ ".wav";
			synth.set(\t_capture, 1);
		});
		capFwd = OSCFunc({ arg msg;
			if (msg[3] > 0.5 and: { capPath.notNil }) {
				var path = capPath;
				capPath = nil;
				fork {
					File.mkdir("/home/we/dust/audio/dirac");
					// 32-bit float: the ring can exceed 1.0 with feedback, and
					// an integer file would clip what the grains are reading.
					capBuf.write(path, "wav", "float");
					srv.sync;
					("Engine_Dirac: captured " ++ path).postln;
					matron.sendMsg('/dirac/captured', path);
				};
			} {
				"Engine_Dirac: capture failed".postln;
				matron.sendMsg('/dirac/capture_fail');
			};
		}, '/dirac_captured', srv.addr);

		// One command per parameter. tools/check-params.sh reads these symbols
		// and compares them against lib/params.lua.
		[
			\ingain, \insrc, \source,
			\playhead, \speed, \rate, \grains, \grainlen, \posjtr, \revprob,
			\semishift, \voct, \psprd, \scale, \window, \texture, \tilt,
			\tiltspread, \heads, \headspread, \headtune, \snap,
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

	// Read a file into a NEW buffer, point the synth at it, and only then free
	// the old one. The UGen re-reads the buffer every block, so the swap is
	// clean as soon as the synth has moved; 0.25 s is many blocks of margin.
	// The file must already be 48 kHz (norns-dirac.lua converts with sox): the engine
	// assumes 48 kHz, and a 44.1 kHz file would play 9% sharp.
	loadSample { arg path;
		var gen;
		loadGen = loadGen + 1;
		gen = loadGen;
		Buffer.read(context.server, path, action: { arg b;
			if (b.numFrames.isNil or: { b.numFrames < 2 }) {
				("Engine_Dirac: could not read " ++ path).postln;
				b.free;
				matron.sendMsg('/dirac/load_fail', path);
			} {
				var old = sampleBuf;
				sampleBuf = b;
				synth.set(\buf, b.bufnum);
				if (old.notNil) { SystemClock.sched(0.25, { old.free; nil }) };
				("Engine_Dirac: loaded " ++ path ++ " (" ++ b.numFrames ++ " frames, "
					++ b.numChannels ++ " ch)").postln;
				matron.sendMsg('/dirac/loaded', path, b.numFrames, b.numChannels);
				this.sendPeaks(path, gen);
			};
		});
	}

	unloadSample {
		var old = sampleBuf;
		loadGen = loadGen + 1;
		sampleBuf = nil;
		synth.set(\buf, -1);
		if (old.notNil) { SystemClock.sched(0.25, { old.free; nil }) };
		matron.sendMsg('/dirac/unloaded');
	}

	// 128 waveform peaks for the field, read from the FILE rather than the
	// server buffer (no server round trip). One bin at a time, yielding
	// between bins so a long file never stalls sclang's handling of engine
	// commands. FloatArray abs/maxItem are primitives: fast even for minutes
	// of audio.
	sendPeaks { arg path, gen;
		fork {
			var sf = SoundFile.new, bins = 128, peaks;
			if (sf.openRead(path)) {
				var nf = sf.numFrames, nc = sf.numChannels;
				var per = (nf / bins).ceil.asInteger.max(1);
				peaks = Array.fill(bins, { arg i;
					var n = per.min(nf - (i * per)).max(0), p = 0;
					if (n > 0) {
						var data = FloatArray.newClear(n * nc);
						sf.readData(data);
						p = data.abs.maxItem ? 0;
					};
					0.wait;
					p
				});
				sf.close;
				if (gen == loadGen) { matron.sendMsg('/dirac/samplewave', *peaks) };
			};
		};
	}

	free {
		meter.free;
		if (sampleBuf.notNil) { sampleBuf.free; sampleBuf = nil };
		capFwd.free;
		if (capBuf.notNil) { capBuf.free; capBuf = nil };
		vizFwd.free;
		waveFwd.free;
		synth.free;
	}
}
