// Presentation-only vocabulary. Never pass user-entered text or storage keys.
import 'package:flutter/widgets.dart';
import 'app_localizations.dart';

String uiText(BuildContext context, String text) =>
    localizedText(AppLocalizations.of(context), text);

String journalTagText(BuildContext context, String tag) =>
    localizedJournalTag(AppLocalizations.of(context), tag);

/// Preset journal tags are stable storage keys. Translate them only at the
/// presentation boundary so saved data, AI extraction and correlations keep
/// using the canonical English vocabulary.
String localizedJournalTag(AppLocalizations? l, String tag) {
  if (l == null) return tag;
  return switch (tag) {
    'caffeine' => l.journalTagCaffeine,
    'alcohol' => l.journalTagAlcohol,
    'late meal' => l.journalTagLateMeal,
    'stress' => l.journalTagStress,
    'poor sleep' => l.journalTagPoorSleep,
    'travel' => l.journalTagTravel,
    'screens late' => l.journalTagScreensLate,
    'meds' => l.journalTagMeds,
    'sick' => l.journalTagSick,
    'sauna' => l.journalTagSauna,
    'cold plunge' => l.journalTagColdPlunge,
    'social' => l.journalTagSocial,
    'workout' => l.journalTagWorkout,
    'rest day' => l.journalTagRestDay,
    _ => tag,
  };
}

