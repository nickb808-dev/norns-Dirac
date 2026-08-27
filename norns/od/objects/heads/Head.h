// norns/od/objects/heads/Head.h — the norns/SuperCollider shim.
//
// Dirac derives from od::Head only to inherit mpSample and setSample(); it
// does not use the ER-301's transport (mCurrentIndex / mEndIndex) for
// anything the norns build needs. attach()/release() are the SDK's
// reference-counting hooks — no-ops here, because on norns the SC Buffer's
// lifetime is managed by the server and the script, not by us.
//
// NOTE for whoever wires up sample loading in v2: on the ER-301,
// Head::setSample() reference-counts the SAMPLE OBJECT, which does NOT keep
// its audio buffer alive (Sample::allocateBuffer begins with freeBuffer).
// The SC equivalent is the same shape: holding a bufnum does not stop
// /b_free. Validate on every read.
#pragma once
#include <od/objects/Object.h>
#include <od/audio/Sample.h>
namespace od {
struct Head : Object {
    Sample *mpSample      = nullptr;
    int     mCurrentIndex = 0;
    int     mEndIndex     = 0;
    virtual void setSample(Sample *s) { mpSample = s; }
    Sample *getSample() { return mpSample; }
    int  getPosition()  { return mCurrentIndex; }
    void attach()  {}
    void release() {}
};
} // namespace od
