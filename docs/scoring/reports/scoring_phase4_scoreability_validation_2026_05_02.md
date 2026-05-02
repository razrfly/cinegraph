# CineGraph Phase 4 Scoreability Validation - 2026-05-02

This report validates the product `movie_scoreability_view`.

This is a baseline implementation check only. It does not change scores, refresh caches,
enqueue jobs, or call external APIs.

## View Checks

| Check | Value |
| --- | --- |
| Movies table rows | 1144666 |
| View rows | 1144666 |
| Rows with raw score | 902490 |
| 2+ lens numeric display count | 550797 |
| Distinct movie IDs | 1144666 |
| 1-lens numeric display count | 0 |
| 0-lens numeric display count | 0 |

## Scoreability Buckets

| State | Confidence | Movies | Visible scores |
| --- | --- | --- | --- |
| scoreable | high | 16,886 | 16,886 |
| scoreable | medium | 31,670 | 31,670 |
| limited | low | 247,965 | 247,965 |
| limited | medium | 254,276 | 254,276 |
| insufficient_evidence | insufficient | 593,869 | 0 |

## Threshold Comparison

Phase 3 expected the 2+ lens visible count to be close to 550,797 on the restored production snapshot.
Differences are expected if the database snapshot or score cache changed.

| Threshold | Visible rows | Visible % |
| --- | --- | --- |
| 0+ lenses | 550,797 | 48.120 |
| 2+ lenses | 550,797 | 48.120 |
| 3+ lenses | 302,832 | 26.460 |
| 4+ lenses | 48,556 | 4.240 |

## Sample Rows

| Movie | Year | Raw score | Display score | Lenses | State | Confidence | Hidden reason |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Nahual | 2025 | 0.100 | n/a | 1 | insufficient_evidence | insufficient | not_enough_evidence |
| Miami Vice | 2027 | 1.000 | n/a | 1 | insufficient_evidence | insufficient | not_enough_evidence |
| Ramayana: Part One | 2026 | 0.400 | n/a | 1 | insufficient_evidence | insufficient | not_enough_evidence |
| Bride of Death | 1912 | 0.100 | n/a | 1 | insufficient_evidence | insufficient | not_enough_evidence |
| Parthiban Kanavu | 1960 | 0.300 | n/a | 1 | insufficient_evidence | insufficient | not_enough_evidence |
| Night Carnage | 2025 | 0.900 | 0.900 | 3 | limited | medium | none |
| Vultures | 2025 | 0.900 | 0.900 | 3 | limited | medium | none |
| GATAO: Big Brothers | 2025 | 1.000 | 1.000 | 3 | limited | medium | none |
| They Were Witches | 2025 | 0.700 | 0.700 | 3 | limited | medium | none |
| Captain Avispa | 2024 | 0.700 | 0.700 | 3 | limited | medium | none |
| Bugonia | 2025 | 6.300 | 6.300 | 6 | scoreable | high | none |
| Ballad of a Small Player | 2025 | 2.800 | 2.800 | 4 | scoreable | medium | none |
| A Working Man | 2025 | 3.200 | 3.200 | 5 | scoreable | high | none |
| Now You See Me 2 | 2016 | 3.600 | 3.600 | 5 | scoreable | high | none |
| Dead of Winter | 2025 | 3.500 | 3.500 | 5 | scoreable | high | none |

## Acceptance Checks

- 0-lens numeric display count must be `0`.
- 1-lens numeric display count must be `0`.
- 2+ lens numeric display count should be close to the Phase 3 production snapshot if the DB snapshot is unchanged.
- `scoreable` and `limited` rows may expose `cinegraph_display_score`.
- `insufficient_evidence` rows must not expose `cinegraph_display_score`.
