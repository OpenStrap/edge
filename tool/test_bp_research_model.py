#!/usr/bin/env python3
"""Math-only tests for tool/bp_research_model.py.

Synthetic data here verifies MATHEMATICS (Kalman recursion, feature math,
session aggregation, prequential discipline, causal level-B gating, fair
baselines) — it claims NO physiological validity and is never used as
evidence of medical accuracy.

Run:  python3 tool/test_bp_research_model.py
"""
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
import bp_research_model as m


def approx(a, b, tol=1e-9):
    assert abs(a - b) <= tol, f"{a} != {b}"


def _row(t, sys_, dia, hr=70.0, rm=40.0, sess=None, q="ok", cov=1.0):
    return m.Row(t, sys_, dia, hr, rm, sess, q, cov)


def test_features():
    # z = [1, (H-60)/20, (ln(V+eps) - ln(40+eps))]
    z = m.features(80.0, 40.0)
    approx(z[0], 1.0)
    approx(z[1], 1.0)
    approx(z[2], 0.0, 1e-6)
    # Missing data never becomes a zero feature.
    assert m.features(None, 40.0) is None
    assert m.features(80.0, None) is None
    assert m.features(80.0, 0.0) is None  # RMSSD 0 = absent, not ln(0)
    # NaN and infinities are rejected, never laundered into features.
    assert m.features(float("nan"), 40.0) is None
    assert m.features(80.0, float("inf")) is None
    assert m.features(80.0, float("nan")) is None
    assert m.features(float("-inf"), 40.0) is None


def test_level_a_converges():
    mdl = m.Model.initial(120.0)
    z = m.features(70.0, 40.0)
    # Feed the same reference repeatedly: the offset must converge to it.
    for _ in range(200):
        m.update_level_a(mdl, z, 130.0, delta_days=0.01)
    approx(mdl.theta[0], 130.0, 0.5)
    # Slopes stay frozen at zero in level A.
    approx(mdl.theta[1], 0.0)
    approx(mdl.theta[2], 0.0)
    # The covariance shrinks: repeated references increase certainty.
    assert mdl.p_offset < m.DEFAULT_P0


def test_level_b_joseph():
    mdl = m.Model.initial(120.0)
    z = m.features(70.0, 35.0)
    p_before = [row[:] for row in mdl.P]
    m.update_level_b(mdl, z, 125.0, delta_days=0.1)
    # P stays symmetric positive-definite-ish under the Joseph form.
    for i in range(3):
        for j in range(3):
            approx(mdl.P[i][j], mdl.P[j][i], 1e-12)
    assert all(mdl.P[i][i] >= 0 for i in range(3))
    assert mdl.P != p_before


def test_prediction_is_recorded_before_update():
    # Prequential discipline: with ONE usable reference after calibration,
    # the recorded prediction must equal the initial calibration baseline
    # (no feature influence yet — slopes are zero at start).
    rows = [_row(0, 120.0, 80.0), _row(86_400_000, 122.0, 82.0)]
    rep = m.run(rows)
    # First usable row: prediction = theta^T z = 120 + 0 + 0 = 120.
    approx(rep["systolic"]["adaptive_cuff_offset_baseline"]["mae_mmhg"], 2.0, 0.01)


def test_level_b_runs_without_name_error():
    # 25 references with real feature variation: level B must actually
    # execute past its gate (>= 20 processed, spread in H AND L) and never
    # raise NameError.
    rows = [_row(0, 120.0, 80.0)]
    for i in range(25):
        hr = 60.0 + (i % 5) * 8.0
        rm = 25.0 + (i % 4) * 15.0
        rows.append(_row((i + 1) * 86_400_000, 120.0 + i * 0.5, 80.0,
                          hr=hr, rm=rm))
    rep = m.run(rows, level_b=True)
    assert rep["updates"]["level_b"] > 0
    assert rep["updates"]["level_a"] >= m.MIN_SLOPE_SAMPLES
    # The gate opens only after enough CAUSAL history, never from the
    # total row count of the CSV.
    assert rep["updates"]["level_b"] == len(rows) - 1 - rep["updates"]["level_a"]


def test_level_b_falls_back_without_variation():
    # Plenty of references but ZERO variation in L: the gate must stay
    # shut and every update falls back to level A, reported as such.
    rows = [_row(0, 120.0, 80.0)]
    for i in range(25):
        rows.append(_row((i + 1) * 86_400_000, 120.0, 80.0,
                          hr=60.0 + (i % 5) * 8.0, rm=40.0))
    rep = m.run(rows, level_b=True)
    assert rep["updates"]["level_b"] == 0
    assert rep["updates"]["level_a"] == 25


