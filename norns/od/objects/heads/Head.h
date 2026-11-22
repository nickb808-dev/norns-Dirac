// norns/od/objects/heads/Head.h — the norns/SuperCollider shim.
//
// Both engines derive from od::Head. Dirac inherits mpSample / setSample()
// and sets its own mEndIndex; Noether overrides setSample() and calls this
// one. setSample() follows the device SDK's order, because Noether relies on
// it: publish nothing mid-swap, release the old sample, attach the new one,
// publish last.
//
// attach()/release() on the HEAD are the SDK's object reference counting —
// no-ops here; the SC synth owns the unit's lifetime.
//
// On norns setSample() is called by the UGen wrappers on the audio thread at a
// block boundary, so "mid-swap" cannot actually be observed; the order is kept
// so the engines see exactly the semantics they were written against.
#pragma once
#include <od/objects/Object.h>
#include <od/audio/Sample.h>
namespace od {
struct Head : Object {
    Sample *mpSample      = nullptr;
    int     mCurrentIndex = 0;
    int     mEndIndex     = 0;

    virtual void setSample(Sample *sample)
    {
        Sample *p = mpSample;
        mpSample = nullptr;
        if (p) p->release();
        p = sample;
        if (p) {
            p->attach();
            mEndIndex = int(p->mSampleCount) - 2;
        } else {
            mEndIndex = 0;
        }
        mpSample = p;
    }
    virtual ~Head() { if (mpSample) mpSample->release(); }

    Sample *getSample() { return mpSample; }
    int  getPosition()  { return mCurrentIndex; }
    void attach()  {}
    void release() {}
};
} // namespace od
