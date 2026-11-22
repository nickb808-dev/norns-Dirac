// norns/od/audio/Sample.h — the norns/SuperCollider shim.
//
// The ER-301's public surface, as far as the two vendored engines touch it:
// Dirac reads mpData / mSampleCount / mChannelCount; Noether also reads
// mSampleLoadCount, calls setDirty(), and attach()es / release()s the samples
// it holds. Types are the device SDK's (uint32_t counts), which both engines
// already compile against on the ER-301. On norns this is a VIEW ONTO A
// SUPERCOLLIDER BUFFER, not an owner:
//
//     SndBuf *b = ...;                    // from the server, via bufnum
//     od::Sample s;
//     s.mpData           = b->data;
//     s.mSampleCount     = b->frames;     // FRAMES, not floats
//     s.mSampleLoadCount = b->frames;     // a server buffer is always "loaded"
//     s.mChannelCount    = b->channels;
//
// Two traps carried over from the ER-301 work, both learned the hard way:
//
//  1. mSampleCount counts FRAMES. Indexing is mpData[i * mChannelCount + ch].
//  2. The buffer is NOT ours and can be freed or reallocated underneath us.
//     SuperCollider's /b_free and /b_alloc are asynchronous with the audio
//     thread, which is the same hazard as the ER-301 sample pool's
//     allocateBuffer() calling freeBuffer() first. The wrappers rebuild this
//     view from the SndBuf every block; never cache the pointer or the length
//     across blocks.
//
// attach() / release(): on the device these reference-count the Sample
// OBJECT. Here the server and the script own the buffer's lifetime, so they
// only count, and nothing is ever destroyed by reaching zero.
#pragma once
#include <cstddef>
#include <cstdint>
namespace od {
struct Sample {
    uint32_t mSampleCount     = 0;        // FRAMES allocated
    uint32_t mSampleLoadCount = 0;        // FRAMES loaded (= mSampleCount here)
    uint32_t mChannelCount    = 1;
    float   *mpData           = nullptr;  // borrowed from the SC server
    float    mSampleRate      = 48000.0f;
    bool     mDirty           = false;
    int      mRefs            = 0;

    void attach()   { ++mRefs; }
    void release()  { --mRefs; }
    void setDirty() { mDirty = true; }
    void setClean() { mDirty = false; }
};
} // namespace od