def test_level_b_uses_no_future_information():
    # The FIRST 19 references look exactly like a different, feature-rich
    # future — the gate must not inspect them. With only 10 references
    # total, level B can never open even though the CSV is full of spread.
    rows = [_row(0, 120.0, 80.0)]
    for i in range(10):
        rows.append(_row((i + 1) * 86_400_000, 120.0 + i, 80.0,
                          hr=60.0 + i * 5, rm=25.0 + i * 10))
    rep = m.run(rows, level_b=True)
    assert rep["updates"]["level_b"] == 0
    assert rep["updates"]["level_a"] == 10
    # And the predictions of the first targets are IDENTICAL with and
    # without --level-b requested: the flag must not change the past.
    rep2 = m.run(rows, level_b=False)
    a = rep["systolic"]["adaptive_cuff_offset_baseline"]
    b = rep2["systolic"]["adaptive_cuff_offset_baseline"]
    assert a["mae_mmhg"] == b["mae_mmhg"]


def test_quality_exclusion():
    # 'pending' and 'no_data' captures are excluded by the admission rule
    # and reported; 'gappy' is admitted.
    rows = [_row(0, 120.0, 80.0, q="ok"),
            _row(86_400_000, 121.0, 81.0, q="pending"),
            _row(2 * 86_400_000, 122.0, 82.0, q="no_data"),
            _row(3 * 86_400_000, 123.0, 83.0, q="gappy")]
    rep = m.run(rows)
    assert rep["rows_excluded_quality"] == 2
    # Admitted: the 'ok' calibration row and the 'gappy' target.
    assert rep["systolic"]["adaptive_cuff_offset_baseline"]["n"] == 1


def test_level_b_handover_happens_once_in_run():
    # END-TO-END: level-A updates run first (gate shut), the gate opens
    # causally, the hand-over happens EXACTLY ONCE, and the FIRST
    # level-B update runs on P[0][0] = the p_offset level A actually
    # learned — not the initial DEFAULT_P0.
    rows = [_row(0, 120.0, 80.0)]
    for i in range(25):
        hr = 60.0 + (i % 5) * 8.0
        rm = 25.0 + (i % 4) * 15.0
        rows.append(_row((i + 1) * 86_400_000, 120.0 + i * 0.5, 80.0,
                          hr=hr, rm=rm))
    rep = m.run(rows, level_b=True)
    u = rep["updates"]
    assert u["level_b_requested"] is True
    assert u["level_b_started"] is True
    assert u["level_b"] == 25 - m.MIN_SLOPE_SAMPLES
    assert u["level_a"] == m.MIN_SLOPE_SAMPLES
    # The hand-over fired after exactly MIN_SLOPE_SAMPLES processed refs.
    assert u["level_b_started_after_refs"] == m.MIN_SLOPE_SAMPLES
    assert u["level_b_fallback_reason"] is None


def test_level_b_p_offset_carries_into_level_b():
    # The hand-over must carry the LEARNED p_offset: after many level-A
    # updates the offset covariance is far below DEFAULT_P0, so P[0][0]
    # at hand-over must be that learned value.
    mdl = m.Model.initial(120.0)
    z = m.features(70.0, 40.0)
    for _ in range(100):
        m.update_level_a(mdl, z, 128.0, delta_days=0.01)
    handed = m.Model.hand_over_to_level_b(mdl)
    assert handed.P[0][0] == mdl.p_offset
    assert handed.P[0][0] < m.DEFAULT_P0


def test_mixed_session_quality_excludes_the_session():
    # 'ok + pending' in ONE session: the whole session is excluded —
    # never silently admitted through a None -> "" back door.
    rows = [_row(0, 120.0, 80.0),
            _row(60_000, 122.0, 82.0, sess="s1", q="ok"),
            _row(120_000, 124.0, 84.0, sess="s1", q="pending")]
    rep = m.run(rows)
    assert rep["rows_excluded_quality"] == 1
    assert rep["systolic"]["adaptive_cuff_offset_baseline"]["n"] == 0


def test_all_admitted_session_quality_stays_admitted():
    rows = [_row(0, 120.0, 80.0),
            _row(60_000, 122.0, 82.0, sess="s1", q="ok"),
            _row(120_000, 124.0, 84.0, sess="s1", q="gappy")]
    rep = m.run(rows)
    assert rep["rows_excluded_quality"] == 0
    # The aggregate carries the worst ADMITTED status ('gappy').
    assert rep["systolic"]["adaptive_cuff_offset_baseline"]["n"] == 1


