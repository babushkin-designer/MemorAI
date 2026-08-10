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

Nothing is held in memory whole. The model is a block filter carrying its own
LSTM state, so the call is streamed through it in chunks and written out as it
goes; the metrics are folded in per block, and the one measurement that needs
raw waveform (the voice-correlation check) re-reads the handful of seconds it
samples off disk at the end.

Measured on a 33:43 call: peak RSS 1107 MB before, 353 MB after, with the
cleaned track coming out byte for byte identical. What is left is dominated by
the delay estimation's FFT over its 180 s window, not by the length of the
call.

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
# Enough audio to lock onto the delay; keeps the correlation's FFT scratch in
# the tens of MB instead of gigabytes on a long call.
DELAY_WINDOW_SECONDS = 180.0
# Metrics are computed per 250 ms block. Working on block energies instead of
# per-sample envelopes is what keeps a long call cheap to measure.
BLOCK = 4000
# Blocks sampled for the waveform check — 50 s is plenty to catch a mangled voice.
CORRELATION_BLOCKS = 200
# Samples streamed through the model at a time: 10 s, and a whole number of
# both the model's hop (128) and the metric block (4000), so neither the filter
# state nor the block accounting has to straddle a chunk boundary.
CHUNK = 160000


def read_at(handle, start, count, total):
    """`count` samples from `start`, zero-padded where they fall outside."""
    out = np.zeros(count, dtype=np.float32)
    lo, hi = max(0, start), min(total, start + count)
    if hi > lo:
        handle.seek(lo)
        got = handle.read(hi - lo, dtype="float32", always_2d=False)
        out[lo - start:lo - start + len(got)] = got
    return out


