"""Unit tests for the v1 source-taxonomy classifier.

Pure-Python — no Lightroom required. Each test exercises one rule and
its precedence relative to others.
"""

import pytest

from mcp_server.classifier import (
    CLASSIFIER_VERSION,
    ALL_SOURCE_KEYWORDS,
    Classification,
    CandidatePhoto,
    classify_batch,
    classify_one,
)
from mcp_server.classifier.source_classifier import (
    SOURCE_CAPTURE,
    SOURCE_SCREENSHOT,
    SOURCE_RECEIVED,
    SOURCE_WEB,
    SOURCE_SCANNED,
    SOURCE_UNCLASSIFIED,
    SOURCE_VIDEO,
)


pytestmark = pytest.mark.unit


def _candidate(**kwargs) -> CandidatePhoto:
    """Build a CandidatePhoto with sensible defaults."""
    return CandidatePhoto(
        photo_id=kwargs.pop("photo_id", 1),
        path=kwargs.pop("path", ""),
        filename=kwargs.pop("filename", ""),
        file_format=kwargs.pop("file_format", "JPG"),
        make=kwargs.pop("make", None),
        model=kwargs.pop("model", None),
        software=kwargs.pop("software", None),
        width=kwargs.pop("width", None),
        height=kwargs.pop("height", None),
        **kwargs,
    )


class TestVideoShortcut:
    """Video v1 Policy: any video gets source:video, no further rules."""

    def test_file_format_video(self):
        c = _candidate(file_format="VIDEO", filename="vacation.mov")
        assert classify_one(c).source_keyword == SOURCE_VIDEO

    def test_extension_mp4(self):
        c = _candidate(file_format=None, filename="clip.mp4")
        assert classify_one(c).source_keyword == SOURCE_VIDEO

    def test_video_short_circuits_capture(self):
        # Even with a real camera tag, video stays video — image classifier
        # rules don't apply.
        c = _candidate(
            file_format="VIDEO",
            filename="DSC_0001.mov",
            make="NIKON",
            model="D850",
        )
        assert classify_one(c).source_keyword == SOURCE_VIDEO


class TestScannerSoftware:
    """Scanner software tag is highest precedence above image rules."""

    def test_vuescan(self):
        c = _candidate(filename="img001.tif", software="VueScan 9.7")
        assert classify_one(c).source_keyword == SOURCE_SCANNED

    def test_silverfast(self):
        c = _candidate(filename="img002.tif", software="SilverFast Ai 8")
        assert classify_one(c).source_keyword == SOURCE_SCANNED

    def test_scanner_overrides_capture_signal(self):
        # If a scan happens to inherit Make/Model from the source EXIF,
        # scanner software should still win.
        c = _candidate(
            filename="scan.jpg",
            software="VueScan 9.7",
            make="EPSON",
            model="V800",
        )
        assert classify_one(c).source_keyword == SOURCE_SCANNED


class TestScreenshot:
    """Screenshot is identified primarily by filename."""

    def test_android_screenshot_underscore(self):
        c = _candidate(filename="Screenshot_20240115_143022.png")
        assert classify_one(c).source_keyword == SOURCE_SCREENSHOT

    def test_macos_screen_shot(self):
        c = _candidate(filename="Screen Shot 2024-01-15 at 14.30.22.png")
        assert classify_one(c).source_keyword == SOURCE_SCREENSHOT

    def test_screenshot_anywhere_in_name(self):
        c = _candidate(filename="my-screenshot-20240115.png")
        assert classify_one(c).source_keyword == SOURCE_SCREENSHOT

    def test_screenshot_overrides_no_camera(self):
        # No EXIF camera tag, but screenshot pattern wins regardless.
        c = _candidate(filename="Screenshot_2024.png", make=None, model=None)
        assert classify_one(c).source_keyword == SOURCE_SCREENSHOT


class TestCapture:
    """EXIF Make/Model is the strong signal for a real shutter event."""

    def test_make_only(self):
        c = _candidate(filename="DSC_0001.NEF", make="NIKON")
        result = classify_one(c)
        assert result.source_keyword == SOURCE_CAPTURE
        assert any("exif-camera" in s for s in result.signals)

    def test_model_only(self):
        c = _candidate(filename="IMG_0001.JPG", model="iPhone 15")
        assert classify_one(c).source_keyword == SOURCE_CAPTURE

    def test_capture_with_messaging_path_loses_to_capture(self):
        # If a real camera EXIF is present, capture wins over the path
        # heuristic — a real photo someone happened to save under WhatsApp.
        c = _candidate(
            filename="IMG_0001.JPG",
            make="Canon",
            model="EOS R5",
            path="C:/Users/ken/WhatsApp/IMG_0001.JPG",
        )
        assert classify_one(c).source_keyword == SOURCE_CAPTURE