def test_unknown_quality_is_excluded_by_default():
    rows = [_row(0, 120.0, 80.0, q="ok"),
            _row(86_400_000, 121.0, 81.0, q=None)]
    rep = m.run(rows)
    assert rep["rows_excluded_quality"] == 1
    assert rep["admission_rule"]["unknown_quality_admitted"] is False


def test_unknown_quality_admitted_only_in_compatibility_mode():
    rows = [_row(0, 120.0, 80.0, q="ok"),
            _row(86_400_000, 121.0, 81.0, q=None)]
    rep = m.run(rows, admit_missing_quality=True)
    assert rep["rows_excluded_quality"] == 0
    assert rep["admission_rule"]["unknown_quality_admitted"] is True
    assert rep["systolic"]["adaptive_cuff_offset_baseline"]["n"] == 1


def test_level_a_to_level_b_handover():
    # The documented transition: theta carries over unchanged, p_offset
    # seeds the offset diagonal of P, slopes start at DEFAULT_P0.
    mdl = m.Model.initial(120.0)
    z = m.features(70.0, 40.0)
    for _ in range(50):
        m.update_level_a(mdl, z, 128.0, delta_days=0.01)
    handed = m.Model.hand_over_to_level_b(mdl)
    assert handed.theta == mdl.theta
    assert handed.P[0][0] == mdl.p_offset
    assert handed.P[1][1] == m.DEFAULT_P0
    assert handed.P[2][2] == m.DEFAULT_P0


def test_session_aggregation():
    # Three readings of one session are NOT three independent states.
    rows = [
        _row(1000, 120.0, 80.0, sess="s1"),
        _row(60_000, 124.0, 84.0, sess="s1"),
        _row(120_000, 122.0, 82.0, sess="s1"),
    ]
    agg = m.aggregate_sessions(rows)
    assert len(agg) == 1
    approx(agg[0].sys_mmhg, 122.0)
    approx(agg[0].dia_mmhg, 82.0)


def test_session_label_conflict_keeps_references_apart():
    # The SAME session label hours apart is NOT one session: each
    # reference stays independent (no implicit day/label aggregation).
    rows = [
        _row(0, 120.0, 80.0, sess="morning"),
        _row(60_000, 121.0, 81.0, sess="morning"),
        # 6 hours later, same label: a different sitting.
        _row(6 * 3_600_000, 130.0, 90.0, sess="morning"),
    ]
    agg = m.aggregate_sessions(rows)
    assert len(agg) == 2
    approx(agg[1].sys_mmhg, 130.0)


def test_missing_features_excluded_not_zeroed():
    rows = [_row(0, 120.0, 80.0),
            # No band data: excluded, never treated as HR 0.
            _row(86_400_000, 121.0, 81.0, hr=None, rm=None, q="no_data"),
            # Quality 'ok' but the features are STILL absent: the feature
            # exclusion is what must catch this one, not the quality rule.
            _row(2 * 86_400_000, 122.0, 82.0, hr=None, rm=None, q="ok")]
    rep = m.run(rows)
    assert rep["rows_excluded_quality"] == 1
    assert rep["rows_excluded_no_features"] == 1
    # The only post-calibration target had no features: nothing is left to
    # evaluate — an honest n = 0, not a fabricated prediction.
    assert rep["systolic"]["adaptive_cuff_offset_baseline"]["n"] == 0


def test_fair_baseline_target_sets():
    # All models are evaluated on the SAME targets: identical n across
    # last-cuff, cuff-mean and the model.
    rows = [_row(0, 120.0, 80.0)]
    for i in range(8):
        rows.append(_row((i + 1) * 86_400_000, 120.0 + i, 80.0 + i * 0.5,
                          hr=60.0 + i * 3, rm=30.0 + i * 5))
    rep = m.run(rows)
    for group in ("systolic", "diastolic"):
        ns = {k: v["n"] for k, v in rep[group].items()}
        assert len(set(ns.values())) == 1, ns
        assert all(n == 8 for n in ns.values()), ns


def test_chronological_replay():
    # Back-dated rows: the CSV order must not matter, only measured_at_ms.
    r1 = _row(86_400_000, 122.0, 82.0)
    r0 = _row(0, 120.0, 80.0)
    a = m.run([r1, r0])
    b = m.run([r0, r1])
    assert a["systolic"]["adaptive_cuff_offset_baseline"]["mae_mmhg"] == \
           b["systolic"]["adaptive_cuff_offset_baseline"]["mae_mmhg"]




# ======================================================================
# C: the compatibility mode re-admits ONLY genuinely missing quality.
# A session excluded for a KNOWN bad member (pending, no_data) carries
# the EXPLICIT EXCLUDED_MIXED status and stays excluded in every mode.
# ======================================================================

