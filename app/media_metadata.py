from __future__ import annotations

import math
from typing import Any, Optional


def normalize_waveform_samples(
    metadata: Optional[dict[str, Any]],
) -> list[float]:
    if metadata is None:
        return []

    value = metadata.get("waveform_samples")
    if not isinstance(value, list):
        return []

    samples: list[float] = []
    for item in value[:80]:
        if isinstance(item, bool) or not isinstance(item, (int, float)):
            continue

        sample = float(item)
        if math.isfinite(sample):
            samples.append(max(0.0, min(1.0, sample)))

    return samples
