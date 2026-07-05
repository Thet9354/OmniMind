//
//  AudioLevel.swift
//  OmniMind
//
//  Input level metering for the live capture UI. The user seeing the app
//  "hear" them within one buffer (~40 ms) makes model latency feel like
//  processing, not deafness — perceived latency is the one we can fix.
//  Computed on the transcription pump's executor, never the render thread.
//

import Accelerate
import AVFAudio

nonisolated enum AudioLevel {
    /// 0...1 loudness for UI metering: RMS mapped through dBFS with a
    /// -50 dB floor (silence) and 0 dB ceiling (full scale).
    static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else {
            return 0
        }
        var rms: Float = 0
        vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(buffer.frameLength))
        guard rms > 0 else { return 0 }

        let decibels = 20 * log10(rms)
        let floorDB: Float = -50
        return max(0, min(1, (decibels - floorDB) / -floorDB))
    }
}