def test_ok_pending_session_stays_excluded_in_compatibility_mode():
    rows = [_row(0, 120.0, 80.0),
            _row(60_000, 122.0, 82.0, sess="s1", q="ok"),
            _row(120_000, 124.0, 84.0, sess="s1", q="pending")]
    rep = m.run(rows, admit_missing_quality=True)
    assert rep["rows_excluded_quality"] == 1
    assert rep["systolic"]["adaptive_cuff_offset_baseline"]["n"] == 0


def test_ok_no_data_session_stays_excluded_in_compatibility_mode():
    rows = [_row(0, 120.0, 80.0),
            _row(60_000, 122.0, 82.0, sess="s1", q="ok"),
            _row(120_000, 124.0, 84.0, sess="s1", q="no_data")]
    rep = m.run(rows, admit_missing_quality=True)
    assert rep["rows_excluded_quality"] == 1
    assert rep["systolic"]["adaptive_cuff_offset_baseline"]["n"] == 0


def test_ok_gappy_session_is_admitted_as_gappy_in_compatibility_mode():
    rows = [_row(0, 120.0, 80.0),
            _row(60_000, 122.0, 82.0, sess="s1", q="ok"),
            _row(120_000, 124.0, 84.0, sess="s1", q="gappy")]
    rep = m.run(rows, admit_missing_quality=True)
    assert rep["rows_excluded_quality"] == 0
    assert rep["systolic"]["adaptive_cuff_offset_baseline"]["n"] == 1


def test_all_missing_quality_session_follows_the_flag():
    # Every member genuinely lacks quality metadata (historical data):
    # excluded by default, admitted ONLY with the explicit flag.
    rows = [_row(0, 120.0, 80.0, sess="s1", q=None),
            _row(60_000, 122.0, 82.0, sess="s1", q=None)]
    rep_default = m.run(rows)
    # ONE aggregated session row (all members None) → excluded by default.
    assert rep_default["rows_excluded_quality"] == 1
    rep_compat = m.run(rows, admit_missing_quality=True)
    assert rep_compat["rows_excluded_quality"] == 0


def test_admitted_mixed_with_missing_is_conservative():
    # 'ok + genuinely missing' (no KNOWN bad member): excluded without
    # the flag; the flag admits it because nothing known is wrong.
    rows = [_row(60_000, 122.0, 82.0, sess="s1", q="ok"),
            _row(120_000, 124.0, 84.0, sess="s1", q=None)]
    rep_default = m.run(rows)
    # The two members aggregate into ONE session row, whose folded
    # quality is None (conservative) → excluded without the flag.
    assert rep_default["rows_excluded_quality"] == 1
    rep_compat = m.run(rows, admit_missing_quality=True)
    assert rep_compat["rows_excluded_quality"] == 0


def test_excluded_mixed_status_is_never_admitted():
    # The fold's explicit exclusion status itself never passes admission.
    assert m.is_admitted_quality(m.EXCLUDED_MIXED) is False
    assert m.is_admitted_quality(m.EXCLUDED_MIXED,
                                 admit_missing_quality=True) is False
    assert m.is_admitted_quality("pending") is False
    assert m.is_admitted_quality("no_data") is False


# ======================================================================
# D: no crash when nothing is admitted — a structured, parseable
# research report instead of an IndexError.
# ======================================================================

def test_empty_csv_returns_no_rows_error():
    rep = m.run([])
    assert rep["error"] == "no rows"


def test_only_pending_rows_return_no_admitted_rows():
    rows = [_row(0, 120.0, 80.0, q="pending"),
            _row(86_400_000, 121.0, 81.0, q="pending")]
    rep = m.run(rows)
    assert rep["error"] == "no admitted rows"
    assert rep["rows_total"] == 2
    assert rep["rows_excluded_quality"] == 2
    assert rep["admission_rule"]["unknown_quality_admitted"] is False


def test_only_no_data_rows_return_no_admitted_rows():
    rows = [_row(0, 120.0, 80.0, q="no_data")]
    rep = m.run(rows)
    assert rep["error"] == "no admitted rows"
    assert rep["rows_excluded_quality"] == 1


def test_only_unknown_quality_returns_no_admitted_rows():
    rows = [_row(0, 120.0, 80.0, q="weird_status")]
    rep = m.run(rows)
    assert rep["error"] == "no admitted rows"
    assert rep["rows_excluded_quality"] == 1


