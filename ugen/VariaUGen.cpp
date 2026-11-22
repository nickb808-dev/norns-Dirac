// VariaUGen.cpp - the filter unit: engine/VariaFilter.h as a scsynth plugin.
//
// A wrapper with nothing to manage: no buffers, no display replies, no block
// size baked in (the filter takes any block length). The controls are read
// once per block, as Varia reads its inlets; the SynthDef lags them.
//
// Aliasing: scsynth may hand OUT(0) the same wire as IN(1). VariaFilter's
// process() reads both input samples before writing either output sample of
// the same index, so it is safe in place (test/varia-host `alias`,
// test/scstub/varia_driver.cpp `aliased`).
#include "SC_PlugIn.h"

#include <VariaFilter.h>

#include <new>

static InterfaceTable *ft;

// SC argument order; Varia.sc.in must match (tools/check-ugen-names.sh)
enum { kInL = 0, kInR, kFreq, kWidth, kRes, kType, kPeaks, kPhase, kNumInputs };

// NAME IS LOAD-BEARING: the SC class asks the server for a UGen by this name.
struct Varia : public Unit {
    varia::Filter f;
};

static void Varia_next(Varia *unit, int inNumSamples);
static void Varia_Ctor(Varia *unit);

void Varia_Ctor(Varia *unit)
{
    // scsynth hands over raw memory: construct the filter's state in place
    new (&unit->f) varia::Filter();
    SETCALC(Varia_next);
    ClearUnitOutputs(unit, 1);
}

void Varia_next(Varia *unit, int inNumSamples)
{
    varia::Filter &f = unit->f;
    f.freq  = IN0(kFreq);
    f.width = IN0(kWidth);
    f.res   = IN0(kRes);
    f.type  = IN0(kType);
    f.peaks = IN0(kPeaks);
    f.phase = IN0(kPhase);
    f.process(IN(kInL), IN(kInR), OUT(0), OUT(1), inNumSamples);
}

PluginLoad(Varia)
{
    ft = inTable;
    DefineSimpleUnit(Varia);
}
