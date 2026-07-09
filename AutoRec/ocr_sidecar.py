#!/usr/bin/env python3
"""MemorAI OCR sidecar.

Replaces the in-process Apple Vision OCR (which hangs on macOS 27 beta) with a
persistent RapidOCR (ONNX) daemon. The recognition model is loaded once; the
process then reads one image path per line on stdin and writes one JSON object
per line on stdout: {"text": "..."} (empty text on any failure).

Recognition model + char dict are configured globally in the rapidocr
config.yaml (patched to the cyrillic PP-OCRv3 model for Russian + English).
"""
import sys
import json


def main():
    try:
        from rapidocr_onnxruntime import RapidOCR
        ocr = RapidOCR()
    except Exception as e:  # pragma: no cover
        # Signal init failure, then exit so Swift falls back to no-OCR.
        sys.stdout.write(json.dumps({"ready": False, "error": str(e)}) + "\n")
        sys.stdout.flush()
        return

    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()

    for line in sys.stdin:
        path = line.strip()
        if not path:
            continue
        text = ""
        try:
            result, _ = ocr(path)
            if result:
                text = "\n".join(r[1] for r in result)
        except Exception:
            text = ""
        sys.stdout.write(json.dumps({"text": text}) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