def test_calibration_row_then_only_excluded_still_reports():
    # One valid calibration point, then only excluded rows: no target
    # rows, but a structured report — never a crash.
    rows = [_row(0, 120.0, 80.0, q="ok"),
            _row(86_400_000, 121.0, 81.0, q="pending")]
    rep = m.run(rows)
    assert "error" not in rep
    assert rep["systolic"]["adaptive_cuff_offset_baseline"]["n"] == 0


def test_admitted_rows_without_features_report_zero_targets():
    # Admitted rows exist, but none carries usable HR/RMSSD features:
    # the report is structured, targets are zero, no exception.
    rows = [_row(0, 120.0, 80.0, q="ok"),
            _row(86_400_000, 121.0, 81.0, hr=None, rm=None, q="ok")]
    rep = m.run(rows)
    assert "error" not in rep
    assert rep["systolic"]["adaptive_cuff_offset_baseline"]["n"] == 0
    assert rep["rows_excluded_no_features"] == 1


def test_load_rows_rejects_corrupt_mandatory_numbers():
    import csv as _csv, tempfile
    bad = [
        ("measured_at_ms,systolic_mmhg,diastolic_mmhg\n,120,80\n", "empty required"),
        ("measured_at_ms,systolic_mmhg,diastolic_mmhg\nabc,120,80\n", "non-numeric"),
        ("measured_at_ms,systolic_mmhg,diastolic_mmhg\n1700000000,abc,80\n", "bad sys"),
        ("measured_at_ms,systolic_mmhg,diastolic_mmhg\n1700000000,120,\n", "empty dia"),
        ("measured_at_ms,systolic_mmhg,diastolic_mmhg\n1700000000,nan,80\n", "nan sys"),
        ("measured_at_ms,systolic_mmhg,diastolic_mmhg\n1700000000,inf,80\n", "inf sys"),
    ]
    for content, why in bad:
        with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False) as f:
            f.write(content)
            path = f.name
        try:
            try:
                m.load_rows(path)
            except m.CsvDataError:
                pass
            else:
                raise AssertionError(f"corrupt CSV accepted: {why}")
        finally:
            os.unlink(path)


def test_load_rows_rejects_invalid_timestamp():
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False) as f:
        f.write("measured_at_ms,systolic_mmhg,diastolic_mmhg\n"
                "1700000000.5,120,80\n")
        path = f.name
    try:
        try:
            m.load_rows(path)
        except m.CsvDataError:
            pass
        else:
            raise AssertionError("fractional measured_at_ms accepted")
    finally:
        os.unlink(path)


def test_load_rows_rejects_corrupt_optional_numbers():
    # A non-empty optional field that does not parse (or is nan/inf) is a
    # corrupt row, never a quiet None that would read as "no data".
    import tempfile
    bad = [
        ("1700000000,120,80,abc,40\n", "non-numeric hr"),
        ("1700000000,120,80,70,nan\n", "nan rmssd"),
        ("1700000000,120,80,70,inf\n", "inf rmssd"),
    ]
    for tail, why in bad:
        with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False) as f:
            f.write("measured_at_ms,systolic_mmhg,diastolic_mmhg,"
                    "hr_mean,rmssd_ms\n" + tail)
            path = f.name
        try:
            try:
                m.load_rows(path)
            except m.CsvDataError:
                pass
            else:
                raise AssertionError(f"corrupt optional field accepted: {why}")
        finally:
            os.unlink(path)


def test_load_rows_keeps_empty_optionals_as_none():
    # Empty optional fields are honestly missing, not corrupt.
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False) as f:
        f.write("measured_at_ms,systolic_mmhg,diastolic_mmhg,"
                "hr_mean,rmssd_ms\n1700000000,120,80,,\n")
        path = f.name
    try:
        rows = m.load_rows(path)
        assert len(rows) == 1
        assert rows[0].hr_mean is None
        assert rows[0].rmssd_ms is None
    finally:
        os.unlink(path)


def test_main_reports_corrupt_csv_structured():
    # The CLI exits 2 with a parseable JSON error report, no traceback.
    import json as _json, subprocess, tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False) as f:
        f.write("measured_at_ms,systolic_mmhg,diastolic_mmhg\n"
                "1700000000,abc,80\n")
        path = f.name
    try:
        proc = subprocess.run(
            [sys.executable, os.path.join(os.path.dirname(__file__),
                                          "bp_research_model.py"),
             "--csv", path],
            capture_output=True, text=True)
        assert proc.returncode == 2, proc.stderr
        report = _json.loads(proc.stdout)
        assert report["error"] == "corrupt csv"
        assert "systolic_mmhg" in report["detail"]
        assert "Traceback" not in proc.stderr
    finally:
        os.unlink(path)


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"PASS {name}")
    print("ALL MATH TESTS PASSED")
