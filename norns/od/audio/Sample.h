// norns/od/audio/Sample.h — the norns/SuperCollider shim.
//
// Field-for-field identical to the ER-301's public surface, because that is
// all the engine touches (mpData / mSampleCount / mChannelCount). On norns
// this is a VIEW ONTO A SUPERCOLLIDER BUFFER, not an owner:
//
//     SndBuf *b = ...;                    // from the server, via bufnum
//     od::Sample s;
//     s.mpData        = b->data;
//     s.mSampleCount  = b->frames;        // FRAMES, not floats
//     s.mChannelCount = b->channels;
//
// Two traps carried over from the ER-301 work, both learned the hard way:
//
//  1. mSampleCount counts FRAMES. Indexing is mpData[i * mChannelCount + ch].
//     (The ER-301's od::Sample::get() is exactly that; Landau's peak scan had
//     to be checked against it.)
//  2. The buffer is NOT ours and can be freed or reallocated underneath us.
//     SuperCollider's /b_free and /b_alloc are asynchronous with the audio
//     thread, which is the same hazard as the ER-301 sample pool's
//     allocateBuffer() calling freeBuffer() first. Re-validate mpData every
//     time it is read; never cache the pointer or the length across blocks.
//
// v1 does not load samples (live granulation only), so this exists to satisfy
// the vendored engine's signature. Phase "v2 sample loading" is where it gets
// wired to a real Buffer.
#pragma once
#include <cstddef>
namespace od {
struct Sample {
    size_t mSampleCount  = 0;    // FRAMES
    int    mChannelCount = 1;
    float *mpData        = nullptr;   // borrowed from the SC server
};
} // namespace od
