# Health Age Estimate

**Experimental — documentation and research stage. No module or age model has been implemented or validated.**

Health Age Estimate is a proposed OpenStrap Edge module for explaining how available sleep, activity, and fitness observations relate to health and fitness. It would process data locally and expose its sources, assumptions, and limitations. It is an independent project, inspired by the idea of making long-term habits easier to understand.

## Why it is useful

A transparent summary could help users understand their available wearable data, spot sustained changes, and identify gaps in measurement. The aim is directionally useful insights rather than an apparently precise number that the evidence cannot support. Owning a compatible band does not establish that every required metric is available through OpenStrap Edge.

## Intended experience

The eventual module should show:

- Actual (chronological) age, supplied by the user or an existing profile when available.
- Estimated health/fitness age and its difference from actual age, only after a defensible model has been selected and validated.
- Confidence in that estimate, with an explanation of its limitations.
- Available contributing factors: sleep duration and consistency, steps, cardio zone time, resting heart rate, VO₂ max, strength activity, and lean mass.

An estimate would be a model-dependent summary, not a measurement of biological age. A factor breakdown must not assign invented year adjustments to individual metrics.

## Small, safe v0

The first implementation should summarize available factors and their data coverage. Numerical estimated age and age difference are **deferred**; display them as unavailable with an explanation that the model is not yet validated. If actual age is missing, leave it unavailable too.

- Audit the app's data first, then use only metrics with known provenance, units, and observation dates.
- Show available values, observation windows, freshness, and gaps. Distinguish measured, derived, and manually entered values.
- Keep missing metrics explicitly unavailable. Never substitute zero, a population average, or an inferred value presented as a measurement.
- Explain coverage and measurement limitations in plain language. Coverage is not statistical confidence in a health-age estimate; age-estimate confidence is unavailable in v0.
- Keep computation local. No automatic upload or official-app dependency is part of v0.
- Label the experience experimental and link to its methodology and limitations.

This documentation does not assert that the app already provides any of these inputs. The workspace was empty when it was inspected on 2026-10-10; implementation requires an audit of the actual fork.

## What it must not claim

- Do not name this module “WHOOP Age,” use WHOOP branding for it, or imply affiliation or endorsement.
- Do not claim to reproduce WHOOP's exact proprietary formula. Public inputs and methodology disclosures are background research, not a complete implementation specification.
- Do not claim medical validity, diagnosis, lifespan prediction, measured biological age, or proven reversal of aging.
- Do not promise a particular number of years gained or lost from a behavior, equate correlation with causation, or imply that more exercise or lower resting heart rate is always better.
- Do not report precise age values, confidence percentages, or certainty unsupported by validation.

See [research notes](research.md) for sources and unresolved questions, and [progress](progress.md) for decisions, next steps, and validation planning.
