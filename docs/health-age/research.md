# Health Age Estimate: research notes

**Experimental. Initial research inventory, not a validated model or a systematic evidence review.** Sources reviewed on 2026-10-10.

## Public WHOOP Healthspan inputs

WHOOP's [Healthspan introduction](https://www.whoop.com/us/en/thelocker/healthspan/) identifies nine contributors. Cardio zone time is split into two contributors:

| Contributor | Availability question for OpenStrap Edge |
| --- | --- |
| Sleep duration | Are sleep periods available, and how are naps and incomplete nights handled? |
| Sleep consistency | Are sleep/wake timestamps reliable enough to define an independent consistency metric? |
| Daily steps | Are validated step counts available, rather than merely raw movement samples? |
| Time in heart rate zones 1–3 | Are heart rate coverage and the zone definitions known? |
| Time in heart rate zones 4–5 | Can higher-intensity time be distinguished reliably from sensor artifacts? |
| Strength activity time | Are activity labels and durations recorded or supplied by the user? |
| VO₂ max | Is there a documented estimate or measured value with source and date? |
| Resting heart rate | Is there a reproducible resting measurement definition and sufficient coverage? |
| Lean body mass | Is body composition supplied by a suitable external measurement, with units and date? |

These are public descriptions of WHOOP's product, not confirmed OpenStrap Edge capabilities. Do not assume that WHOOP 4.0 raw band data exposes official-app derived metrics. Lean mass and VO₂ max must remain unavailable unless a credible source exists; neither should be fabricated from unrelated signals.

## What is public, and what is proprietary

The exact WHOOP formula is proprietary and is not publicly available as a complete reproducible implementation specification. This does not mean that WHOOP publishes no methodology: its [Healthspan white paper overview](https://www.whoop.com/us/en/thelocker/Healthspan-Data-Meets-Longevity/) describes a mortality-risk framework and accounting for overlapping contributors, and links to a white paper with further detail. Review that paper before making more specific claims about what is disclosed.

This project will develop and document its own approach. It will not infer hidden weights from screenshots, copy age-impact values, or present agreement with official output as proof of validity.

## Research directions

The following are starting points. Associations at the population level do not establish causation or a valid conversion into an individual's “years.” No age weights or thresholds have been selected.

| Direction | Starting evidence or investigation | Limitation to resolve |
| --- | --- | --- |
| Sleep duration and regularity | [Windred et al., 2024: prospective cohort study of sleep regularity and mortality](https://pubmed.ncbi.nlm.nih.gov/37738616/) | Check population, measurement method, confounding, and whether local sleep summaries can support comparable definitions. |
| Steps and activity volume | [Paluch et al., 2022: meta-analysis of 15 cohorts](https://pubmed.ncbi.nlm.nih.gov/35247352/) | Investigate age-dependent, nonlinear associations and device differences; avoid a universal step target. |
| Cardiorespiratory fitness | [Laukkanen et al., 2022: meta-analysis of objectively assessed fitness and mortality](https://pubmed.ncbi.nlm.nih.gov/35562197/) | Evidence for assessed fitness does not automatically validate a wearable VO₂ max estimate or an age conversion. |
| Cardio zones and resting heart rate | Investigate intensity definitions, resting measurement protocols, and relevant longitudinal studies. | Medication, illness, training status, and heart rate artifacts can change interpretation. Evidence review remains pending. |
| Strength activity and lean mass | Investigate resistance-training evidence, functional strength, and body-composition measurement methods. | Training minutes do not directly measure strength; lean mass is not interchangeable with muscle function. Evidence review remains pending. |
| Model design and measurement reliability | Investigate reference populations, independent validation, calibration, sensor accuracy, and missing-data effects. | Steps, cardio time, VO₂ max, and resting heart rate may overlap. Adding separate benefits can double-count related signals. |

For each candidate study, record population, design, exposure definition, effect uncertainty, adjustments, applicability to wearable data, and limitations before adopting a rule. Directional insights should cite an applicable source and acknowledge uncertainty.

## Open questions

- Which metrics actually exist in the fork, and which are raw, locally derived, manually entered, or unavailable? What does WHOOP 4.0 support through this app?
- What observation windows, valid-day rules, freshness limits, and timezone handling can the data support? How should gaps and interrupted wear be explained?
- Is any age model defensible and independently testable for the intended users? Would factor summaries remain more useful than an age number?
- Which reference populations and age ranges are appropriate? How should applicability be assessed across sex, fitness level, disability, chronic conditions, and medications?
- How can correlated inputs be handled without counting the same signal repeatedly? What independent outcome would validate a combined model?
- How should uncertainty from measurement, missingness, and model error be communicated separately? A coverage label alone cannot answer this.
- What sensitivity and stability criteria should a future age model meet before displaying numerical age and age difference?

See [v0 boundaries](README.md) and the [validation plan](progress.md). These questions remain open research work; they are not grounds for inventing fallback data or a provisional age formula.