class TestPathHeuristics:
    """Messaging-dir and download-dir trigger only when no stronger signal."""

    def test_whatsapp_path(self):
        c = _candidate(
            filename="IMG-20240115-WA0001.jpg",
            path="C:/Users/ken/Pictures/WhatsApp/IMG-20240115-WA0001.jpg",
        )
        assert classify_one(c).source_keyword == SOURCE_RECEIVED

    def test_telegram_path(self):
        c = _candidate(
            filename="photo.jpg",
            path="/home/ken/Telegram/photo.jpg",
        )
        assert classify_one(c).source_keyword == SOURCE_RECEIVED

    def test_downloads_path(self):
        c = _candidate(
            filename="random_hash.jpg",
            path="C:/Users/ken/Downloads/random_hash.jpg",
        )
        assert classify_one(c).source_keyword == SOURCE_WEB

    def test_instagram_save_path(self):
        c = _candidate(
            filename="ig_save.jpg",
            path="C:/Users/ken/Pictures/Instagram/ig_save.jpg",
        )
        assert classify_one(c).source_keyword == SOURCE_WEB


class TestAmbiguousFallback:
    """No strong signal → source:unclassified, surfaces for review."""

    def test_blank_metadata(self):
        c = _candidate(filename="random.jpg", path="/var/random.jpg")
        result = classify_one(c)
        assert result.source_keyword == SOURCE_UNCLASSIFIED
        assert "no-strong-signal" in result.signals

    def test_no_camera_no_path(self):
        c = _candidate(filename="x.jpg")
        assert classify_one(c).source_keyword == SOURCE_UNCLASSIFIED


class TestPrecedenceOrdering:
    """Cross-rule precedence locked in v1."""

    def test_scanner_beats_screenshot_filename(self):
        # Edge case: scanner software AND screenshot-y filename. Scanner wins
        # per documented order.
        c = _candidate(
            filename="screenshot_scan.jpg",
            software="VueScan 9.7",
        )
        assert classify_one(c).source_keyword == SOURCE_SCANNED

    def test_screenshot_beats_capture_when_no_exif(self):
        c = _candidate(filename="Screenshot_2024.png", make=None, model=None)
        assert classify_one(c).source_keyword == SOURCE_SCREENSHOT

    def test_messaging_loses_to_capture(self):
        c = _candidate(
            filename="IMG_0001.JPG",
            path="/User/Telegram/IMG_0001.JPG",
            make="Canon",
        )
        # capture wins
        assert classify_one(c).source_keyword == SOURCE_CAPTURE


class TestBatchAndShape:
    """The contract the Lua walker / Python orchestrator depend on."""

    def test_classify_batch_accepts_dicts(self):
        items = [
            {"id": 1, "filename": "DSC.NEF", "cameraMake": "NIKON"},
            {"id": 2, "filename": "Screenshot_x.png"},
        ]
        out = classify_batch(items)
        assert len(out) == 2
        assert out[0].photo_id == 1
        assert out[0].source_keyword == SOURCE_CAPTURE
        assert out[1].source_keyword == SOURCE_SCREENSHOT

    def test_classify_batch_accepts_candidate_objects(self):
        items = [
            _candidate(photo_id=42, filename="x.mp4"),
        ]
        out = classify_batch(items)
        assert out[0].photo_id == 42
        assert out[0].source_keyword == SOURCE_VIDEO

    def test_classification_to_dict_shape(self):
        c = _candidate(photo_id=7, filename="a.jpg", make="Canon")
        result = classify_one(c)
        d = result.to_dict()
        assert d["photoId"] == 7
        assert d["sourceKeyword"] == SOURCE_CAPTURE
        assert d["version"] == CLASSIFIER_VERSION
        assert isinstance(d["signals"], list)

    def test_version_constant(self):
        assert CLASSIFIER_VERSION == "v1"

    def test_all_source_keywords_set(self):
        # Every keyword the classifier might emit is in ALL_SOURCE_KEYWORDS
        # (the stamper uses this list to pre-create keywords).
        emitted = {
            SOURCE_CAPTURE, SOURCE_SCREENSHOT, SOURCE_RECEIVED, SOURCE_WEB,
            SOURCE_SCANNED, SOURCE_UNCLASSIFIED, SOURCE_VIDEO,
        }
        assert emitted.issubset(set(ALL_SOURCE_KEYWORDS))
