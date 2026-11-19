// test/scstub/SC_PlugIn.h — a minimal stand-in for SuperCollider's plugin API.
//
// NOT a reimplementation of scsynth. It exists so DiracUGen.cpp can be COMPILED
// AND RUN on the dev host, where the real headers are not installed, before it
// is ever built on the Pi. Without this, the first execution of the wrapper
// would be on the target, where the debugging tools are worse and the feedback
// loop runs through another person.
//
// It mirrors the real API's SHAPE for the handful of macros the wrapper uses.
// Where the real header is more general (multiple rates, buffer colouring,
// SIMD alignment) this is deliberately literal. Anything the wrapper does not
// touch is absent on purpose: a stub that quietly accepts a call the real
// header would reject is worse than no stub, because it manufactures
// confidence. If DiracUGen starts using a new macro, this will fail to compile
// — which is the intended behaviour.
#pragma once
#include <cstdlib>
#include <cstdio>
#include <cstdarg>

enum { calc_ScalarRate = 0, calc_BufRate = 1, calc_FullRate = 2 };

typedef unsigned int uint32;
// The fields DiracUGen reads, in the real layout's order (SC_SndBuf.h,
// SC_World.h). Sample mode reads data/channels/frames of a global buffer.
struct SndBuf {
    double samplerate;
    double sampledur;
    float *data;
    int    channels;
    int    samples;
    int    frames;
};
struct World {
    uint32  mNumSndBufs;
    SndBuf *mSndBufs;
};
#define LOCK_SNDBUF_SHARED(buf)
#define LOCK_SNDBUF(buf)
struct Unit;
typedef void (*UnitCalcFunc)(struct Unit *unit, int inNumSamples);


struct Rate {
    double mSampleRate;
    int    mBufLength;
};

struct UnitInput {
    int mCalcRate;
};

// Real scsynth: Unit::mParent is a Graph*, and a Graph's FIRST member is its
// Node. SendReply-style UGens address their replies to &unit->mParent->mNode.
struct Node  { int mID; };
struct Graph { Node mNode; };

struct Unit {
    World        *mWorld;
    Graph        *mParent;
    int           mNumInputs, mNumOutputs;
    UnitCalcFunc  mCalcFunc;
    int           mBufLength;
    float       **mInBuf;
    float       **mOutBuf;
    UnitInput   **mInput;
    Rate         *mRate;
};

typedef void (*UnitCtorFunc)(Unit *);
typedef void (*UnitDtorFunc)(Unit *);

// The real table carries scsynth's whole service API. The wrapper only ever
// assigns it to `ft`, so a marker type is enough here — and keeping it empty
// means any future use of a real table member fails loudly on the host instead
// of silently working against a stub that invented it.
struct InterfaceTable {
    int unused;
};

#define IN(index)      ((const float *)(unit->mInBuf[index]))
#define IN0(index)     (IN(index)[0])
#define OUT(index)     (unit->mOutBuf[index])
#define INRATE(index)  (unit->mInput[index]->mCalcRate)
#define BUFLENGTH      (unit->mBufLength)
#define SAMPLERATE     (unit->mRate->mSampleRate)

#define SETCALC(func)  (unit->mCalcFunc = (UnitCalcFunc)&func)

#define RTAlloc(world, size) scstub_rtalloc(world, size)
#define RTFree(world, ptr)   scstub_rtfree(world, ptr)
#define Print                scstub_print
#define SendNodeReply        scstub_sendnodereply

void *scstub_rtalloc(World *w, size_t n);
void  scstub_rtfree(World *w, void *p);
void  scstub_print(const char *fmt, ...);
// Records each reply so the driver can check what the UGen would send.
void  scstub_sendnodereply(Node *node, int replyID, const char *cmd, int n, const float *values);

static inline void ClearUnitOutputs(Unit *unit, int n)
{
    for (int c = 0; c < unit->mNumOutputs; ++c)
        for (int i = 0; i < n; ++i) unit->mOutBuf[c][i] = 0.0f;
}

// The driver picks these up by name after including the wrapper.
extern UnitCtorFunc scstub_ctor;
extern UnitDtorFunc scstub_dtor;

#define DefineDtorUnit(name)                                                   \
    do { scstub_ctor = (UnitCtorFunc)&name##_Ctor;                             \
         scstub_dtor = (UnitDtorFunc)&name##_Dtor; } while (0)

// The real macro defines a C entry point scsynth calls at load. Here it becomes
// an ordinary function the driver calls itself.
#define PluginLoad(name)  void scstub_pluginload(InterfaceTable *inTable)
