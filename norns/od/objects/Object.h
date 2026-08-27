// norns/od/objects/Object.h — the norns/SuperCollider shim.
//
// Same six symbols the ER-301 provides and the host harness stubs, but with
// one structural difference that matters:
//
//   THE PORTS DO NOT OWN THEIR BUFFERS.
//
// On the ER-301 (and in test/host) a Port carries `float mBuf[FRAMELENGTH]`.
// Under scsynth the audio lives in the graph's wires — IN(n) and OUT(n) hand
// you pointers the server owns, and they can move between calls. So a Port
// here is a NAMED POINTER that the wrapper re-points every process() call.
//
// The engine never notices: it only ever calls buffer(), and it re-reads that
// on every block already.
//
// Consequence to respect: a Port is only valid DURING a process() call. Do not
// cache buffer() across blocks in wrapper code.
#pragma once
#include <od/config.h>
#include <cstddef>

namespace od {

// A zero block, for inlets nothing is patched into. The ER-301 firmware does
// exactly this (Inlet::buffer() returns ZeroOutput.buffer() when
// mInwardConnection is null), and Varia's V/Oct bypass depends on the same
// behaviour — an unconnected control must read as a real buffer of zeros, not
// as null.
extern float gZeroBlock[FRAMELENGTH];

struct Port {
    const char *mName;
    float      *mpBuf;                     // borrowed; set per block

    explicit Port(const char *n) : mName(n), mpBuf(gZeroBlock) {}
    float *buffer() { return mpBuf; }
    // Wrapper-side only. Passing nullptr parks the port on the zero block,
    // which is what an unpatched input must read as.
    void point(float *p) { mpBuf = p ? p : gZeroBlock; }
};

using Inlet  = Port;
using Outlet = Port;

// Menu option. On norns these are params:add_option, driven over OSC, so the
// value arrives as an int from Lua. 1-based, matching the ER-301's
// OptionControl convention — the engine compares against literal 1/2/3.
struct Option {
    const char *mName;
    int         mValue;
    Option(const char *n, int v = 0) : mName(n), mValue(v) {}
    int  value() { return mValue; }        // non-const, matching the device SDK
    void set(int v) { mValue = v; }
};

struct Object {
    virtual ~Object() {}
    virtual void process() {}
    // The engine calls these from its constructor to register ports. On the
    // ER-301 they build the patchable graph; here the wrapper addresses ports
    // directly by member, so registration is a no-op — but the signatures must
    // exist or the vendored constructor will not compile.
    void addInput(Port &) {}
    void addOutput(Port &) {}
    void addOption(Option &) {}
};

} // namespace od
