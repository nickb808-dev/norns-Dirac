// Engine_Dirac.sc - the norns engine: a chain of five units.
//
// ASCII ONLY. tools/check-sc-collisions.sh enforces it; run `make check`
// before this file leaves the repo.
//
// THE CHAIN. input -> slot 1 -> ... -> slot 5 -> output, each stage a
// group, each link a private stereo bus. A slot holds one UNIT:
//
//   loop    Noether, the ER-301 looper (UGen, vendored engine)
//   dirac   Dirac, the ER-301 granular processor (UGen, vendored engine)
//   filter  Varia, the ER-301 variable-bandwidth filter made multimode
//           (UGen, engine/VariaFilter.h)
//   delay   a stereo delay with ping-pong spread
//   verb    JPverb (sc3-plugins), FreeVerb2 if absent
//   off     a wire (the script never sends it: it only reorders the five)
//
// A unit is one or more synths in its slot's group, reading the bus before
// it and writing the bus after it. Order is group order, so moving a unit is
// moving its synths to another group and re-pointing their buses: the unit
// KEEPS ITS STATE (a loop survives being moved past the delay). A unit taken
// out of the chain is freed; one put in is created fresh. Each unit type
// appears at most once, so every parameter keeps one id, one command and one
// value, whatever slot its unit is in.
//
// Every chain change is made under a 30 ms dip of the output (the output
// stage's duck), so moving, creating and freeing nodes never clicks.
//
// Parameters are remembered here (vals) and sent to every unit synth; a synth
// ignores names it does not have, and a unit created later starts with them.
//
// Two things learned on this machine, still true:
//
// 1. AN UNCAUGHT ERROR IN alloc HANGS THE SCRIPT SILENTLY. alloc runs in a
//    Routine and doneCallback only fires when it returns: throw, and the
//    script sits on "loading..." with nothing in any log. Hence the try.
//
// 2. PLACEMENT. The first version of this engine was silent because its synth
//    was added to the TAIL of context.xg; the working shape (Engine_TestSine)
//    adds to the HEAD. So the chain lives in one group at the head of
//    context.xg, and orders its own stages inside it.
Engine_Dirac : CroneEngine {

	var <root, <stages, <buses, <inSynth, <outSynth;
	var <chain, <units, vals, chainGen = 0;
	var <meter, <inAmp = 0, <outAmp = 0;
	// Display data from the UGens (SendNodeReply), forwarded to matron.
	var <vizFwd, <waveFwd, <loopFwd, <matron;
	// Sample mode, capture, and the looper's buffers.
	var <sampleBuf, loadGen = 0;
	var <capBuf, capFwd, capPath;
	var <loopBuf, <undoBuf;
	// The reverb's wet half exists only while its mix is above 0: JPverb
	// costs ~12% of the audio core even when silent.
	var verbGen = 0;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		try {
			// prAlloc answers false when the UGens are not installed yet; it
			// has already said why, so do not also claim to have loaded.
			if (this.prAlloc != false) { "Engine_Dirac: loaded".postln };
		} { arg err;
			"### Engine_Dirac: alloc failed ###".postln;
			err.reportError;
		};
	}

	prAlloc {
		var srv = context.server;
		// Looked up at RUN time, never named in source: naming a class the
		// library lacks fails the WHOLE class library, every engine on the
		// norns. This way only this engine fails, and says what to do.
		var diracUGen = \Dirac.asClass;
		var noetherUGen = \Noether.asClass;
		var variaUGen = \Varia.asClass;
		var jpverb = \JPverb.asClass;
		if (diracUGen.isNil or: { noetherUGen.isNil } or: { variaUGen.isNil }) {
			"### Engine_Dirac: the Dirac / Noether / Varia UGens are not installed yet. Load the norns-dirac script once (it installs them), then SYSTEM > RESTART.".postln;
			^false;
		};

		// 131072 = Dirac::kCapBufSize, the engine's live ring (2.73 s at 48k).
		capBuf = Buffer.alloc(srv, 131072, 1);
		// The loop: 30 s stereo, and an undo buffer of the same size. From
		// the server's normal heap, not its real-time pool.
		loopBuf = Buffer.alloc(srv, 48000 * 30, 2);
		undoBuf = Buffer.alloc(srv, 48000 * 30, 2);
		// bus 0: the input stage's output; bus k: slot k's output
		buses = Array.fill(6, { Bus.audio(srv, 2) });

		// -- the stages ------------------------------------------------------
		// LeakDC: the ER-301 chain is DC-free by construction; a norns codec
		// is not, and DC parked in a feedback ring (or a loop) pumps.
		SynthDef(\dirac_in, { arg out = 0, inbusl = 0, inbusr = 1, ingain = 0;
			var g = Lag.kr(ingain.dbamp, 0.05);
			Out.ar(out, [LeakDC.ar(In.ar(inbusl, 1)), LeakDC.ar(In.ar(inbusr, 1))] * g);
		}).add;

		// METERS: "input arriving, output silent" and "no input at all" are
		// different bugs that sound identical, so both are always measured.
		SynthDef(\dirac_out, { arg in = 0, out = 0, inmon = 0, duck = 1;
			var sig = In.ar(in, 2) * Lag.kr(duck, 0.01);
			var mon = In.ar(inmon, 2);
			SendReply.kr(Impulse.kr(15), '/dirac_amp',
				[Amplitude.kr((mon[0] + mon[1]) * 0.5), Amplitude.kr(sig[0] + sig[1])]);
			Out.ar(out, sig);
		}).add;

		SynthDef(\unit_off, { arg in = 0, out = 0;
			Out.ar(out, In.ar(in, 2));
		}).add;

		// -- loop: Noether. With no loop (or no buffer) it is an exact wire.
		// The triggers are plain controls the script raises and drops (a
		// rising edge is what the engine listens for); clk, v/oct and bars
		// are not used yet.
		SynthDef(\unit_loop, {
			arg in = 0, out = 0,
			    lrec = 0, ldub = 0, lundo = 0, lstop = 0, lext = 0,
			    lspeed = 1.0, lsos = 0.5, ldry = 1.0, llevel = 1.0, lclear = 0,
			    loopbuf = -1, undobuf = -1;
			var x = In.ar(in, 2);
			Out.ar(out, noetherUGen.ar(x[0], x[1],
				lrec, ldub, lstop, lundo, 0,
				lspeed, 0, lext, 0,
				lsos, ldry, llevel,
				1, loopbuf, undobuf, lclear));
		}).add;

		// -- dirac. Its input is MONO (one od::Inlet); insrc picks how the
		// pair becomes one: 1 L+R average, 2 L, 3 R. Mix is applied here, not
		// in the engine (held at 1): the engine's dry is its mono input, which
		// would collapse a stereo source. Same linear blend as Dirac.cpp's.
		SynthDef(\unit_dirac, {
			arg in = 0, out = 0, insrc = 1,
			    playhead = 0.0, speed = 0.0, rate = 3.0, grains = 12, grainlen = 0.05,
			    posjtr = 0.0, revprob = 0.0, semishift = 0, voct = 0.0, psprd = 0.0,
			    scale = 0, window = 0, texture = 0.5, tilt = 0.0, tiltspread = 0.0,
			    heads = 1, headspread = 0.0, headtune = 0, snap = 0.0,
			    compress = 0.0, spread = 0.5, detune = 0.0, binaural = 0.0,
			    mix = 1.0, feedback = 0.0, level = 0.7, fire = 0.0, hold = 0.0,
			    playheadsOpt = 1, diffuseOpt = 1, freezeOpt = 1,
			    source = 1, buf = -1, t_capture = 0, capbuf = -1;
			var x = In.ar(in, 2);
			var src = Select.ar((insrc - 1).clip(0, 2), [(x[0] + x[1]) * 0.5, x[0], x[1]]);
			var wet = Lag.kr(mix.clip(0, 1), 0.02);
			// Fire is read PER SAMPLE by the engine: expand it, so a gate
			// lands on the sample it was sent on.
			var sig = diracUGen.ar(src,
				playhead, rate, posjtr, spread, detune, level, revprob, psprd,
				texture, grains, K2A.ar(fire), hold, semishift, grainlen, 1.0, feedback,
				compress, binaural, scale, voct, speed, heads, headspread,
				headtune, snap, tilt, tiltspread, window,
				playheadsOpt, diffuseOpt, freezeOpt,
				// source 1 = live, 2 = sample; an unloaded sample (buf -1)
				// is live too
				Select.kr(source > 1.5, [-1, buf]),
				t_capture, capbuf);
			Out.ar(out, (sig * wet) + (x * (1 - wet)));
		}).add;

		// -- filter: Varia. Type sweeps low (0) -> band (0.5, Varia itself) ->
		// high (1). Freq is lagged on a log scale, so a sweep glides evenly
		// in pitch; the rest are lagged so a turn never zippers (the UGen
		// reads its controls once per block).
		SynthDef(\unit_filter, {
			arg in = 0, out = 0, ffreq = 1000, fres = 0.3, ftype = 0.0, fwidth = 0.5,
			    fpeaks = 0.0, fphase = 0.0, fmix = 0.0, fdrive = 0.0;
			var x = In.ar(in, 2);
			var f = Lag.kr(ffreq.clip(20, 20000).log, 0.05).exp;
			// drive: up to +24 dB into tanh, half made up after; crossfaded in
			// over the first eighth of the dial so 0 is the exact input
			var dr = Lag.kr(fdrive.clip(0, 1), 0.05);
			var g = (dr * 24).dbamp;
			var xd = x + ((((x * g).tanh / g.sqrt) - x) * (dr * 8).clip(0, 1));
			var y = variaUGen.ar(xd[0], xd[1], f,
				Lag.kr(fwidth.clip(0, 1), 0.05), Lag.kr(fres.clip(0, 1), 0.05),
				Lag.kr(ftype.clip(0, 1), 0.05), Lag.kr(fpeaks.clip(0, 1), 0.05),
				Lag.kr(fphase.clip(-1, 1), 0.05));
			var m = Lag.kr(fmix.clip(0, 1), 0.02);
			Out.ar(out, (x * (1 - m)) + (y * m));
		}).add;

		// -- delay: stereo, with spread from twin echoes (0) to ping-pong (1).
		// Time is lagged, so moving it glides like tape rather than
		// zippering. The feedback path is darkened, DC-blocked and softly
		// limited, so even feedback 1 settles instead of exploding. LocalIn
		// adds one block to the loop; the delay subtracts it.
		SynthDef(\unit_delay, {
			arg in = 0, out = 0, dtime = 0.375, dfdbk = 0.45, dsprd = 0.5, dmix = 0.0;
			var x = In.ar(in, 2);
			var t = (Lag.kr(dtime.clip(0.01, 2.0), 0.15) - ControlDur.ir).max(0.001);
			var fb = dfdbk.clip(0, 1) * 0.98;
			var s = Lag.kr(dsprd.clip(0, 1), 0.05);
			var m = Lag.kr(dmix.clip(0, 1), 0.02);
			var loop = LocalIn.ar(2);
			// ping-pong: the input enters on the left as spread rises, and
			// the echoes cross sides on every pass
			var feed = [x[0] + (x[1] * s), x[1] * (1 - s)] + loop;
			var d = DelayC.ar(feed, 2.1, t);
			var back = [(d[0] * (1 - s)) + (d[1] * s), (d[1] * (1 - s)) + (d[0] * s)];
			LocalOut.ar(LeakDC.ar(LPF.ar(back * fb, 7000)).tanh);
			Out.ar(out, (x * (1 - m)) + (d * m));
		}).add;

		// -- verb: two halves. The dry half is always there (the slot's
		// signal times 1 - mix); the wet half exists only while mix > 0,
		// created fresh (empty delay lines, no stale tail) and freed once
		// back at 0. Size is lagged because it resizes JPverb's delay lines.
		SynthDef(\unit_verb_dry, { arg in = 0, out = 0, vmix = 0.0;
			Out.ar(out, In.ar(in, 2) * (1 - Lag.kr(vmix.clip(0, 1), 0.02)));
		}).add;
		SynthDef(\unit_verb_wet, {
			arg in = 0, out = 0, vmix = 0.0, vtime = 2.0, vsize = 1.5, vdamp = 0.3;
			var x = In.ar(in, 2);
			var rev = if (jpverb.notNil) {
				jpverb.ar(x, Lag.kr(vtime.clip(0.1, 60), 0.1), Lag.kr(vdamp.clip(0, 1), 0.1),
					Lag.kr(vsize.clip(0.5, 5), 0.5))
			} {
				FreeVerb2.ar(x[0], x[1], 1, ((vsize - 0.5) / 4.5).clip(0, 1), vdamp.clip(0, 1))
			};
			Out.ar(out, rev * Lag.kr(vmix.clip(0, 1), 0.02));
		}).add;

		srv.sync;

		// The chain's own group, at the HEAD of context.xg (see 2 above), and
		// its stages in order inside it.
		root = Group.head(context.xg);
		stages = Array.fill(7, { Group.tail(root) });
		inSynth = Synth(\dirac_in, [\out, buses[0].index,
			\inbusl, context.in_b[0].index, \inbusr, context.in_b[1].index], stages[0]);
		outSynth = Synth(\dirac_out, [\in, buses[5].index, \out, context.out_b.index,
			\inmon, buses[0].index], stages[6]);

		vals = IdentityDictionary.new;
		vals[\loopbuf] = loopBuf.bufnum;
		vals[\undobuf] = undoBuf.bufnum;
		vals[\capbuf] = capBuf.bufnum;
		units = IdentityDictionary.new;
		chain = [\off, \off, \off, \off, \off];
		// the script's default order; it sends its own (PSET) order once its
		// params are set
		this.setChain([\loop, \dirac, \filter, \delay, \verb], false);

		// -- display data and meters, forwarded to matron (OSC 10111). A
		// reply arrives as [path, nodeID, replyID, values...]: strip three.
		matron = NetAddr("127.0.0.1", 10111);
		meter = OSCFunc({ arg msg; inAmp = msg[3]; outAmp = msg[4]; }, '/dirac_amp', srv.addr);
		loopFwd = OSCFunc({ arg msg; matron.sendMsg('/noether/viz', *msg.copyToEnd(3)); }, '/noether_viz', srv.addr);
		vizFwd = OSCFunc({ arg msg; matron.sendMsg('/dirac/viz', *msg.copyToEnd(3)); }, '/dirac_viz', srv.addr);
		waveFwd = OSCFunc({ arg msg; matron.sendMsg('/dirac/wave', *msg.copyToEnd(3)); }, '/dirac_wave', srv.addr);
		this.addPoll(\in_amp,  { inAmp });
		this.addPoll(\out_amp, { outAmp });

		// The chain: five unit indexes, 0 off, 1 loop, 2 dirac, 3 delay,
		// 4 verb, 5 filter.
		this.addCommand("chain", "iiiii", { arg msg;
			var names = [\off, \loop, \dirac, \delay, \verb, \filter];
			this.setChain(msg.copyRange(1, 5).collect({ arg i; names[i.asInteger.clip(0, 5)] }), true);
		});

		// Sample mode. Not params: these carry a path and a lifecycle.
		// NOT "load"/"unload": those are norns' own engine-table functions
		// (check-params.sh rejects any command named after one).
		this.addCommand("loadsample", "s", { arg msg; this.loadSample(msg[1].asString); });
		this.addCommand("clearsample", "", { this.unloadSample; });

		// Capture Dirac's ring to ~/dust/audio/dirac/capture-YYMMDD_HHMMSS.wav.
		// The UGen copies the ring (oldest first) into capBuf and replies; the
		// file is written only on an ok reply. A trigger, so NOT remembered:
		// a dirac created later must not capture on arrival.
		this.addCommand("capture", "", {
			capPath = "/home/we/dust/audio/dirac/capture-" ++ Date.localtime.stamp ++ ".wav";
			this.unitSet(\dirac, \t_capture, 1);
		});
		capFwd = OSCFunc({ arg msg;
			if (msg[3] > 0.5 and: { capPath.notNil }) {
				var path = capPath;
				capPath = nil;
				fork {
					File.mkdir("/home/we/dust/audio/dirac");
					// 32-bit float: the ring can exceed 1.0 with feedback
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
			\fire, \hold,
			\lrec, \ldub, \lundo, \lstop, \lext, \lspeed, \lsos, \ldry,
			\llevel, \lclear,
			\ffreq, \fres, \ftype, \fwidth, \fpeaks, \fphase, \fmix, \fdrive,
			\dtime, \dfdbk, \dsprd, \dmix,
			\vmix, \vtime, \vsize, \vdamp
		].do { |name|
			this.addCommand(name, "f", { |msg| this.set(name, msg[1]); });
		};

		// Menu options arrive as ints, 1-BASED to match od::OptionControl on the
		// device - the engine compares against literal 1/2/3.
		[\playheadsOpt, \diffuseOpt, \freezeOpt].do { |name|
			this.addCommand(name, "i", { |msg| this.set(name, msg[1]); });
		};
	}

	// -- parameters ---------------------------------------------------------
	set { arg name, v;
		vals[name] = v;
		if (name == \ingain) { inSynth.set(\ingain, v) };
		units.do { arg syns; syns.do { arg s; s.set(name, v) } };
		if (name == \vmix) { this.verbWet(v) };
	}

	// a one-off to one unit (a trigger), not remembered
	unitSet { arg unit, name, v;
		var syns = units[unit];
		if (syns.notNil) { syns.do { arg s; s.set(name, v) } };
	}

	// -- the chain ----------------------------------------------------------
	// The synths of a unit, created in `group` reading bus `in`, writing `out`.
	newUnit { arg name, group, in, out;
		var args = [\in, in, \out, out] ++ vals.asKeyValuePairs;
		^switch (name,
			\loop,  { [Synth.tail(group, \unit_loop, args)] },
			\dirac, { [Synth.tail(group, \unit_dirac, args)] },
			\delay, { [Synth.tail(group, \unit_delay, args)] },
			\filter, { [Synth.tail(group, \unit_filter, args)] },
			\verb,  {
				var dry = Synth.tail(group, \unit_verb_dry, args);
				if ((vals[\vmix] ? 0) > 0) { [dry, Synth.tail(group, \unit_verb_wet, args)] } { [dry] }
			},
			{ [Synth.tail(group, \unit_off, args)] }
		);
	}

	setChain { arg want, duck;
		var srv = context.server;
		var gen;
		want = want.collect({ arg u, i;
			// a unit in two slots keeps the first; the rest are off
			if (u != \off and: { want.copyRange(0, i - 1).includes(u) }) { \off } { u }
		});
		chainGen = chainGen + 1;
		gen = chainGen;
		fork {
			if (duck) { outSynth.set(\duck, 0); 0.03.wait };
			if (gen == chainGen) {
				var keep = IdentityDictionary.new;
				// units leaving the chain, and every wire (keyed off0..off4), are
				// freed; units staying are kept, to be moved
				units.keysValuesDo { arg name, syns;
					if (want.includes(name)) {
						keep[name] = syns;
					} {
						syns.do(_.free);
					};
				};
				units = IdentityDictionary.new;
				want.do { arg name, i;
					var g = stages[i + 1], in = buses[i].index, out = buses[i + 1].index;
					if (name == \off) {
						units[("off" ++ i).asSymbol] = this.newUnit(\off, g, in, out);
					} {
						if (keep[name].notNil) {
							// moved (or staying): same synths, new place
							keep[name].do { arg s; s.moveToTail(g); s.set(\in, in, \out, out) };
							units[name] = keep[name];
						} {
							units[name] = this.newUnit(name, g, in, out);
						};
					};
				};
				chain = want;
				srv.sync;
			};
			if (duck and: { gen == chainGen }) { outSynth.set(\duck, 1) };
		};
	}

	// The reverb's wet half: there while vmix > 0, gone 0.25 s after it
	// returns to 0 (once the 20 ms fade has finished), unless it moved again.
	verbWet { arg v;
		var syns = units[\verb], gen;
		verbGen = verbGen + 1;
		gen = verbGen;
		if (syns.isNil) { ^this };
		if (v > 0) {
			if (syns.size < 2) {
				units[\verb] = syns ++ [Synth.after(syns[0], \unit_verb_wet,
					vals.asKeyValuePairs ++ [\in, this.busIn(\verb), \out, this.busOut(\verb)])];
			};
		} {
			SystemClock.sched(0.25, {
				var s = units[\verb];
				if (gen == verbGen and: { s.notNil and: { s.size > 1 } }) {
					s[1].free;
					units[\verb] = [s[0]];
				};
				nil
			});
		};
	}

	busIn  { arg unit; ^buses[chain.indexOf(unit) ? 0].index }
	busOut { arg unit; ^buses[(chain.indexOf(unit) ? 0) + 1].index }

	// -- samples ------------------------------------------------------------
	// Read a file into a NEW buffer, point dirac at it, and only then free
	// the old one (0.25 s later: many blocks of margin). The file must already
	// be 48 kHz (the script converts with sox).
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
				this.set(\buf, b.bufnum);
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
		this.set(\buf, -1);
		if (old.notNil) { SystemClock.sched(0.25, { old.free; nil }) };
		matron.sendMsg('/dirac/unloaded');
	}

	// 128 waveform peaks for the field, read from the FILE, one bin at a time,
	// yielding between bins so a long file never stalls engine commands.
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
		meter.free; loopFwd.free; vizFwd.free; waveFwd.free; capFwd.free;
		// the root group takes every stage and unit with it
		if (root.notNil) { root.free; root = nil };
		if (buses.notNil) { buses.do(_.free); buses = nil };
		if (sampleBuf.notNil) { sampleBuf.free; sampleBuf = nil };
		if (capBuf.notNil) { capBuf.free; capBuf = nil };
		if (loopBuf.notNil) { loopBuf.free; loopBuf = nil };
		if (undoBuf.notNil) { undoBuf.free; undoBuf = nil };
	}
}
