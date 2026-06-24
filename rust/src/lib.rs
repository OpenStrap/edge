// osc_edge — C-ABI glue exposing the OpenStrap Rust core (decoder + analytics) to
// Flutter via dart:ffi. ONE entry point: `osc_call(name, json_in) -> json_out`, plus
// `osc_free`. Same Rust source the cloud compiles to wasm — here it's native FFI.
//
// (flutter_rust_bridge is the alternative binding; we use a hand-written C-ABI so the
// build needs no codegen toolchain and is verifiable headless. See HANDOFF for the
// frb migration path if codegen is preferred.)
use openstrap_core as analytics;
use openstrap_protocol as protocol;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

/// Route a JSON request to the right core function. Returns JSON (or {"error":...}).
fn dispatch(name: &str, json: &str) -> String {
    match name {
        // ── protocol: decode (raw hex → decoded JSON) ──
        "decode_r24" => protocol::decode_r24(json),
        "decode_record" => protocol::decode_record(json),
        "realtime_rr" => protocol::realtime_rr(json),
        "frame_accel" => protocol::frame_accel(json),

        // ── analytics: minute family ──
        "calc_strain" => analytics::calc_strain(json),
        "calc_resting_hr" => analytics::calc_resting_hr(json),
        "calc_hr_zones" => analytics::calc_hr_zones(json),
        "calc_calories" => analytics::calc_calories(json),
        "calc_sleep" => analytics::calc_sleep(json),
        "calc_sleep_periods" => analytics::calc_sleep_periods(json),
        "stage_hypnogram" => analytics::stage_hypnogram(json),
        "calc_sleep_regularity" => analytics::calc_sleep_regularity(json),
        "detect_sessions" => analytics::detect_sessions(json),
        "calc_baselines" => analytics::calc_baselines(json),
        "calc_nocturnal_heart" => analytics::calc_nocturnal_heart(json),
        "calc_restlessness" => analytics::calc_restlessness(json),
        "calc_sleep_stress" => analytics::calc_sleep_stress(json),
        "calc_steps" => analytics::calc_steps(json),
        "calc_circadian" => analytics::calc_circadian(json),
        "stage_sleep" => analytics::stage_sleep(json),
        "detect_wake_state" => analytics::detect_wake_state(json),
        "peek_recent_state" => analytics::peek_recent_state(json),
        "detect_sleep_cycles" => analytics::detect_sleep_cycles(json),

        // ── analytics: HRV / recovery / stress / illness ──
        "time_domain_hrv" => analytics::time_domain_hrv(json),
        "freq_domain_hrv" => analytics::freq_domain_hrv(json),
        "baevsky_stress_index" => analytics::baevsky_stress_index(json),
        "calc_hrv_stability" => analytics::calc_hrv_stability(json),
        "calc_irregular" => analytics::calc_irregular(json),
        "calc_daytime_hrv" => analytics::calc_daytime_hrv(json),
        "calc_recovery" => analytics::calc_recovery(json),
        "calc_hr_recovery" => analytics::calc_hr_recovery(json),
        "calc_stress" => analytics::calc_stress(json),
        "calc_illness" => analytics::calc_illness(json),
        "calc_anomaly" => analytics::calc_anomaly(json),
        "calc_readiness_index" => analytics::calc_readiness_index(json),
        "calc_cycle" => analytics::calc_cycle(json),
        "calc_spo2_index" => analytics::calc_spo2_index(json),
        "calc_desaturation" => analytics::calc_desaturation(json),

        // ── analytics: load / fitness / trends ──
        "calc_load" => analytics::calc_load(json),
        "calc_fitness_model" => analytics::calc_fitness_model(json),
        "calc_monotony" => analytics::calc_monotony(json),
        "calc_fitness_trend" => analytics::calc_fitness_trend(json),
        "calc_vo2max" => analytics::calc_vo2max(json),

        // ── analytics: HAR / sessions ──
        "extract_har_features" => analytics::extract_har_features(json),
        "classify_activity" => analytics::classify_activity(json),
        "segment_workout" => analytics::segment_workout(json),

        // ── analytics: coach / notifications ──
        "build_coach" => analytics::build_coach(json),
        "build_notifications" => analytics::build_notifications(json),

        // ── hz1 (1 Hz-native family) ──
        "calc_dc_ac" => analytics::calc_dc_ac(json),
        "calc_long_term_hrv" => analytics::calc_long_term_hrv(json),
        "calc_hr_asymmetry" => analytics::calc_hr_asymmetry(json),
        "calc_cvhr" => analytics::calc_cvhr(json),
        "calc_circadian_hrv" => analytics::calc_circadian_hrv(json),
        "calc_sleep_regularity_index" => analytics::calc_sleep_regularity_index(json),

        // ── frontier (Batch 1 insight metrics) ──
        "detect_meals" => analytics::detect_meals(json),
        "calc_af_burden" => analytics::calc_af_burden(json),
        "calc_coherence" => analytics::calc_coherence(json),
        "calc_alcohol_signature" => analytics::calc_alcohol_signature(json),
        "calc_acclimatization" => analytics::calc_acclimatization(json),
        "calc_recovery_debt" => analytics::calc_recovery_debt(json),
        "calc_light_hygiene" => analytics::calc_light_hygiene(json),
        "calc_orthostatic" => analytics::calc_orthostatic(json),

        other => format!("{{\"error\":\"unknown fn: {}\"}}", other.replace('"', "'")),
    }
}

/// C-ABI: name + JSON in (NUL-terminated UTF-8) → JSON out (caller must osc_free).
/// Never unwinds across the boundary; returns {"error":...} on bad input/panic.
#[no_mangle]
pub extern "C" fn osc_call(name: *const c_char, json: *const c_char) -> *mut c_char {
    let res = std::panic::catch_unwind(|| {
        let name = unsafe { cstr(name) };
        let json = unsafe { cstr(json) };
        dispatch(&name, &json)
    })
    .unwrap_or_else(|_| "{\"error\":\"panic in core\"}".to_string());
    CString::new(res).unwrap_or_else(|_| CString::new("{\"error\":\"nul\"}").unwrap()).into_raw()
}

/// Free a string returned by osc_call.
#[no_mangle]
pub extern "C" fn osc_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CString::from_raw(ptr)) };
    }
}

unsafe fn cstr(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    CStr::from_ptr(p).to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dispatch_decode_and_hrv() {
        // a real R24 inner frame (from whoop_hist) decodes to a known HR.
        let out = dispatch("decode_r24", "2f1805f13ced01c261d2698848805454016202d802f5010000000000609f0fff80de233d3dda19be5c87a9be7b14803f0020dc463dda19be5c87a9be7b14803f16028402bc0286025e01000b010c020c0000000000370001510c000000000000");
        assert!(out.contains("\"hr\""), "decode out: {}", out);
        let hrv = dispatch("time_domain_hrv", r#"{"rr":[800,820,800,820,800,820,800,820,800,820,800,820,800,820,800,820,800,820,800,820,800,820]}"#);
        assert!(hrv.contains("\"rmssd\":20"), "hrv out: {}", hrv);
        assert!(dispatch("nope", "{}").contains("unknown fn"));
    }
}
