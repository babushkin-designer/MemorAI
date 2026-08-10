#!/usr/bin/env python3
"""Offline acoustic echo cancellation for a recorded call.

Removes the far side's voice where it leaked from the speakers back into the
microphone. Apple's live voice processing does the same job at capture time,
but it reconfigures the SHARED input device for every other app on the machine
(measured: the built-in mic's virtual format goes 1ch -> 3ch while it is on),
which audibly degraded real meetings. Doing it here, after the recording has
stopped, cannot affect a live call at all.

Model: DTLN-aec (https://github.com/breizhn/DTLN-aec, MIT), 3rd place in the
Microsoft AEC Challenge. Runs on the LiteRT runtime — the one echo canceller of
its class that installs on arm64 macOS as a wheel, which matters on a machine
where Homebrew has no bottles and webrtc-audio-processing cannot be built.

Usage:
    aec_sidecar.py --mic mic.wav --lpb system.wav --out clean.wav \
                   --models /path/to/dtln_aec_512

Both inputs must be 16 kHz mono WAV. Prints one JSON object on stdout with the
measured quality of the result; the caller decides whether to keep it.
"""

import argparse
import json
import sys

import numpy as np
import soundfile as sf

BLOCK_LEN = 512
BLOCK_SHIFT = 128
# The model emits each sample BLOCK_LEN - BLOCK_SHIFT later than it arrived.
# Left uncorrected, the cleaned track would sit 24 ms behind the system track
# and the speaker-labeled transcript interleaves the two by timestamp.
MODEL_LATENCY = BLOCK_LEN - BLOCK_SHIFT
SAMPLE_RATE = 16000
# Echo arrives within a few hundred ms; a full second is generous headroom for
# the difference in when the two recorders were started.
MAX_DELAY_SECONDS = 1.0
# Enough audio to lock onto the delay; keeps peak memory in the hundreds of MB
# instead of gigabytes on a long call.
DELAY_WINDOW_SECONDS = 180.0
# Metrics are computed per 250 ms block. Working on block energies instead of
# per-sample envelopes is what keeps a 40-minute call in a few hundred MB: the
# per-sample version allocated ~1 GB of index arrays alone.
BLOCK = 4000
# Blocks sampled for the waveform check — 50 s is plenty to catch a mangled voice.
CORRELATION_BLOCKS = 200


