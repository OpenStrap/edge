# Health Age Estimate: progress

Last updated: 2026-10-10.

## Current status

Documentation and initial source review only. No application code, age model, participant recruitment, data collection, or user validation has been completed. The inspected workspace was empty before these documents were added, so the actual fork's metrics and hardware support remain unverified.

The [module overview](README.md) defines the intended experience and v0 boundary. [Research notes](research.md) collect public WHOOP inputs, initial literature, and unresolved questions.

## Decisions made

- Use the independent name **Health Age Estimate** and label it experimental.
- Prefer transparent, locally processed factor summaries over unsupported precision.
- Start v0 with available factors and data coverage. Defer numerical health/fitness age and age difference until a defensible model is validated.
- Show actual age only when supplied; do not infer it from physiological signals.
- Keep missing data unavailable and identify provenance, observation dates, and measurement limitations.
- Distinguish data coverage from confidence in an age model. Do not assign an age-confidence percentage in v0.
- Use WHOOP's public materials as background, without claiming affiliation or reproduction of its proprietary algorithm.
- Keep this contribution documentation-only. Do not modify application code or the root README, and do not commit yet.

## Next steps

1. Inspect the actual Flutter fork and map each candidate metric to its source, units, timestamps, coverage, derivation, and hardware support. Explicitly record unavailable inputs.
2. Expand the evidence review, including the linked WHOOP white paper, sensor reliability, strength activity, resting heart rate, and body composition. Document where evidence does and does not apply to local measurements.
3. Specify a small local factor-summary prototype using only verified inputs. Define observation windows and coverage rules from the audited data before implementation.
4. Run the pilot below after the prototype exists, recording its version, results, limitations, and resulting changes.
5. Revisit numerical age only if an independent model, suitable reference data, uncertainty method, and validation criteria can be justified. Otherwise retain factor summaries.

## Validation plan with real WHOOP users

This is a proposed feasibility and usability pilot, not clinical validation. Target 5–10 consenting adults with varied activity levels and wear consistency, including WHOOP 4.0 users where supported. A small convenience sample cannot establish population-wide age accuracy.

### Collection and comparison

- Ask participants to voluntarily share only the minimum de-identified observations needed for comparison. Do not request account credentials, full birth dates, or unrelated health records.
- Before collection, explain the purpose, fields, storage, access, retention/deletion schedule, and withdrawal process. Keep raw participant records out of the public repository; publish only consented aggregate findings.
- Compare local summaries with participant-provided official-app summaries for matching dates, timezones, units, and aggregation windows. Record metric definitions, device/model, app versions, missing days, and manual inputs so differences are interpretable.
- Include normal wear, interrupted wear, missing factors, and stale manual measurements when present. Do not ask participants to change medication, exercise, or sleep for the pilot.
- Record official Healthspan output only if a participant has access and chooses to share it. It is an optional comparator, not ground truth or a target to reverse-engineer.

### Evaluation and acceptance

- Check provenance and coverage: every displayed factor must trace to an available input; absent factors must remain unavailable. Report observed discrepancies and their likely causes rather than hiding them in a combined score.
- Check reproducibility: the same inputs and prototype version must produce the same summaries. Inspect sensitivity to incomplete days, timezone boundaries, and outliers before interpreting trends.
- Check comprehension: ask each participant to explain the experimental label, missing-data indicators, and the distinction between coverage and confidence. Record misunderstandings and revise wording before wider release.
- Check the v0 boundary: numerical health age, age difference, and age-estimate confidence must remain unavailable. No fabricated values or unsupported year adjustments may appear.
- Report participant count, data completeness, comparison limitations, discrepancies, and unresolved issues. Set metric-specific agreement tolerances after definitions are audited and before evaluating the pilot; do not retrofit tolerances to observed results.

Any later numerical age model needs a separate validation design with independent reference data, prespecified calibration and uncertainty criteria, and subgroup evaluation. Matching WHOOP output or finding a prototype understandable does not establish a valid health-age estimate.
