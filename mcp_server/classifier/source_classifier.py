"""v1 rule-based source classifier for the Phase 3 stamper.

Maps photos to source-taxonomy classes per
``toolkit-lightroom-notes-source-taxonomy.md``. Pure-Python — no LR dep.

Precedence (taxonomy doc Open Question 1, locked for v1):

    1. video extension       → source:video        (v1 placeholder per Video v1 Policy)
    2. scanner software tag  → source:scanned
    3. screenshot filename   → source:screenshot
    4. EXIF Make/Model       → source:capture
    5. messaging-dir path    → source:received
    6. download-dir path     → source:web
    7. otherwise             → source:unclassified

Note: the existing user-facing convention "no source keyword = real photo"
is extended in v1 with an explicit ``source:capture`` keyword. The classifier
needs every class to leave a stamp so the idempotency predicate
(``source:* + classifier:vN``) can reliably skip done work.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import Optional, Union

CLASSIFIER_VERSION = "v1"

# Source-taxonomy keyword names. Flat, colon-namespaced — matches existing
# catalog convention (source:from-cd, source:scanned, source:unclassified).
SOURCE_CAPTURE = "source:capture"
SOURCE_SCREENSHOT = "source:screenshot"
SOURCE_RECEIVED = "source:received"
SOURCE_WEB = "source:web"
SOURCE_SCANNED = "source:scanned"
SOURCE_UNCLASSIFIED = "source:unclassified"
SOURCE_VIDEO = "source:video"

# Every keyword the stamper must ensure exists. Pre-creation is one warmup
# pass at the start of the run.
ALL_SOURCE_KEYWORDS = (
    SOURCE_CAPTURE,
    SOURCE_SCREENSHOT,
    SOURCE_RECEIVED,
    SOURCE_WEB,
    SOURCE_SCANNED,
    SOURCE_UNCLASSIFIED,
    SOURCE_VIDEO,
)


# Video extensions cover the Video v1 Policy short-circuit. fileFormat=VIDEO
# from LrC is the primary signal; extension is a fallback if metadata is sparse.
VIDEO_EXTENSIONS = frozenset({
    ".mp4", ".mov", ".m4v", ".mts", ".m2ts", ".mkv", ".avi", ".mxf",
    ".webm", ".3gp", ".wmv", ".flv",
})

# Scanner software tags. EXIF Software field substring match (case-insensitive).
SCANNER_SOFTWARE_TOKENS = (
    "vuescan", "silverfast", "epson scan", "canoscan", "lasersoft",
    "nikon scan", "minolta scan", "scangear", "imageacquire",
    "hp scan", "brother iprint", "windows fax and scan",
)

# Path-based signals. Substring match against the normalized lowercase path.
MESSAGING_DIR_TOKENS = (
    "/whatsapp", "/telegram", "/signal", "/viber", "/messenger",
    "/wechat", "/kakaotalk", "/line/", "/skype", "/slack",
    "/discord", "/teams", "/messages",
)
DOWNLOAD_DIR_TOKENS = (
    "/downloads/", "/downloaded/", "/saved pictures/", "/saved photos/",
    "/instagram/", "/facebook/", "/twitter/", "/pinterest/",
    "/browser downloads/",
)


# Filename pattern: leading "Screenshot" / "Screen Shot" / "screen-shot".
# Anchored to start to avoid matching files named like "Hawaii Screenshot.jpg".
_SCREENSHOT_FILENAME_RE = re.compile(
    r"^screen[\s_-]*shot[\s_\-:.]",
    re.IGNORECASE,
)


@dataclass
class CandidatePhoto:
    """Input shape from the Lua walker. Field names mirror what
    ``getCandidatesForClassification`` returns."""
    photo_id: Union[int, str]
    path: str = ""
    filename: str = ""
    file_format: Optional[str] = None
    make: Optional[str] = None
    model: Optional[str] = None
    software: Optional[str] = None
    width: Optional[int] = None
    height: Optional[int] = None

    @classmethod
    def from_dict(cls, d: dict) -> "CandidatePhoto":
        return cls(
            photo_id=d.get("id") if d.get("id") is not None else d.get("photoId"),
            path=d.get("path") or "",
            filename=d.get("filename") or "",
            file_format=d.get("fileFormat"),
            make=d.get("cameraMake"),
            model=d.get("cameraModel"),
            software=d.get("software"),
            width=d.get("width"),
            height=d.get("height"),
        )


@dataclass
class Classification:
    photo_id: Union[int, str]
    source_keyword: str
    version: str = CLASSIFIER_VERSION
    signals: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "photoId": self.photo_id,
            "sourceKeyword": self.source_keyword,
            "version": self.version,
            "signals": list(self.signals),
        }


def _is_video(c: CandidatePhoto) -> bool:
    if c.file_format and c.file_format.upper() == "VIDEO":
        return True
    name = c.filename or os.path.basename(c.path or "")
    ext = os.path.splitext(name)[1].lower()
    return ext in VIDEO_EXTENSIONS


def _is_scanner(c: CandidatePhoto) -> bool:
    if not c.software:
        return False
    s = c.software.lower()
    return any(token in s for token in SCANNER_SOFTWARE_TOKENS)


def _is_screenshot(c: CandidatePhoto) -> bool:
    name = c.filename or os.path.basename(c.path or "")
    if not name:
        return False
    if _SCREENSHOT_FILENAME_RE.match(name):
        return True
    # MacOS "Screen Shot 2024-..." and similar variants caught by anchored regex.
    # Looser fallback: filename contains "screenshot" as a token.
    lower = name.lower()
    if "screenshot" in lower or "screen shot" in lower:
        return True
    return False


def _is_capture(c: CandidatePhoto) -> bool:
    if c.make and c.make.strip():
        return True
    if c.model and c.model.strip():
        return True
    return False


def _path_has_token(c: CandidatePhoto, tokens) -> bool:
    if not c.path:
        return False
    p = c.path.lower().replace("\\", "/")
    return any(t in p for t in tokens)


def classify_one(c: CandidatePhoto) -> Classification:
    """Classify a single photo. Precedence order is load-bearing — see
    module docstring for the locked v1 ordering."""
    signals: list[str] = []

    if _is_video(c):
        signals.append("video-extension")
        return Classification(c.photo_id, SOURCE_VIDEO, signals=signals)

    if _is_scanner(c):
        signals.append(f"scanner-software:{c.software}")
        return Classification(c.photo_id, SOURCE_SCANNED, signals=signals)

    if _is_screenshot(c):
        signals.append("screenshot-filename")
        return Classification(c.photo_id, SOURCE_SCREENSHOT, signals=signals)

    if _is_capture(c):
        signals.append(f"exif-camera:{(c.make or '').strip()}/{(c.model or '').strip()}")
        return Classification(c.photo_id, SOURCE_CAPTURE, signals=signals)

    if _path_has_token(c, MESSAGING_DIR_TOKENS):
        signals.append("messaging-dir")
        return Classification(c.photo_id, SOURCE_RECEIVED, signals=signals)

    if _path_has_token(c, DOWNLOAD_DIR_TOKENS):
        signals.append("download-dir")
        return Classification(c.photo_id, SOURCE_WEB, signals=signals)

    signals.append("no-strong-signal")
    return Classification(c.photo_id, SOURCE_UNCLASSIFIED, signals=signals)


def classify_batch(
    candidates: list,
) -> list[Classification]:
    """Classify a batch. Conforms to the cross-cutting #1 contract in
    Phase 3 strategy: the stamper is dumb about classifier internals."""
    out: list[Classification] = []
    for c in candidates:
        cp = c if isinstance(c, CandidatePhoto) else CandidatePhoto.from_dict(c)
        out.append(classify_one(cp))
    return out