def estimate_delay(mic, lpb):
    """Samples the reference must be shifted by to line up with the echo.

    MANDATORY, not an optimisation: fed tracks that are 167 ms apart — the
    normal offset between the two recorders — the model removed 0.7 dB of echo,
    i.e. nothing. Aligned first, the same audio gave 24.7 dB.

    Measured on a window rather than the whole call: correlating 40 minutes
    end to end needs gigabytes of FFT scratch for an answer a couple of minutes
    of audio already gives. The window is placed where the far side is loudest,
    since silence carries no delay information.
    """
    n = min(len(mic), len(lpb))
    window_span = int(DELAY_WINDOW_SECONDS * SAMPLE_RATE)
    if n > window_span:
        block = SAMPLE_RATE
        blocks = n // block
        energy = (lpb[:blocks * block].astype(np.float64) ** 2).reshape(blocks, block).sum(axis=1)
        width = max(1, window_span // block)
        totals = np.convolve(energy, np.ones(width), "valid")   # one value per second, cheap
        start = int(np.argmax(totals)) * block
        mic = mic[start:start + window_span]
        lpb = lpb[start:start + window_span]
        n = min(len(mic), len(lpb))

    a = mic[:n].astype(np.float64)
    b = lpb[:n].astype(np.float64)
    a = a - a.mean()
    b = b - b.mean()
    size = 1 << int(np.ceil(np.log2(2 * n)))
    corr = np.fft.irfft(np.fft.rfft(a, size) * np.conj(np.fft.rfft(b, size)), size)
    span = int(MAX_DELAY_SECONDS * SAMPLE_RATE)
    window = np.concatenate([corr[-span:], corr[: span + 1]])
    denom = np.sqrt((a ** 2).sum() * (b ** 2).sum()) + 1e-12
    window = window / denom
    peak = int(np.argmax(np.abs(window)))
    return peak - span, float(abs(window[peak]))


def block_energy(x, blocks):
    """Mean square per block, in chunks, so no full-length temporary appears."""
    out = np.empty(blocks, dtype=np.float64)
    step = 512
    for start in range(0, blocks, step):
        stop = min(start + step, blocks)
        chunk = x[start * BLOCK:stop * BLOCK].reshape(stop - start, BLOCK)
        out[start:stop] = np.einsum("ij,ij->i", chunk, chunk, dtype=np.float64) / BLOCK
    return out


def shift(signal, samples):
    out = np.zeros_like(signal)
    if samples == 0:
        return signal.copy()
    if samples > 0:
        out[samples:] = signal[:-samples]
    else:
        out[:samples] = signal[-samples:]
    return out


def run_model(mic, lpb, model_prefix):
    from ai_edge_litert import interpreter as tflite

    interp1 = tflite.Interpreter(model_path=model_prefix + "_1.tflite")
    interp1.allocate_tensors()
    interp2 = tflite.Interpreter(model_path=model_prefix + "_2.tflite")
    interp2.allocate_tensors()

    in1, out1 = interp1.get_input_details(), interp1.get_output_details()
    in2, out2 = interp2.get_input_details(), interp2.get_output_details()
    states1 = np.zeros(in1[1]["shape"], dtype="float32")
    states2 = np.zeros(in2[1]["shape"], dtype="float32")

    # float32 throughout: a float64 pad silently promotes the whole call and
    # triples the footprint.
    pad = np.zeros(BLOCK_LEN - BLOCK_SHIFT, dtype=np.float32)
    audio = np.concatenate((pad, mic.astype(np.float32, copy=False), pad))
    ref = np.concatenate((pad, lpb.astype(np.float32, copy=False), pad))

    result = np.zeros(len(audio), dtype=np.float32)
    buf = np.zeros(BLOCK_LEN, dtype="float32")
    buf_lpb = np.zeros(BLOCK_LEN, dtype="float32")
    out_buf = np.zeros(BLOCK_LEN, dtype="float32")

    blocks = (audio.shape[0] - (BLOCK_LEN - BLOCK_SHIFT)) // BLOCK_SHIFT
    for idx in range(blocks):
        start = idx * BLOCK_SHIFT
        buf[:-BLOCK_SHIFT] = buf[BLOCK_SHIFT:]
        buf[-BLOCK_SHIFT:] = audio[start:start + BLOCK_SHIFT]
        buf_lpb[:-BLOCK_SHIFT] = buf_lpb[BLOCK_SHIFT:]
        buf_lpb[-BLOCK_SHIFT:] = ref[start:start + BLOCK_SHIFT]

        block_fft = np.fft.rfft(np.squeeze(buf)).astype("complex64")
        mag = np.reshape(np.abs(block_fft), (1, 1, -1)).astype("float32")
        lpb_mag = np.reshape(
            np.abs(np.fft.rfft(np.squeeze(buf_lpb)).astype("complex64")), (1, 1, -1)
        ).astype("float32")

        interp1.set_tensor(in1[0]["index"], mag)
        interp1.set_tensor(in1[2]["index"], lpb_mag)
        interp1.set_tensor(in1[1]["index"], states1)
        interp1.invoke()
        mask = interp1.get_tensor(out1[0]["index"])
        states1 = interp1.get_tensor(out1[1]["index"])

        estimated = np.reshape(np.fft.irfft(block_fft * mask), (1, 1, -1)).astype("float32")
        interp2.set_tensor(in2[1]["index"], states2)
        interp2.set_tensor(in2[0]["index"], estimated)
        interp2.set_tensor(in2[2]["index"], np.reshape(buf_lpb, (1, 1, -1)).astype("float32"))
        interp2.invoke()
        block_out = interp2.get_tensor(out2[0]["index"])
        states2 = interp2.get_tensor(out2[1]["index"])

        out_buf[:-BLOCK_SHIFT] = out_buf[BLOCK_SHIFT:]
        out_buf[-BLOCK_SHIFT:] = 0.0
        out_buf += np.squeeze(block_out)
        result[start:start + BLOCK_SHIFT] = out_buf[:BLOCK_SHIFT]

    # Drop the padding the loop was primed with (what the reference
    # implementation trims). The model's own processing delay is removed
    # separately by the caller — measured, not assumed: after this trim the
    # output still lags its input by exactly MODEL_LATENCY samples.
    return result[MODEL_LATENCY:MODEL_LATENCY + len(mic)]


def measure(mic, lpb, clean):
    """Did this help the far side's echo without touching the near-end voice?

    Reported so the caller can reject a bad result and keep the raw mic — a
    track with echo is a cosmetic problem, a track with the user's voice eaten
    out of it is a destroyed recording.
    """
    blocks = min(len(mic), len(lpb), len(clean)) // BLOCK
    if blocks == 0:
        return {"far_seconds": 0.0, "near_seconds": 0.0,
                "erle_db": None, "voice_delta_db": None, "voice_correlation": None}

    mic_e = block_energy(mic, blocks)
    lpb_e = block_energy(lpb, blocks)
    clean_e = block_energy(clean, blocks)

    far = lpb_e > np.percentile(lpb_e, 85)
    near = (mic_e > np.percentile(mic_e, 70)) & (lpb_e < np.percentile(lpb_e, 35))
    seconds_per_block = BLOCK / SAMPLE_RATE

    def ratio_db(numerator, denominator, mask):
        return float(10 * np.log10((numerator[mask].mean() + 1e-20)
                                   / (denominator[mask].mean() + 1e-20)))

    out = {
        "far_seconds": float(far.sum()) * seconds_per_block,
        "near_seconds": float(near.sum()) * seconds_per_block,
        "erle_db": None,
        "voice_delta_db": None,
        "voice_correlation": None,
    }
    if out["far_seconds"] >= 1.0:
        out["erle_db"] = ratio_db(mic_e, clean_e, far)
    if out["near_seconds"] >= 1.0:
        out["voice_delta_db"] = ratio_db(clean_e, mic_e, near)
        # Waveform check on a bounded sample of the near-end blocks: enough to
        # tell "voice preserved" from "voice replaced", without building
        # another full-length array.
        chosen = np.flatnonzero(near)[:CORRELATION_BLOCKS]
        a = np.concatenate([mic[i * BLOCK:(i + 1) * BLOCK] for i in chosen]).astype(np.float64)
        b = np.concatenate([clean[i * BLOCK:(i + 1) * BLOCK] for i in chosen]).astype(np.float64)
        a -= a.mean()
        b -= b.mean()
        out["voice_correlation"] = float((a @ b) / (np.sqrt((a @ a) * (b @ b)) + 1e-12))
    return out


def main():
    parser = argparse.ArgumentParser(description="Offline AEC for a recorded call")
    parser.add_argument("--mic", required=True, help="16 kHz mono WAV of the microphone")
    parser.add_argument("--lpb", required=True, help="16 kHz mono WAV of the system audio")
    parser.add_argument("--out", required=True, help="where to write the cleaned WAV")
    parser.add_argument("--models", required=True, help="model path prefix, without _1/_2.tflite")
    args = parser.parse_args()

    # float32 halves the footprint, and every copy below is another full-length
    # array: a 40-minute call is ~150 MB per array at 16 kHz.
    mic, mic_rate = sf.read(args.mic, dtype="float32")
    lpb, lpb_rate = sf.read(args.lpb, dtype="float32")
    if mic_rate != SAMPLE_RATE or lpb_rate != SAMPLE_RATE:
        raise SystemExit(f"expected {SAMPLE_RATE} Hz input, got {mic_rate} and {lpb_rate}")
    if mic.ndim > 1 or lpb.ndim > 1:
        raise SystemExit("expected mono input")

    length = min(len(mic), len(lpb))
    if length < SAMPLE_RATE:
        raise SystemExit("inputs shorter than a second — nothing worth processing")
    mic, lpb = mic[:length], lpb[:length]

    delay, confidence = estimate_delay(mic, lpb)
    aligned = shift(lpb, delay)
    del lpb

    clean = run_model(mic, aligned, args.models)
    # Undo the model's fixed latency so the result stays on the mic's timeline.
    clean = shift(clean, -MODEL_LATENCY)

    sf.write(args.out, clean.astype("float32"), SAMPLE_RATE)

    report = {"delay_samples": int(delay), "delay_ms": delay / (SAMPLE_RATE / 1000.0),
              "delay_confidence": confidence, "seconds": length / SAMPLE_RATE}
    report.update(measure(mic, aligned, clean))
    json.dump(report, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