String localizedText(AppLocalizations? l, String text) {
  if (l == null || l.localeName == 'en') return text;
  final lowScore = RegExp(
    r"^Readiness scored (\d+), its lowest band\. Taken together, that night's signals sat well on the unfavourable side of your own baseline\.$",
  ).firstMatch(text);
  if (lowScore != null) {
    return l.findingLowReadinessScoredDetail(int.parse(lowScore[1]!));
  }
  return switch (text) {
    "Resting heart rate has been raised" => l.findingIllnessTitle,
    "Your recent overnight resting heart rates add up to a rise above your own baseline: one very high night can do it, or a few slightly raised ones. This watches one signal only. It names a pattern, not a cause." =>
      l.findingIllnessDetail,
    "Low readiness" => l.findingLowReadinessTitle,
    "Readiness was in its lowest band. Taken together, that night's signals sat well on the unfavourable side of your own baseline." =>
      l.findingLowReadinessDetail,
    "Warm-up" => l.activityZonesNameWarmUp,
    "Easy" => l.activityZonesNameEasy,
    "Aerobic" => l.activityZonesNameAerobic,
    "Threshold" => l.activityZonesNameThreshold,
    "Max effort" => l.activityZonesNameMaxEffort,

    "units" => l.presentationUnits,
    "mg" => l.presentationMg,
    "ml" => l.presentationMl,
    "lb" => l.presentationLb,
    "in" => l.presentationIn,
    "Weight" => l.journalComposeWeightLabel,
    "Screens before bed" => l.presentationScreensBeforeBed,
    "Soreness" => l.presentationSoreness,
    "Alcohol" => l.presentationAlcohol,
    "Caffeine" => l.presentationCaffeine,
    "A TLW64 or NO1 F1 fitness band. Pairs and banks its raw data; nothing is derived from it yet." =>
      l.presentationATLW64OrNO1F1FitnessBandPairsAnd,
    "An SMA-Q2-OSS smartwatch. Pairs and banks its raw data; nothing is derived from it yet." =>
      l.presentationAnSMAQ2OSSSmartwatchPairsAndBanksIts,
    "An unbranded Watch9 board. Pairs and banks its raw data; nothing is derived from it yet." =>
      l.presentationAnUnbrandedWatch9BoardPairsAndBanksItsRaw,
    "An unbranded XWatch board. Pairs and banks its raw data; nothing is derived from it yet." =>
      l.presentationAnUnbrandedXWatchBoardPairsAndBanksItsRaw,
    "An unbranded ID115 board. Pairs and banks its raw data; nothing is derived from it yet." =>
      l.presentationAnUnbrandedID115BoardPairsAndBanksItsRaw,
    "An unbranded Makibes HR3 board. Pairs and banks its raw data; nothing is derived from it yet." =>
      l.presentationAnUnbrandedMakibesHR3BoardPairsAndBanksIts,
    "An unbranded DaFit/MOYOUNG-style watch. Pairs and banks its own data; nothing derives from it yet." =>
      l.presentationAnUnbrandedDaFitMOYOUNGStyleWatchPairsAndBanks,
    "Pairs and banks its raw data in the background, but does not derive anything from it yet." =>
      l.presentationPairsAndBanksItsRawDataInTheBackground,
    "A generic HPlus-family HR band. Pairs and banks its history; nothing is decoded into a number yet." =>
      l.presentationAGenericHPlusFamilyHRBandPairsAndBanks,
    "A generic ring or band sold under many storefront names. Pairs and connects; reports nothing yet." =>
      l.presentationAGenericRingOrBandSoldUnderManyStorefront,
    "Pairs and banks its raw data — nothing is decoded yet." =>
      l.presentationPairsAndBanksItsRawDataNothingIsDecoded,
    "A budget activity band. Pairs and banks its raw data, but nothing is derived from it yet." =>
      l.presentationABudgetActivityBandPairsAndBanksItsRaw,
    "The original Fossil/Skagen hybrid smartwatch, not the newer Hybrid HR. Pairs and connects; nothing derives from it yet." =>
      l.presentationTheOriginalFossilSkagenHybridSmartwatchNotTheNewer,
    "Pebble 2 or Pebble 2 SE only. Pairs only for now — nothing is read or stored yet." =>
      l.presentationPebble2OrPebble2SEOnlyPairsOnly,
    "Reads the ring directly — no account, no key exchange." =>
      l.presentationReadsTheRingDirectlyNoAccountNoKeyExchange,
    "µV" => l.presentationV,
    "s" => l.presentationS,
    "Weight (lb)" => l.presentationWeightLb,
    "Weight (kg)" => l.journalComposeWeightKgLabel,
    "Height (in)" => l.presentationHeightIn,
    "Height (cm)" => l.presentationHeightCm,
    "Energy" => l.logFoodEnergyLabel,
    "Sleep quality" => l.presentationSleepQuality,
    "Mood" => l.presentationMood,
    "MET value × your weight, refined by heart rate — or heart rate alone, for an activity that carries no MET." =>
      l.presentationMETValueYourWeightRefinedByHeartRateOr,
    "no readiness inputs present — \"—\" (never imputed)." =>
      l.presentationNoReadinessInputsPresentNeverImputed,
    "Baevsky Stress Index → 0–100; resting autonomic tension (PRV)." =>
      l.presentationBaevskyStressIndex0100RestingAutonomicTensionPRV,
    "no sleep was scored for this day — resting HR is only ever measured over a sleep window, never over waking hours." =>
      l.presentationNoSleepWasScoredForThisDayRestingHR,
    "no sleep was scored for this day — resting HR is only ever measured over a sleep window, never over waking hours" =>
      l.presentationNoSleepWasScoredForThisDayRestingHR,
    "Colmi ring" => l.presentationColmiRing,
    "Fossil/Skagen Hybrid Smartwatch" =>
      l.presentationFossilSkagenHybridSmartwatch,
    "HPlus HR band" => l.presentationHPlusHRBand,
    "Smart ring/band (Lefun protocol)" =>
      l.presentationSmartRingBandLefunProtocol,
    "WearFit band" => l.presentationWearFitBand,
    "DaFit / MOYOUNG watch" => l.presentationDaFitMOYOUNGWatch,
    "Smart ring (R11M/R10M)" => l.presentationSmartRingR11MR10M,
    "COROS watch" => l.presentationCOROSWatch,
    "Coros watch" => l.presentationCorosWatch,
    "Polar sensor" => l.presentationPolarSensor,
    "Garmin watch" => l.presentationGarminWatch,
    "Bluetooth heart rate sensor" => l.presentationBluetoothHeartRateSensor,
    "A deviation, not a temperature. Imported nights carry different units, so they are not charted together." =>
      l.supplementADeviationNotATemperaturefc109f,
    "A dose is due." => l.supplementADoseIsDue1543e3,
    "A local model can take a while to load before its first reply. Default is 5 minutes (300s). Cloud providers use a fixed 2-minute timeout and are not affected by this." =>
      l.supplementALocalModelCanTake62d4a8,
    "A low-confidence overlay: a wrist sensor cannot see slow-wave activity, so deep sleep here is heart-rate flatness inside NREM." =>
      l.supplementALowConfidenceOverlayA9fbabe,
    "A minute of notes tonight teaches OpenStrap what actually moves your recovery." =>
      l.supplementAMinuteOfNotesTonightac2cf6,
    "A possible nap is ready to review." =>
      l.supplementAPossibleNapIsReady84b3cf,
    "A possible workout is ready to review." =>
      l.supplementAPossibleWorkoutIsReady2861bb,
    "A step goal of 500–100,000 is a real one. Nothing was saved." =>
      l.supplementAStepGoalOf500f44746,
    "A weighted composite of a handful of inputs, each scored against your own history. Every input's weight, and whether last night had enough history to use it, is listed on the Readiness screen. Missing inputs are re-weighted, never zero-filled." =>
      l.supplementAWeightedCompositeOfA8941a5,
    "AASM sleep-accounting definitions" =>
      l.supplementAASMSleepAccountingDefinitions79c9d9,
    "AN-2554 pedometer · phone pedometer (HealthKit / Health Connect)" =>
      l.supplementAN2554PedometerPhonePedometer79c0a4,
    "About your bedtime — log your day" =>
      l.supplementAboutYourBedtimeLogYourb7f0e2,
    "Active energy" => l.homeActiveEnergy,
    "Add a medication" => l.supplementAddAMedicationef7260,
    "Alarm" => l.settingsAlarmRowTitle,
    "Alarm not confirmed" => l.settingsAlarmLatchFailedRowTitle,
    "Already syncing." => l.supplementAlreadySyncing7ed158,
    "Avg HR" => l.logWorkoutAvgHr,
    "Awake min" => l.supplementAwakeMin81d9ac,
    "Baevsky stress index over a resting window: a histogram measure of how tightly beat intervals cluster. There is deliberately no fallback when the resting window is missing." =>
      l.supplementBaevskyStressIndexOverA037465,
    "Band battery and charging" => l.supplementBandBatteryAndCharging0d7f7d,
    "Banister TRIMP family · log-compressed" =>
      l.supplementBanisterTRIMPFamilyLogCompressed553d36,
    "Bedtime" => l.supplementBedtimee3cb8b,
    "Blood oxygen" => l.supplementBloodOxygen8cd845,
    "Breathing rate recovered from respiratory sinus arrhythmia — the periodic modulation breathing imposes on beat timing — over a grid of candidate rates." =>
      l.supplementBreathingRateRecoveredFromRespiratory66461f,
    "Breathing variability" => l.supplementBreathingVariability99a552,
    "Calibrating" => l.homeCalibrating,
    "Calories" => l.workoutCaloriesStatLabel,
    "Cardiovascular load over the day, compressed onto a 0–21 scale." =>
      l.supplementCardiovascularLoadOverTheDayd6c4f3,
    "Charge your strap before bed" =>
      l.supplementChargeYourStrapBeforeBedcb17aa,
    "Charging" => l.supplementCharging5f99fe,
    "Coefficient of variation of per-window respiratory rate across the night." =>
      l.supplementCoefficientOfVariationOfPerc71989,
    "Cole–Kripke wake spine + HRV overlay" =>
      l.supplementColeKripkeWakeSpineHRVcd5f37,
    "Counted, never modelled. A step count comes from a gait-capable counter: the band's 100 Hz pedometer while it streams, or your phone's. Each stretch of the day is counted by whichever of the two was actually recording it, and a stretch both covered is counted once, so a session never takes the day from the sensor that carried the rest of it. There is no 1 Hz estimate — walking cadence sits above what one sample a second can resolve, so a day with no counter behind it reports no steps rather than a guess." =>
      l.supplementCountedNeverModelledAStepc66896,
    "Creatinine" => l.supplementCreatinined3029a,
    "Daily recovery readiness from your own data" =>
      l.supplementDailyRecoveryReadinessFromYourf995c0,
    "Daytime sleep" => l.healthDaytimeSleep,
    "Deep min" => l.supplementDeepMin28f1fc,
    "Deep sleep" => l.sleepDetailStageDeep,
    "Device alerts" => l.supplementDeviceAlerts608f4f,
    "Did you nap?" => l.supplementDidYouNapccbced,
    "Did you work out?" => l.supplementDidYouWorkOut9601b8,
    "Distance" => l.workoutDistanceStatLabel,
    "ENMO over a personal dynamic-range floor" =>
      l.supplementENMOOverAPersonalDynamice858c1,
    "Edit daily step goal" => l.supplementEditDailyStepGoal3f9637,
    "Elapsed time" => l.activitySummaryElapsedTime,
    "Elevated resting HR + suppressed HRV over recent nights." =>
      l.supplementElevatedRestingHRSuppressedHRVfaf9cb,
    "Empty response from provider." =>
      l.supplementEmptyResponseFromProvider2db057,
    "End the active workout." => l.supplementEndTheActiveWorkout37ce3f,
    "End workout" => l.supplementEndWorkout3e8d62,
    "Fasting glucose" => l.supplementFastingGlucose5433f3,
    "Fasting insulin" => l.supplementFastingInsulincf8459,
    "Ferritin" => l.supplementFerritin3c7c47,
    "Folate" => l.supplementFolatec66dfd,
    "Free T4" => l.supplementFreeT4f89836,
    "Goal" => l.supplementGoal9fe00a,
    "Good" => l.supplementGood61dedc,
    "HDL cholesterol" => l.supplementHDLCholesterold579f5,
    "HEALTH OBSERVATION" => l.supplementHEALTHOBSERVATION4f314b,
    "HR recovery" => l.supplementHRRecovery1b0d16,
    "HRV" => l.workoutHrvLabel,
    "HRV stability" => l.supplementHRVStabilitydfdddc,
    "Haematocrit" => l.supplementHaematocrit2a11fb,
    "Haemoglobin" => l.supplementHaemoglobinc80789,
    "Hard minutes" => l.supplementHardMinutes9feee8,
    "Health alerts" => l.supplementHealthAlerts1de231,
    "Heart rate" => l.signalHrSparse,
    "Heart-rate recovery" => l.supplementHeartRateRecoveryfdc20e,
    "Heart-rate-to-energy regression over the waking span, anchored on your weight, age and sex. An estimate, and sensitive to all three." =>
      l.supplementHeartRateToEnergyRegression1e01ee,
    "High" => l.supplementHighb1a595,
    "How far sleeping heart rate falls below the waking average." =>
      l.supplementHowFarSleepingHeartRatee471ae,
    "How was today?" => l.supplementHowWasToday812df3,
    "Hrv rmssd" => l.supplementHrvRmssdf7982b,
    "Illness, unusual physiology and temperature signals" =>
      l.supplementIllnessUnusualPhysiologyAndTemperatureda080b,
    "Imported from WHOOP" => l.supplementImportedFromWHOOPbb12b5,
    "Irregular heart rhythm — screen" =>
      l.supplementIrregularHeartRhythmScreene259c5,
    "Keytel 2005 · Harris–Benedict / Mifflin BMR floor" =>
      l.supplementKeytel2005HarrisBenedictMifflind13096,
    "LDL cholesterol" => l.supplementLDLCholesterol097ebc,
    "LF / HF" => l.investigateLfHf,
    "Last night is still being worked out." =>
      l.supplementLastNightIsStillBeinga75a55,
    "Log a workout" => l.supplementLogAWorkout6929de,
    "Log food" => l.nutritionLogFood,
    "Log how the day went" => l.supplementLogHowTheDayWent0af477,
    "Log journal" => l.supplementLogJournal7b63e0,
    "Log period" => l.supplementLogPeriod9fe2f6,
    "Low" => l.supplementLowa12494,
    "Low battery" => l.supplementLowBatteryc5b099,
    "Low readiness today" => l.supplementLowReadinessTodayfcb16c,
    "Magnesium" => l.supplementMagnesiume6a692,
    "Mark a dose" => l.supplementMarkADoseebc759,
    "Max HR" => l.workoutMaxHrStatLabel,
    "Medication" => l.supplementMedication36da83,
    "Minutes of sleep detected OUTSIDE the main night: the same wrist z-angle window detector the night uses, confirmed by a heart-rate dip. Naps are counted separately and never folded into time asleep." =>
      l.supplementMinutesOfSleepDetectedOUTSIDE0e1868,
    "Minutes whose acceleration sits above a movement floor. That floor is pooled from your own recent days once there are enough of them, and a population one before that. This is activity VOLUME, not locomotion: steps are counted by a pedometer and are never derived from it." =>
      l.supplementMinutesWhoseAccelerationSitsAbovee173ee,
    "Minutes with a band record present. The band logs to flash only while it is on a wrist, so record presence IS wear." =>
      l.supplementMinutesWithABandRecord3ca74f,
    "Moderate" => l.supplementModerateea8b09,
    "Mood, energy, stress — a minute of it." =>
      l.supplementMoodEnergyStressAMinute54d5f9,
    "Morning briefing" => l.supplementMorningBriefing0da62b,
    "Morning cortisol" => l.supplementMorningCortisolc31c55,
    "Motion coprocessor" => l.supplementMotionCoprocessord1ef3c,
    "Movement minutes" => l.supplementMovementMinutes4670da,
    "Night-to-night coefficient of variation of RMSSD." =>
      l.supplementNightToNightCoefficientOf0cae4a,
    "Nightly sweep" => l.supplementNightlySweepe95625,
    "No alarm set for tonight" => l.supplementNoAlarmSetForTonight1dd33d,
    "No motion was recorded alongside the heart rate." =>
      l.supplementNoMotionWasRecordedAlongside2b680c,
    "No night long enough to score was recorded." =>
      l.supplementNoNightLongEnoughTo022959,
    "No readiness" => l.supplementNoReadiness723eb1,
    "No sleep" => l.homeRingNoSleep,
    "No strain" => l.homeRingNoStrain,
    "No target yet" => l.supplementNoTargetYeta4b21a,
    "No waking heart rate was recorded for this day." =>
      l.supplementNoWakingHeartRateWase66108,
    "Nocturnal HR dip" => l.supplementNocturnalHRDipf94b8c,
    "Nocturnal dipping literature; personal baseline" =>
      l.supplementNocturnalDippingLiteraturePersonalBaseline63f775,
    "Nocturnal heart-rate minimum; personal baseline, not population" =>
      l.supplementNocturnalHeartRateMinimumPersonal5237e7,
    "Not enough history yet to know what normal looks like for you." =>
      l.supplementNotEnoughHistoryYetTo635525,
    "Not enough nights of resting heart rate behind the reserve yet." =>
      l.supplementNotEnoughNightsOfRestingce7af6,
    "Not scored" => l.homeReadinessNotScored,
    "Nothing from last night has reached the app yet." =>
      l.supplementNothingFromLastNightHas71866a,
    "Nothing recorded says why this is missing." =>
      l.supplementNothingRecordedSaysWhyThis97026a,
    "Nothing stood out tonight." => l.supplementNothingStoodOutTonight468e67,
    "Off" => l.supplementOffe3de5a,
    "Paired sensor" => l.supplementPairedSensor0ff7bd,
    "Plews 2013 (lnRMSSD) · Hopkins smallest-worthwhile-change gate" =>
      l.supplementPlews2013LnRMSSDHopkinsSmallestdd73bd,
    "Plotting…" => l.supplementPlotting351c45,
    "Poses" => l.supplementPosesbcddeb,
    "Possible illness onset" => l.supplementPossibleIllnessOnset9dccbc,
    "Provider returned a non-JSON response. Check the API base URL — it must point at an OpenAI-compatible /chat/completions endpoint." =>
      l.supplementProviderReturnedANonJSON31ec8d,
    "Provider returned an unsupported response shape (no message/delta). Streaming-only endpoints are not supported — use a standard OpenAI-compatible /chat/completions endpoint." =>
      l.supplementProviderReturnedAnUnsupportedResponse711ef9,
    "Querying your data…" => l.supplementQueryingYourData547061,
    "REM sleep" => l.supplementREMSleepd0c12b,
    "RMSSD over the longest artefact-free window during sleep. Beat timing is recovered from the band's 1 Hz records and corrected by the Lipponen–Tarvainen method before any statistic is taken. Pulse-derived, so this is PRV: real and trendable, but not ECG HRV." =>
      l.supplementRMSSDOverTheLongestArtefact4d9ff2,
    "Readiness" => l.readinessDetailTitle,
    "Reading your food log…" => l.supplementReadingYourFoodLog4efdaa,
    "Reading your medications…" => l.supplementReadingYourMedications855987,
    "Recommended bedtime" => l.supplementRecommendedBedtime4cba4c,
    "Record-presence, not heart-rate validity" =>
      l.supplementRecordPresenceNotHeartRate83be2e,
    "Recovery" => l.wellnessTabRecovery,
    "Relative only — uncalibrated ADC" =>
      l.supplementRelativeOnlyUncalibratedADC306a93,
    "Rem min" => l.supplementRemMin0d0cd5,
    "Reps" => l.supplementReps702045,
    "Request timeout (seconds)" => l.supplementRequestTimeoutSeconds1c1975,
    "Respiratory rate" => l.healthRowRespRate,
    "Resting heart rate" => l.workoutRestingHeartRateLabel,
    "Resting hr" => l.supplementRestingHrdfb52f,
    "Rounds" => l.activitySetupRoundsLabel,
    "Save step goal" => l.supplementSaveStepGoalf99049,
    "Set step goal" => l.supplementSetStepGoalb12cf1,
    "Shown tonight on Vitals" => l.supplementShownTonightOnVitalsa1d4ef,
    "Skin temperature" => l.signalSkinTempRaw,
    "Skin temperature elevated" => l.supplementSkinTemperatureElevated8165c1,
    "Sleep debt min" => l.supplementSleepDebtMin0cdfc7,
    "Sleep efficiency" => l.supplementSleepEfficiency9c3cbc,
    "Sleep efficiency pct" => l.supplementSleepEfficiencyPctc39ed5,
    "Sleep min" => l.supplementSleepMin16cd5b,
    "Smart wake off" => l.supplementSmartWakeOff20d2dc,
    "Smart wake on — the band still buzzes at the wake time either way" =>
      l.supplementSmartWakeOnTheBand381ebf,
    "Smart wake window" => l.supplementSmartWakeWindowb1483d,
    "Something stood out today" => l.supplementSomethingStoodOutToday463b39,
    "Staged from beat-timing variability and movement. A wrist sensor separates REM from light sleep only approximately." =>
      l.supplementStagedFromBeatTimingVariabilityb83d0c,
    "Start workout" => l.supplementStartWorkoutd0f3f2,
    "Step goal reached" => l.supplementStepGoalReached03be1a,
    "Steps" => l.settingsStepsRowTitle,
    "Still working out?" => l.supplementStillWorkingOut5f72c7,
    "Strain" => l.homeRingStrain,
    "Stress" => l.healthRowStress,
    "Sustained rise vs your baseline — a possible illness signal." =>
      l.supplementSustainedRiseVsYourBaseline67c853,
    "Syncing…" => l.supplementSyncing221ca6,
    "Talk it through" => l.supplementTalkItThrough88a9d2,
    "Tap for last night's sleep, recovery and what it means for today." =>
      l.supplementTapForLastNightS6fe212,
    "Tap to log a glass." => l.supplementTapToLogAGlass879bad,
    "Tell it about your day — it proposes tags and a note, you decide what to keep." =>
      l.supplementTellItAboutYourDay129cfd,
    "Tell it about your day…" => l.supplementTellItAboutYourDayef23a5,
    "That night has no sleep efficiency behind it." =>
      l.supplementThatNightHasNoSleepa8ce2d,
    "That night has no total sleep time behind it." =>
      l.supplementThatNightHasNoTotalb1cf0a,
    "That night has no wake time behind it." =>
      l.supplementThatNightHasNoWake1fabdf,
    "The band did not confirm this alarm — check the strap." =>
      l.supplementTheBandDidNotConfirmb7159e,
    "The band has not yet held a high enough heart rate through a hard effort to measure a ceiling from." =>
      l.supplementTheBandHasNotYet9773f2,
    "The drop in heart rate over the 60 seconds after a bout ends, averaged across the day's bouts." =>
      l.supplementTheDropInHeartRate80433d,
    "The highest heart rate held so far sits well below what your age predicts, so it reads as an effort that was never maximal rather than as your ceiling — the zones stay on the age estimate until the band sees a harder one." =>
      l.supplementTheHighestHeartRateHeldc1c878,
    "The lowest sustained sleeping heart rate of the night, taken over a rolling window of the overnight series. Not a spot reading, and not a daytime minimum." =>
      l.supplementTheLowestSustainedSleepingHeart72e5dd,
    "The night's mean raw sensor reading, expressed as distance from your own recent nights. There is no conversion to degrees anywhere in the path." =>
      l.supplementTheNightSMeanRaw25e383,
    "The ratio of low- to high-frequency power in beat-interval variability, from a Lomb–Scargle periodogram (the series is unevenly sampled, so an FFT would be wrong)." =>
      l.supplementTheRatioOfLowTo817781,
    "There is no resting heart rate from a scored night to measure against." =>
      l.supplementThereIsNoRestingHeart36a9ca,
    "There is no scored night to read this from." =>
      l.supplementThereIsNoScoredNight5d353d,
    "These recordings are not stamped with which strap made them, and this number has to be calibrated per strap, so it is withheld rather than guessed." =>
      l.supplementTheseRecordingsAreNotStamped66b52f,
    "This day came from an imported export, which carries the night only — nothing was recorded for the waking day, and there is no raw behind it to work one out from." =>
      l.supplementThisDayCameFromAn2dc4b2,
    "This phone" => l.settingsGroupThisPhone,
    "Time" => l.workoutTimeStatLabel,
    "Time asleep" => l.sleepDetailTimeAsleep,
    "Time asleep as a fraction of time in bed." =>
      l.supplementTimeAsleepAsAFraction516f7f,
    "Time to move" => l.supplementTimeToMove7afe98,
    "Today has not produced any activity to read yet — nothing has reached the app for it." =>
      l.supplementTodayHasNotProducedAnyf103a0,
    "Too few clean beat-to-beat intervals to work this out." =>
      l.supplementTooFewCleanBeatTo5c2edf,
    "Too few half-hour stretches of clean breathing through the night to compare against each other." =>
      l.supplementTooFewHalfHourStretchesbe11a5,
    "Too few heart-rate samples were recorded to work this out." =>
      l.supplementTooFewHeartRateSamples412047,
    "Too few recorded sessions to describe a pattern rather than noise." =>
      l.supplementTooFewRecordedSessionsTofa71f6,
    "Total cholesterol" => l.supplementTotalCholesterol175f97,
    "Total sleep time from the wrist z-angle sleep window, staged by a combined actigraphy and heart-rate model." =>
      l.supplementTotalSleepTimeFromThee13b95,
    "Total testosterone" => l.supplementTotalTestosterone9e1b98,
    "Total volume" => l.activitySummaryTotalVolume,
    "Training impulse: time in each heart-rate zone, weighted by the physiological cost of that zone." =>
      l.supplementTrainingImpulseTimeInEachcd2945,
    "Training load" => l.workoutTrainingLoad,
    "Transferrin saturation" => l.supplementTransferrinSaturation31bc19,
    "Triglycerides" => l.supplementTriglycerides95ae7f,
    "Unexpected response from provider." =>
      l.supplementUnexpectedResponseFromProvider8b5e12,
    "Unknown sensor" => l.supplementUnknownSensor98a1f7,
    "Unusual for you" => l.supplementUnusualForYou770b0d,
    "Unusual overnight physiology" =>
      l.supplementUnusualOvernightPhysiology69c322,
    "Unusual together" => l.supplementUnusualTogether4ca5cd,
    "VO2max (est.)" => l.supplementVO2maxEst25e886,
    "View data" => l.supplementViewData9a8de9,
    "Vitamin B12" => l.supplementVitaminB12be7c1e,
    "Vitamin D (25-OH)" => l.supplementVitaminD25OHacb2ca,
    "Volume of the loaded sets" => l.activitySummaryVolumeLoadedSets,
    "WHOOP's own nightly value, read from the blood oxygen column of an imported export and stored as-is." =>
      l.supplementWHOOPSOwnNightlyValue5e1394,
    "Wake time" => l.alarmWakeTimeRowTitle,
    "Water" => l.nutritionWaterLabel,
    "Wear time" => l.healthRowWearTime,
    "Webster / Cole–Kripke rescoring + HRV staging" =>
      l.supplementWebsterColeKripkeRescoringHRV378025,
    "Wind down" => l.supplementWindDown1d651a,
    "Wind-down, movement nudges, goals and weekly recaps" =>
      l.supplementWindDownMovementNudgesGoalsc032fa,
    "Withheld" => l.supplementWithheld96ac7e,
    "Within-user dispersion" => l.supplementWithinUserDispersion6ba4c5,
    "Working…" => l.supplementWorking13b7bf,
    "You have no wake alarm armed for tonight." =>
      l.supplementYouHaveNoWakeAlarmaf3d5a,
    "You have set your zones manually, so there is no measured reserve anchor to plot a distribution against." =>
      l.supplementYouHaveSetYourZones535d10,
    "You've been still for a couple of hours." =>
      l.supplementYouVeBeenStillForbb79a9,
    "Your age is not on file, and this is worked out from it." =>
      l.supplementYourAgeIsNotOn9fe209,
    "Your band" => l.dayStepsYourBand,
    "Your band hasn't synced in a while" =>
      l.supplementYourBandHasnTSynced0a4dfd,
    "Your beat-to-beat pattern looked irregular today. This is a screen, not a diagnosis — see a clinician if you have symptoms." =>
      l.supplementYourBeatToBeatPatternfed8f0,
    "Your height is not on file, and this is worked out from it." =>
      l.supplementYourHeightIsNotOn733908,
    "Your morning briefing is ready" =>
      l.supplementYourMorningBriefingIsReadydd0ae8,
    "Your nightly signals deviate from your personal baseline." =>
      l.supplementYourNightlySignalsDeviateFromc8d20a,
    "Your rating" => l.supplementYourRating83cd62,
    "Your recovery is ready" => l.supplementYourRecoveryIsReadya1734c,
    "Your recovery markers are below your usual range — ease off." =>
      l.supplementYourRecoveryMarkersAreBelow2fc2f7,
    "Your resting HR has fallen noticeably versus your recent baseline." =>
      l.supplementYourRestingHRHasFallenca6165,
    "Your resting HR has risen noticeably versus your recent baseline." =>
      l.supplementYourRestingHRHasRisen59f637,
    "Your resting heart-rate trend shifted" =>
      l.supplementYourRestingHeartRateTrend8eccb6,
    "Your sex is not on file, and the formula behind this needs it." =>
      l.supplementYourSexIsNotOn676db8,
    "Your strap alarm just fired." => l.supplementYourStrapAlarmJustFiredd366d3,
    "Your week in review" => l.supplementYourWeekInReviewabd176,
    "Your weight is not on file, and this is worked out from it." =>
      l.supplementYourWeightIsNotOn4ae5a6,
    "You’ve been in a typing posture for over 90 minutes without walking." =>
      l.supplementYouVeBeenInA933b2c,
    "alcohol units" => l.supplementAlcoholUnitsea84fd,
    "an improvement" => l.supplementAnImprovement00aad0,
    "bpm" => l.activityLiveBpmUnit,
    "br/min" => l.supplementBrMin0041f9,
    "breakfast" => l.supplementBreakfast9e3a82,
    "caffeine mg" => l.supplementCaffeineMgf15138,
    "cm" => l.supplementCme283e1,
    "days" => l.cycleUnitDays,
    "dinner" => l.supplementDinner78cbc7,
    "doses" => l.wellnessDosesUnit,
    "down" => l.supplementDown77346d,
    "energy" => l.supplementEnergy173d91,
    "every day" => l.supplementEveryDaya3fd74,
    "figure" => l.supplementFiguref85bdc,
    "g" => l.supplementG54fd17,
    "iOS can only show the system pairing sheet before the app has used Bluetooth. Close OpenStrap completely, then reopen it — the sheet appears on its own." =>
      l.supplementIOSCanOnlyShowThe2139b2,
    "kcal" => l.supplementKcal72037b,
    "kg" => l.supplementKg138984,
    "km" => l.supplementKm08ec69,
    "lunch" => l.supplementLunch094530,
    "m" => l.supplementM6b0d31,
    "min" => l.supplementMinb6c935,
    "missed" => l.supplementMissed09f750,
    "mood" => l.supplementMood89b9fb,
    "ms" => l.cycleUnitMs,
    "nights" => l.beatsUnitNights,
    "no trend yet, not enough days recorded" =>
      l.supplementNoTrendYetNotEnoughc23fe5,
    "not_taken" => l.supplementNotTaken3d2bc8,
    "nothing" => l.supplementNothing0feca7,
    "readiness" => l.supplementReadinesseb830b,
    "resting heart rate" => l.supplementRestingHeartRatec5adc7,
    "score" => l.supplementScore75ebcb,
    "screens min" => l.supplementScreensMinab5656,
    "skipped" => l.wellnessStateSkipped,
    "sleep efficiency" => l.supplementSleepEfficiency548fe0,
    "sleep quality" => l.supplementSleepQualitya146dc,
    "snack" => l.supplementSnack1ba61a,
    "soreness" => l.supplementSoreness91da9e,
    "steady" => l.supplementSteady0c69e7,
    "steps" => l.activityLiveStepsUnit,
    "strain" => l.supplementStrain26d10f,
    "stress" => l.supplementStress165bd3,
    "taken" => l.wellnessStateTaken,
    "time asleep" => l.supplementTimeAsleep78b642,
    "today" => l.dayStepsToday,
    "trending down" => l.supplementTrendingDownfc2716,
    "trending up" => l.supplementTrendingUp34094b,
    "up" => l.supplementUp7c0a25,
    "van Hees 2015 window detection + nocturnal HR dip" =>
      l.supplementVanHees2015WindowDetectionbef776,
    "van Hees 2015 · Webster / Cole–Kripke rescoring" =>
      l.supplementVanHees2015WebsterCole3d69f8,
    "water ml" => l.supplementWaterMl7902c6,
    "weight kg" => l.supplementWeightKge50726,
    "workout" => l.supplementWorkoutc87292,
    "worse than usual" => l.supplementWorseThanUsual06f439,
    "wrist optical" => l.supplementWristOptical06ad7e,
    _ => text,
  };
}