def reference_energy_per_second(lpb_path, total):
    """Mean square of the reference per second of the call, streamed."""
    seconds = total // SAMPLE_RATE
    energy = np.zeros(seconds, dtype=np.float64)
    if seconds == 0:
        return energy
    with sf.SoundFile(lpb_path) as handle:
        index = 0
        while index < seconds:
            count = min(CHUNK // SAMPLE_RATE, seconds - index)
            handle.seek(index * SAMPLE_RATE)
            chunk = handle.read(count * SAMPLE_RATE, dtype="float32", always_2d=False)
            block = chunk.reshape(count, SAMPLE_RATE).astype(np.float64)
            energy[index:index + count] = np.einsum("ij,ij->i", block, block)
            index += count
    return energy


def estimate_delay(mic_path, lpb_path, total):
    """Samples the reference must be shifted by to line up with the echo.

    MANDATORY, not an optimisation: fed tracks that are 167 ms apart — the
    normal offset between the two recorders — the model removed 0.7 dB of echo,
    i.e. nothing. Aligned first, the same audio gave 24.7 dB.

    Measured on a window rather than the whole call: correlating 40 minutes
    end to end needs gigabytes of FFT scratch for an answer a couple of minutes
    of audio already gives. The window is placed where the far side is loudest,
    since silence carries no delay information.
    """
    window_span = int(DELAY_WINDOW_SECONDS * SAMPLE_RATE)
    start = 0
    if total > window_span:
        energy = reference_energy_per_second(lpb_path, total)
        width = max(1, window_span // SAMPLE_RATE)
        totals = np.convolve(energy, np.ones(width), "valid")   # one value per second, cheap
        start = int(np.argmax(totals)) * SAMPLE_RATE
    n = min(window_span, total - start)

    with sf.SoundFile(mic_path) as mic_f, sf.SoundFile(lpb_path) as lpb_f:
        a = read_at(mic_f, start, n, total).astype(np.float64)
        b = read_at(lpb_f, start, n, total).astype(np.float64)
    a = a - a.mean()
    b = b - b.mean()
    span = int(MAX_DELAY_SECONDS * SAMPLE_RATE)
    # Sized for the lags actually read, not for the full linear correlation.
    # Both inputs are zero-padded to `size`, so with size >= n + span the
    # circular wrap-around only ever multiplies against that padding for
    # |lag| <= span — those values are the exact linear correlation. Doubling
    # it (the textbook 2n) would double the FFT scratch, which is the single
    # largest allocation left in this script.
    size = 1 << int(np.ceil(np.log2(n + span)))
    corr = np.fft.irfft(np.fft.rfft(a, size) * np.conj(np.fft.rfft(b, size)), size)
    window = np.concatenate([corr[-span:], corr[: span + 1]])
    denom = np.sqrt((a ** 2).sum() * (b ** 2).sum()) + 1e-12
    window = window / denom
    peak = int(np.argmax(np.abs(window)))
    return peak - span, float(abs(window[peak]))


class Canceller:
    """The DTLN-aec block filter as a stream: push samples, get samples back.

    The LSTM states are what make this legitimate — they carry everything the
    model knows across chunk boundaries, so a chunked run and a whole-file run
    produce the same output sample for sample.
    """

    def __init__(self, model_prefix):
        from ai_edge_litert import interpreter as tflite

        self.interp1 = tflite.Interpreter(model_path=model_prefix + "_1.tflite")
        self.interp1.allocate_tensors()
        self.interp2 = tflite.Interpreter(model_path=model_prefix + "_2.tflite")
        self.interp2.allocate_tensors()

        self.in1, self.out1 = self.interp1.get_input_details(), self.interp1.get_output_details()
        self.in2, self.out2 = self.interp2.get_input_details(), self.interp2.get_output_details()
        self.states1 = np.zeros(self.in1[1]["shape"], dtype="float32")
        self.states2 = np.zeros(self.in2[1]["shape"], dtype="float32")

        self.buf = np.zeros(BLOCK_LEN, dtype="float32")
        self.buf_lpb = np.zeros(BLOCK_LEN, dtype="float32")
        self.out_buf = np.zeros(BLOCK_LEN, dtype="float32")
        self.pending_audio = np.zeros(0, dtype="float32")
        self.pending_ref = np.zeros(0, dtype="float32")

    def push(self, audio, ref):
        """Feeds one chunk of the padded input streams; returns the output
        samples that became available (a whole number of hops)."""
        self.pending_audio = np.concatenate((self.pending_audio, audio))
        self.pending_ref = np.concatenate((self.pending_ref, ref))
        hops = len(self.pending_audio) // BLOCK_SHIFT
        if hops == 0:
            return np.zeros(0, dtype="float32")

        result = np.empty(hops * BLOCK_SHIFT, dtype="float32")
        for idx in range(hops):
            start = idx * BLOCK_SHIFT
            self.buf[:-BLOCK_SHIFT] = self.buf[BLOCK_SHIFT:]
            self.buf[-BLOCK_SHIFT:] = self.pending_audio[start:start + BLOCK_SHIFT]
            self.buf_lpb[:-BLOCK_SHIFT] = self.buf_lpb[BLOCK_SHIFT:]
            self.buf_lpb[-BLOCK_SHIFT:] = self.pending_ref[start:start + BLOCK_SHIFT]

            block_fft = np.fft.rfft(np.squeeze(self.buf)).astype("complex64")
            mag = np.reshape(np.abs(block_fft), (1, 1, -1)).astype("float32")
            lpb_mag = np.reshape(
                np.abs(np.fft.rfft(np.squeeze(self.buf_lpb)).astype("complex64")), (1, 1, -1)
            ).astype("float32")

            self.interp1.set_tensor(self.in1[0]["index"], mag)
            self.interp1.set_tensor(self.in1[2]["index"], lpb_mag)
            self.interp1.set_tensor(self.in1[1]["index"], self.states1)
            self.interp1.invoke()
            mask = self.interp1.get_tensor(self.out1[0]["index"])
            self.states1 = self.interp1.get_tensor(self.out1[1]["index"])

            estimated = np.reshape(np.fft.irfft(block_fft * mask), (1, 1, -1)).astype("float32")
            self.interp2.set_tensor(self.in2[1]["index"], self.states2)
            self.interp2.set_tensor(self.in2[0]["index"], estimated)
            self.interp2.set_tensor(self.in2[2]["index"],
                                    np.reshape(self.buf_lpb, (1, 1, -1)).astype("float32"))
            self.interp2.invoke()
            block_out = self.interp2.get_tensor(self.out2[0]["index"])
            self.states2 = self.interp2.get_tensor(self.out2[1]["index"])

            self.out_buf[:-BLOCK_SHIFT] = self.out_buf[BLOCK_SHIFT:]
            self.out_buf[-BLOCK_SHIFT:] = 0.0
            self.out_buf += np.squeeze(block_out)
            result[start:start + BLOCK_SHIFT] = self.out_buf[:BLOCK_SHIFT]

        consumed = hops * BLOCK_SHIFT
        self.pending_audio = self.pending_audio[consumed:]
        self.pending_ref = self.pending_ref[consumed:]
        return result


class OutputWriter:
    """Turns the model's result stream into the cleaned track on disk.

    The stream carries the priming padding the filter was started with, and
    lags its input by the model's fixed latency on top of that; both are
    dropped here so the result stays on the mic's own timeline. The track is
    always exactly as long as the mic, zero-filled if the stream runs short.
    """

    SKIP = 2 * MODEL_LATENCY

    def __init__(self, handle, total):
        self.handle = handle
        self.total = total
        self.skipped = 0
        self.written = 0

    def write(self, samples):
        if self.skipped < self.SKIP:
            drop = min(self.SKIP - self.skipped, len(samples))
            self.skipped += drop
            samples = samples[drop:]
        room = self.total - self.written
        if room <= 0 or len(samples) == 0:
            return np.zeros(0, dtype="float32")
        samples = samples[:room]
        self.handle.write(samples)
        self.written += len(samples)
        return samples

    def finish(self):
        missing = self.total - self.written
        if missing > 0:
            tail = np.zeros(missing, dtype="float32")
            self.handle.write(tail)
            self.written += missing
            return tail
        return np.zeros(0, dtype="float32")


class BlockEnergy:
    """Mean square per BLOCK samples, fed a chunk at a time. Samples past the
    last whole block are dropped, exactly as a reshape over the full call
    would have dropped them."""

    def __init__(self, blocks):
        self.values = np.zeros(blocks, dtype=np.float64)
        self.blocks = blocks
        self.carry = np.zeros(0, dtype=np.float32)
        self.filled = 0

    def add(self, samples):
        data = np.concatenate((self.carry, samples)) if len(self.carry) else samples
        whole = len(data) // BLOCK
        whole = min(whole, self.blocks - self.filled)
        if whole > 0:
            view = data[:whole * BLOCK].reshape(whole, BLOCK).astype(np.float64)
            self.values[self.filled:self.filled + whole] = \
                np.einsum("ij,ij->i", view, view) / BLOCK
            self.filled += whole
        self.carry = data[whole * BLOCK:]


def sample_blocks(path, indices, total):
    """Concatenates the given metric blocks read back off disk."""
    if len(indices) == 0:
        return np.zeros(0, dtype=np.float32)
    with sf.SoundFile(path) as handle:
        return np.concatenate([read_at(handle, int(i) * BLOCK, BLOCK, total) for i in indices])


def measure(mic_e, lpb_e, clean_e, mic_path, clean_path, total):
    """Did this help the far side's echo without touching the near-end voice?

    Reported so the caller can reject a bad result and keep the raw mic — a
    track with echo is a cosmetic problem, a track with the user's voice eaten
    out of it is a destroyed recording.
    """
    out = {"far_seconds": 0.0, "near_seconds": 0.0,
           "erle_db": None, "voice_delta_db": None, "voice_correlation": None}
    if len(mic_e) == 0:
        return out

    far = lpb_e > np.percentile(lpb_e, 85)
    near = (mic_e > np.percentile(mic_e, 70)) & (lpb_e < np.percentile(lpb_e, 35))
    seconds_per_block = BLOCK / SAMPLE_RATE

    def ratio_db(numerator, denominator, mask):
        return float(10 * np.log10((numerator[mask].mean() + 1e-20)
                                   / (denominator[mask].mean() + 1e-20)))

    out["far_seconds"] = float(far.sum()) * seconds_per_block
    out["near_seconds"] = float(near.sum()) * seconds_per_block
    if out["far_seconds"] >= 1.0:
        out["erle_db"] = ratio_db(mic_e, clean_e, far)
    if out["near_seconds"] >= 1.0:
        out["voice_delta_db"] = ratio_db(clean_e, mic_e, near)
        # Waveform check on a bounded sample of the near-end blocks: enough to
        # tell "voice preserved" from "voice replaced", read back off disk so
        # nothing full-length has to be kept around for it.
        chosen = np.flatnonzero(near)[:CORRELATION_BLOCKS]
        a = sample_blocks(mic_path, chosen, total).astype(np.float64)
        b = sample_blocks(clean_path, chosen, total).astype(np.float64)
        a -= a.mean()
        b -= b.mean()
        out["voice_correlation"] = float((a @ b) / (np.sqrt((a @ a) * (b @ b)) + 1e-12))
    return out


def cancel(mic_path, lpb_path, out_path, models, total, delay):
    """Streams the call through the model, writing as it goes. Returns the
    per-block energies the metrics are computed from."""
    blocks = total // BLOCK
    mic_e, lpb_e, clean_e = BlockEnergy(blocks), BlockEnergy(blocks), BlockEnergy(blocks)
    canceller = Canceller(models)
    pad = np.zeros(MODEL_LATENCY, dtype=np.float32)

    # Subtype left at the format default (PCM_16 for WAV) — the same file
    # sf.write produced before this was streamed, and what ffmpeg encodes from.
    with sf.SoundFile(out_path, "w", SAMPLE_RATE, 1) as out_f, \
            sf.SoundFile(mic_path) as mic_f, sf.SoundFile(lpb_path) as lpb_f:
        writer = OutputWriter(out_f, total)
        # The filter is primed with silence, the same way the reference
        # implementation pads the head of the call.
        clean_e.add(writer.write(canceller.push(pad, pad)))
        for start in range(0, total, CHUNK):
            count = min(CHUNK, total - start)
            mic_chunk = read_at(mic_f, start, count, total)
            # The reference is aligned by reading it at an offset instead of
            # building a shifted copy of the whole track.
            ref_chunk = read_at(lpb_f, start - delay, count, total)
            mic_e.add(mic_chunk)
            lpb_e.add(ref_chunk)
            clean_e.add(writer.write(canceller.push(mic_chunk, ref_chunk)))
        # No trailing pad: the reference implementation appends one but never
        # reaches it — its block count leaves those samples as an unprocessed
        # partial hop, and the track's last few ms are zeros. Feeding it here
        # would end the call on a different tail than every measurement so far
        # was taken against.
        clean_e.add(writer.finish())

    return mic_e.values, lpb_e.values, clean_e.values


def main():
    parser = argparse.ArgumentParser(description="Offline AEC for a recorded call")
    parser.add_argument("--mic", required=True, help="16 kHz mono WAV of the microphone")
    parser.add_argument("--lpb", required=True, help="16 kHz mono WAV of the system audio")
    parser.add_argument("--out", required=True, help="where to write the cleaned WAV")
    parser.add_argument("--models", required=True, help="model path prefix, without _1/_2.tflite")
    args = parser.parse_args()

    with sf.SoundFile(args.mic) as mic_f, sf.SoundFile(args.lpb) as lpb_f:
        if mic_f.samplerate != SAMPLE_RATE or lpb_f.samplerate != SAMPLE_RATE:
            raise SystemExit(f"expected {SAMPLE_RATE} Hz input, "
                             f"got {mic_f.samplerate} and {lpb_f.samplerate}")
        if mic_f.channels > 1 or lpb_f.channels > 1:
            raise SystemExit("expected mono input")
        total = min(len(mic_f), len(lpb_f))

    if total < SAMPLE_RATE:
        raise SystemExit("inputs shorter than a second — nothing worth processing")

    delay, confidence = estimate_delay(args.mic, args.lpb, total)
    mic_e, lpb_e, clean_e = cancel(args.mic, args.lpb, args.out, args.models, total, delay)

    report = {"delay_samples": int(delay), "delay_ms": delay / (SAMPLE_RATE / 1000.0),
              "delay_confidence": confidence, "seconds": total / SAMPLE_RATE}
    report.update(measure(mic_e, lpb_e, clean_e, args.mic, args.out, total))
    json.dump(report, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
