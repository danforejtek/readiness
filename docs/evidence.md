# Evidence base for the readiness method

What the published literature says about each part of the morning-readiness method in `hrmon/readiness.py`
and `hrmon/hrv.py` (and its Swift port), and where the app departs from it. The app's three numbers copy the
Elonga/mySASY layout (Regeneration 0–10, Readiness 0–100, Stress 0–10). The Regeneration/Stress composition was
borrowed from Kubios' PNS/SNS indices. This document looks for grounding that does not depend on Kubios.

Every reference below was checked against PubMed or Crossref (October 2026) unless it is marked **unverified**.
"Verified" means the paper exists with that title, journal and DOI. For most of them the abstract was read too.
Claims about a paper's methods that could only be checked through a secondary source say so.

---

## A. Daily lnRMSSD, the ±0.5 SD normal range, and the 7-day rolling average

- Plews DJ, Laursen PB, Kilding AE, Buchheit M (2012). Heart rate variability in elite triathletes, is variation in variability the key to effective training? A case comparison. *Eur J Appl Physiol* 112:3729–3741. https://doi.org/10.1007/s00421-012-2354-4
- Plews DJ, Laursen PB, Kilding AE, Buchheit M (2013). Evaluating training adaptation with heart-rate measures: a methodological comparison. *Int J Sports Physiol Perform* 8:688–691. https://doi.org/10.1123/ijspp.8.6.688
- Plews DJ, Laursen PB, Stanley J, Kilding AE, Buchheit M (2013). Training adaptation and heart rate variability in elite endurance athletes: opening the door to effective monitoring. *Sports Med* 43:773–781. https://doi.org/10.1007/s40279-013-0071-8
- Buchheit M (2014). Monitoring training status with HR measures: do all roads lead to Rome? *Front Physiol* 5:73. https://doi.org/10.3389/fphys.2014.00073
- Hopkins WG, Marshall SW, Batterham AM, Hanin J (2009). Progressive statistics for studies in sports medicine and exercise science. *Med Sci Sports Exerc* 41:3–12. https://doi.org/10.1249/MSS.0b013e31818cb278

In runners, the change in lnRMSSD averaged over a week correlated very strongly with the change in performance
(r ≈ 0.72–0.76). The value from a single isolated day did not (r ≈ −0.06 to −0.17) (Plews 2013 IJSPP). In the
triathlete case study, single-day lnRMSSD fell outside the individual smallest worthwhile change (SWC) on 64–100 %
of days, even in the athlete who was coping well. The 7-day rolling average gave the cleaner signal. Plews defined
the SWC as **0.5 × the athlete's own CV of lnRMSSD over the first two weeks**, following Hopkins 2009 (methods
checked in Plews' 2014 AUT PhD thesis, which reprints the 2012 paper: https://hdl.handle.net/10292/7122).
Buchheit 2014 argues the same: interpret a change against the measurement error and the smallest important change,
and in the context of the training.

**App today:** lnRMSSD, a personal baseline (60 days), a normal range of mean ± 0.5 SD and a 7-day rolling average
all **match** the method. *Applied 2026-10-09:* a single day now triggers MODERATE only at HRV z ≤ −1 (Kiviniemi's
rule); the ±0.5 SD range still applies to the 7-day average. Before that change MODERATE fired at z < −0.5, which with
roughly normal day-to-day noise is about 31 % of perfectly ordinary mornings.
The resting-HR rule (z > +1) adds about 16 % more. In
Plews, Vesterinen and Javaloyes the SWC is applied to the 7-day rolling average (see L). The ±0.5 SD-of-daily-values
version is the HRV4Training/Altini implementation of the same idea. Scaled to SD rather than CV, it is close to
Plews' version.

## B. Typical day-to-day CV of lnRMSSD

- Plews DJ, Laursen PB, Le Meur Y, Hausswirth C, Kilding AE, Buchheit M (2014). Monitoring training with heart-rate variability: how much compliance is needed for valid assessment? *Int J Sports Physiol Perform* 9:783–790. https://doi.org/10.1123/ijspp.2013-0455
- Flatt AA, Esco MR (2015). Smartphone-derived heart-rate variability and training load in a women's soccer team. *Int J Sports Physiol Perform* 10:994–1000. https://doi.org/10.1123/ijspp.2014-0556
- Flatt AA, Esco MR (2016). Evaluating individual training adaptation with smartphone-derived heart rate variability in a collegiate female soccer team. *J Strength Cond Res* 30:378–385. https://doi.org/10.1519/JSC.0000000000001095
- Al Haddad H, Laursen PB, Chollet D, Ahmaidi S, Buchheit M (2011). Reliability of resting and postexercise heart rate measures. *Int J Sports Med* 32:598–605. https://doi.org/10.1055/s-0031-1275356
- Bellenger CR, Miller D, Halson SL, Roach GD, Maclennan M, Sargent C (2022). Evaluating the typical day-to-day variability of WHOOP-derived heart rate variability in Olympic water polo athletes. *Sensors* 22:6723. https://doi.org/10.3390/s22186723

Bellenger 2022 summarises the literature as "typical day-to-day variability in lnRMSSD ranges between 3 and 13 %",
citing Plews 2014, Flatt & Esco 2015, Nakamura 2020, Al Haddad 2011 and Buchheit 2014. It measured a mean weekly CV
of 5.4 % in Olympic water-polo players. The weekly CV is itself a training signal. It rises under heavy load and
with lower fitness (Flatt & Esco 2015, 2016), and it fell steadily in the triathlete who became non-functionally
overreached (Plews 2012). Plews 2014 found that at least 3 randomly spread valid mornings per week reproduce the
7-day picture. Flatt & Esco 2015 recommend at least 5.

**App today:** "3–8 % is typical" **under-states the published range** (3–13 %). It may also flag normal users as
"inconsistent protocol". The comparison is also not like-for-like. `analyze.py` computes the CV over the whole
history, while the literature values are mostly weekly (7-day) CVs. A whole-history CV includes real trends and
reads higher.

## C. Resting HR rise plus HRV drop as an early illness signal

- Mishra T, Wang M, Metwally AA, et al. (2020). Pre-symptomatic detection of COVID-19 from smartwatch data. *Nat Biomed Eng* 4:1208–1220. https://doi.org/10.1038/s41551-020-00640-6
- Alavi A, Bogu GK, Wang M, et al. (2022). Real-time alerting system for COVID-19 and other stress events using wearable data. *Nat Med* 28:175–184. https://doi.org/10.1038/s41591-021-01593-2
- Quer G, Radin JM, Gadaleta M, et al. (2021). Wearable sensor data and self-reported symptoms for COVID-19 detection. *Nat Med* 27:73–77. https://doi.org/10.1038/s41591-020-1123-x
- Natarajan A, Su HW, Heneghan C (2020). Assessment of physiological signs associated with COVID-19 measured using wearable devices. *npj Digit Med* 3:156. https://doi.org/10.1038/s41746-020-00363-7
- Risch M, Grossmann K, Aeschbacher S, et al. (2022). Investigation of the use of a sensor bracelet for the presymptomatic detection of changes in physiological parameters related to COVID-19 (COVI-GAPP). *BMJ Open* 12:e058274. https://doi.org/10.1136/bmjopen-2021-058274
- Mason AE, Hecht FM, Davis SK, et al. (2022). Detection of COVID-19 using multimodal data from a wearable device: results from the first TemPredict Study (Oura ring). *Sci Rep* 12:3463. https://doi.org/10.1038/s41598-022-07314-0
- Miller DJ, Capodilupo JV, Lastella M, et al. (2020). Analyzing changes in respiratory rate to predict the risk of COVID-19 infection (WHOOP). *PLoS One* 15:e0243693. https://doi.org/10.1371/journal.pone.0243693
- Altini M, Plews D (2021). What is behind changes in resting heart rate and heart rate variability? A large-scale analysis of longitudinal measurements acquired in free-living. *Sensors* 21:7932. https://doi.org/10.3390/s21237932
- Hellard P, Guimaraes F, Avalos M, et al. (2011). Modeling the association between HR variability and illness in elite swimmers. *Med Sci Sports Exerc* 43:1063–1070. https://doi.org/10.1249/MSS.0b013e318204de1c

The consumer-wearable studies all find the same thing. Resting HR above the personal baseline is the most robust
early sign. HRV falls and breathing rate rises alongside it (Natarajan 2020, Risch 2022). Signals often appear 1–3
days before symptoms. Mishra 2020 found that 63 % of COVID cases could have been flagged before symptoms from
extreme elevations of resting HR above the personal baseline. In prospective use, the same alerts were also
triggered by stress, alcohol and travel (Alavi 2022). Mason 2022 (Oura) reached a specificity of only 63 %.

The closest analogue to the app is Altini & Plews 2021, with morning spot readings from 28k HRV4Training users:
sickness days averaged **+6 % resting HR and −10 % HRV**, and high alcohol intake caused a similar pattern
(+6 % HR, −12 % HRV). The authors conclude that HRV is "sensitive but not specific".

The sports literature is less tidy. In elite swimmers, Hellard 2011 linked respiratory infections to a *rise* in
supine parasympathetic indices the week before, followed by a shift toward sympathetic dominance.

**App today:** The pattern (HR up with HRV down, relative to the personal baseline) **matches** the evidence. The
thresholds (HR ≥ +4 bpm, and either ≥ +1.5 SD with HRV ≤ −1 SD or ≥ +2.5 SD alone; streak of flagged days counted)
are **not taken from any study**. *Applied 2026-10-09:* the warning now needs two consecutive flagged mornings; a
single flagged morning gets a softer note naming alcohol, sleep, travel and stress as look-alikes.
They are a reasonable heuristic. The +4 bpm floor is a little above the average sickness effect in Altini & Plews
(+6 % ≈ +3–3.5 bpm at a resting HR of 55–60). The phrase "classic pattern a day or two before an infection"
**slightly over-claims**:

- the large studies used overnight or all-day data, not a 2-minute morning reading;
- they needed multi-day or CuSum logic;
- they report many false alarms from alcohol, stress and travel.

## D. Ultra-short recordings, and the duration that LF, HF and LF/HF need

- Munoz ML, van Roon A, Riese H, et al. (2015). Validity of (ultra-)short recordings for heart rate variability measurements. *PLoS One* 10:e0138921. https://doi.org/10.1371/journal.pone.0138921
- Esco MR, Flatt AA (2014). Ultra-short-term heart rate variability indexes at rest and post-exercise in athletes: evaluating the agreement with accepted recommendations. *J Sports Sci Med* 13:535–541. https://pubmed.ncbi.nlm.nih.gov/25177179/
- Nussinovitch U, Elishkevitz KP, Katz K, et al. (2011). Reliability of ultra-short ECG indices for heart rate variability. *Ann Noninvasive Electrocardiol* 16:117–122. https://doi.org/10.1111/j.1542-474X.2011.00417.x
- Pecchia L, Castaldo R, Montesinos L, Melillo P (2018). Are ultra-short heart rate variability features good surrogates of short-term ones? State-of-the-art review and recommendations. *Healthc Technol Lett* 5:94–100. https://doi.org/10.1049/htl.2017.0090
- Shaffer F, Ginsberg JP (2017). An overview of heart rate variability metrics and norms. *Front Public Health* 5:258. https://doi.org/10.3389/fpubh.2017.00258
- Bourdillon N, Schmitt L, Yazdani S, Vesin JM, Millet GP (2017). Minimal window duration for accurate HRV recording in athletes. *Front Neurosci* 11:456. https://doi.org/10.3389/fnins.2017.00456
- Task Force of the ESC and NASPE (1996). Heart rate variability: standards of measurement, physiological interpretation and clinical use. *Circulation* 93:1043–1065. https://doi.org/10.1161/01.CIR.93.5.1043 (full text paywalled; its duration rule was checked only through secondary sources)
- Flatt AA, Esco MR (2016). Heart rate variability stabilization in athletes: towards more convenient data acquisition. *Clin Physiol Funct Imaging* 36:331–336. https://doi.org/10.1111/cpf.12233

RMSSD is the time-domain index that survives shortening best. In 3,387 adults, 120 s against 240–300 s gave
r = 0.986 with negligible bias (Munoz 2015). 60 s is acceptable for lnRMSSD in athletes (Esco & Flatt 2014), and
even 10 s correlates (Nussinovitch 2011). Spectral measures do not shorten as well:

- Shaffer & Ginsberg give conventional minima of 1 min for HF, 2 min for LF and 5 min for VLF.
- Bourdillon 2017 found that RMSSD can be taken from a 2-minute window, but LF and total power needed 4 minutes.
- The Task Force standard short-term recording is 5 min.
- Pecchia 2018 and Shaffer 2020 warn that most ultra-short validation studies used weak statistics.

Flatt & Esco 2016 support a short stabilisation of about 1 minute before recording.

**App today:** 120 s lnRMSSD **matches** the evidence well. HF from 120 s is at the edge of what is acceptable. LF
and LF/HF from 120 s **over-claim**, and `spectral_metrics` accepts spans as short as 60 s, which is too short for
LF by every source above. *Applied 2026-10-09:* the settle period is now 60 s, about what the studies used (it was
15 s).

## E. Lomb-Scargle spectra from the beat series

- Laguna P, Moody GB, Mark RG (1998). Power spectral density of unevenly sampled data by least-square analysis: performance and application to heart rate signals. *IEEE Trans Biomed Eng* 45:698–715. https://doi.org/10.1109/10.678605
- Clifford GD, Tarassenko L (2005). Quantifying errors in spectral estimates of HRV due to beat replacement and resampling. *IEEE Trans Biomed Eng* 52:630–638. https://doi.org/10.1109/TBME.2005.844028
- Tarvainen MP, Niskanen JP, Lipponen JA, Ranta-Aho PO, Karjalainen PA (2014). Kubios HRV – heart rate variability analysis software. *Comput Methods Programs Biomed* 113:210–220. https://doi.org/10.1016/j.cmpb.2013.07.024

Laguna 1998 shows that Lomb-Scargle avoids the low-pass bias of interpolation-plus-FFT. Frequencies should be
kept below the mean Nyquist frequency, which is under 0.5 Hz when HR is under 60 bpm. Clifford & Tarassenko
2005 show that LS beats resampling, and that removing or replacing ectopic beats is essential whatever estimator
is used. The spectral error grows linearly with the artefact rate. Kubios defaults to interpolation with
detrending (smoothness priors) and FFT or AR estimation, and offers Lomb-Scargle as an option.

**App today:** Using Lomb-Scargle on the beat times **matches** the best-supported choice. Two small gaps:

- only the mean is removed, with no detrending;
- the HF band runs to 0.40 Hz without checking it against the mean Nyquist frequency. At 45 bpm the Nyquist
  frequency is 0.375 Hz.

## F. Artefact and ectopic-beat filtering

- Lipponen JA, Tarvainen MP (2019). A robust algorithm for heart rate variability time series artefact correction using novel beat classification. *J Med Eng Technol* 43:173–181. https://doi.org/10.1080/03091902.2019.1640306
- Karlsson M, Hörnsten R, Rydberg A, Wiklund U (2012). Automatic filtering of outliers in RR intervals before analysis of heart rate variability in Holter recordings: a comparison with carefully edited data. *Biomed Eng Online* 11:2. https://doi.org/10.1186/1475-925X-11-2
- Clifford & Tarassenko 2005 (see E)
- Shaffer F, Meehan ZM, Zerr CL (2020). A critical review of ultra-short-term heart rate variability norms research. *Front Neurosci* 14:594880. https://doi.org/10.3389/fnins.2020.594880

Karlsson 2012 removes intervals that differ from the mean of their neighbours by more than a fixed percentage. A
filter like this, with an age-dependent limit of roughly 20–40 %, gave HRV indices close to manually edited data.
The age schedule was read through a summary, so treat it as **partly verified**. Lipponen & Tarvainen 2019 (the
current Kubios automatic method) use time-varying thresholds from the distribution of successive differences, plus
beat classification. They detected 97 % of real ectopic beats, and **correct** artefacts by interpolation instead
of deleting them. Shaffer 2020 stresses that a single missed artefact can distort ultra-short HRV badly.

**App today:** Rejecting intervals more than 20 % away from the median of the last 5 accepted intervals is
**consistent** with the relative-threshold family (Karlsson and the Kubios threshold filter). It is simpler than
Lipponen. Two departures:

- **Rejected beats are dropped, and successive differences are computed across the gap.** This inflates RMSSD
  slightly whenever there are artefacts. Proper practice either skips those differences or interpolates the beat.
  *Applied earlier:* differences that span a rejected beat are now skipped by RMSSD, pNN50 and SD1.
- **The 15 % artefact limit for "low confidence" is lenient** for a 2-minute PPG recording. Clifford shows the
  error growing linearly with the artefact rate. Many studies exclude recordings above about 5 %, but no single
  validated cut-off was verified. *Applied 2026-10-09:* the limit is now 5 % (`low_quality_artefact_pct`); the
  60-clean-beats rule stays. Low-confidence mornings are also left out of the baseline, so mornings between 5 and
  15 % no longer shape your normal range.

## G. Poincaré SD1/SD2 and how they relate to RMSSD/SDNN

- Brennan M, Palaniswami M, Kamen P (2001). Do existing measures of Poincaré plot geometry reflect nonlinear features of heart rate variability? *IEEE Trans Biomed Eng* 48:1342–1347. https://doi.org/10.1109/10.959330
- Ciccone AB, Siedlik JA, Wecht JM, et al. (2017). Reminder: RMSSD and SD1 are identical heart rate variability metrics. *Muscle Nerve* 56:674–678. https://doi.org/10.1002/mus.25573
- Shaffer & Ginsberg 2017 (see D): "The RMSSD is identical to the non-linear metric SD1."

Brennan 2001 shows that the standard Poincaré descriptors are linear statistics already captured by time-domain
indices: SD1² = ½·Var(ΔRR) and SD2² = 2·SDNN² − SD1². Ciccone 2017 shows empirically and mathematically that SD1
equals RMSSD/√2. Reporting both is redundant, and treating them as separate evidence "may affect the
interpretation of HRV studies".

**App today:** The `poincare()` docstring is **correct** about the equivalence. However, Regeneration averages the
z-scores of RMSSD **and** SD1. A z-score is unchanged by scaling, so those two z-scores are essentially the same
number. RMSSD is effectively counted twice, carrying 2/3 of the weight, with mean RR as the other 1/3. Likewise,
SD2 is a function of SDNN and SD1, so in Stress it is not independent of the HRV that Regeneration measures.

## H. Baevsky's stress index

- Baevsky RM, Chernikova AG (2017). Heart rate variability analysis: physiological foundations and main methods. *Cardiometry* 10:66–76. https://doi.org/10.12710/cardiometry.2017.10.6676 (existence verified; full text not readable here, so its specific numbers are **unverified**)
- Baevsky RM, Berseneva AP (2008). *Methodical recommendations: use of the Kardivar system for determination of the stress level and estimation of the body adaptability.* Moscow/Kardivar. **Unverified**: grey literature, not indexed, could not be retrieved.
- Brisinda D, Picerni M, Fenici P, Fenici R (2024). Rapid assessment of cardiac autonomic modulation and adaptive stress responses: automatic calculation of time-varying parasympathetic, sympathetic, and Baevsky stress indexes. *Brain & Heart* 2(4):3503. https://doi.org/10.36922/bh.3503

SI = AMo / (2·Mo·MxDMn) comes from the RR histogram:

- Mo is the modal bin;
- AMo is the percentage of beats in that bin;
- MxDMn is the range of RR intervals.

The value depends on the bin width, either 50 ms or Baevsky's original 1/128 s, so values are only comparable with
the same bins. Brisinda 2024 quotes a normal resting range of 80–150 conventional units, rising 1.5–2× under stress.
It also notes that Kubios reports the square root of SI, and finds that Kubios values do not match a plain square
root of the original formula. The 50–150 "normal" range that circulates online has no primary source that could
be verified here.

Mathematically, Mo tracks mean RR (that is, HR), and MxDMn tracks overall variability (SDNN and SD2). SI therefore
has little information that is independent of HR and SD2. With about 120–150 beats and 50 ms bins, Mo moves in
50 ms steps (about 5 % of RR) and AMo is coarse.

**App today:** SI with 50 ms bins and a √ transform **matches Kubios**, not Baevsky's original. No resting
reference range is claimed, which is good. As a Stress component, √SI is **largely redundant** with mean HR and
SD2, and it is quantised at a 2-minute duration. The evidence does not support it as an independent third component.

## I. Alternatives to the Kubios PNS/SNS composition

- Naranjo Orellana J, de la Cruz Torres B, Sarabia Cachadiña E, de Hoyo M, Domínguez Cobo S (2015). Two new indexes for the assessment of autonomic balance in elite soccer players. *Int J Sports Physiol Perform* 10:452–457. https://doi.org/10.1123/ijspp.2014-0235
- Laborde S, Altini M, Mosley E, Plews D (2026; © 2027). *Heart Rate Variability: Science and Strategies for Peak Performance.* Human Kinetics. ISBN 9781718236097. Excerpt "Does HRV represent sympathetic nervous system activity?": https://us.humankinetics.com/blogs/excerpt/does-hrv-represent-sympathetic-nervous-system-activity
- Hayano J, Yuda E (2019). Pitfalls of assessment of autonomic function by heart rate variability. *J Physiol Anthropol* 38:3. https://doi.org/10.1186/s40101-019-0193-2
- Billman GE (2013). The LF/HF ratio does not accurately measure cardiac sympatho-vagal balance. *Front Physiol* 4:26. https://doi.org/10.3389/fphys.2013.00026
- Martelli D, Silvani A, McAllen RM, May CN, Ramchandra R (2014). The low frequency power of heart rate variability is neither a measure of cardiac sympathetic tone nor of baroreflex sensitivity. *Am J Physiol Heart Circ Physiol* 307:H1005–H1012. https://doi.org/10.1152/ajpheart.00361.2014
- Goldstein DS, Bentho O, Park MY, Sharabi Y (2011). Low-frequency power of heart rate variability is not a measure of cardiac sympathetic tone but may be a measure of modulation of cardiac autonomic outflows by baroreflexes. *Exp Physiol* 96:1255–1261. https://doi.org/10.1113/expphysiol.2010.056259
- Laborde S, Mosley E, Thayer JF (2017). Heart rate variability and cardiac vagal tone in psychophysiological research – recommendations for experiment planning, data analysis, and data reporting. *Front Psychol* 8:213. https://doi.org/10.3389/fpsyg.2017.00213

**What the evidence says**

- **The vagal side is well grounded.** RMSSD (lnRMSSD) is the recommended short-recording index of cardiac vagal
  activity: it is robust to breathing and to short durations (Laborde 2017; Buchheit 2014; Saboul 2013 in J). The
  log transform is standard in this literature (Plews, Buchheit, Flatt, Esco). It deals with the right-skewed,
  heteroscedastic distribution of RMSSD, in line with Hopkins 2009's advice to log-transform variables whose error
  scales with their size.
- **The sympathetic side is not grounded.** No HRV index from a short resting recording validly measures cardiac
  sympathetic tone. LF and LF/HF fail (Billman 2013; Goldstein 2011; Martelli 2014; Hayano & Yuda 2019). Martelli
  2014 found that heart period (mean RR, i.e. HR) tracked directly recorded cardiac sympathetic nerve activity
  better than LF power did.
- **The Human Kinetics excerpt (Laborde, Altini, Mosley & Plews) names Kubios' composition directly.** It
  criticises "the overinterpretation of HRV as a marker of sympathetic activity". It points out that mean RR (in
  PNS) and mean HR (in SNS) are reciprocals of each other, so the two indices are partly mirror images of each
  other by construction.
- **Naranjo 2015's Stress Score is SS = 1000/SD2, and the S:PS ratio is SS/SD1.** They were validated only by
  correlation with other HRV indices (SS against SDNN, R² = 0.94; S:PS against RMSSD, R² = 0.95). They were taken
  from 10-minute recordings in 25 soccer players, and never compared with a sympathetic criterion such as nerve
  activity, catecholamines or pre-ejection period. SS is in practice an inverse of overall variability. The S:PS
  ratio builds in the vagal SD1, so it overlaps with any Regeneration index by design.

**App today:** The app reproduces the Kubios structure faithfully. Its personal z-scores are an improvement over
population norms. It inherits three problems:

1. RMSSD and SD1 are counted twice in Regeneration (see G).
2. Mean RR in Regeneration and mean HR in Stress are reciprocals, so the two indices are anti-correlated by
   construction.
3. All three Stress components (HR, √SI, SD2) share most of their information, and none is a validated measure
   of sympathetic activity.

The `readiness.py` comment "Stress … high = bad (sympathetic)" and the README's "Kubios-style PNS / SNS indices" **over-claim**.

**Recommended composition** (non-redundant, each part with published support):

- **Regeneration = z(lnRMSSD)**, optionally smoothed or shown alongside the 7-day lnRMSSD average.
  - Drop SD1, because it is identical to RMSSD.
  - Drop mean RR, because it is the reciprocal of the HR used in Stress, and resting HR is not a vagal-specific
    index.
  - Use the ln scale, not raw RMSSD.
  - If a second component is wanted for highly trained users with "saturated" HRV, Plews 2013 (Sports Med)
    suggests the **lnRMSSD : mean RR ratio** as a saturation check. That is an add-on flag, not an average.
  - Confidence: **high** that lnRMSSD alone is the best-supported vagal index. **Moderate** that adding anything
    else improves it.
- **Stress = z(resting HR)** as the primary component. Optionally average it with **z(ln SS) = −z(ln SD2)**, the
  Naranjo Stress Score on a log scale, at ≤ 1/3 weight.
  - Drop √SI, because it is redundant with HR and SD2 and quantised at 2 minutes.
  - Do not use S:PS, because it re-imports SD1 (vagal).
  - Do not use LF/HF, because it depends on breathing and duration (see D and J).
  - Present Stress as "physiological load / strain on your system", not "sympathetic activity". That is the
    strongest message from the literature, regardless of the formula.
  - Confidence: **moderate** that resting HR is the most defensible single "stress/strain" marker, given its role
    in illness detection (C), alcohol (Altini & Plews 2021) and Martelli 2014. **Low** that SS adds independent
    information, since it correlates strongly with SDNN and hence with RMSSD at rest. Without SS, Stress is simply
    the HR z-score, which the Readiness score already uses at 35 % weight. That trade-off is honest rather than
    a flaw.
- The two indices will still correlate, because HR and RMSSD are physiologically linked. With this composition
  the correlation is physiology, not arithmetic.

## J. Breathing rate from the HF peak; slow breathing and the LF band

- Shaffer & Ginsberg 2017 (see D): the HF band (0.15–0.40 Hz) "is influenced by breathing from 9 to 24 bpm". Vagal oscillations move into LF when breathing is below about 8.5/min.
- Brown TE, Beightol LA, Koh J, Eckberg DL (1993). Important influence of respiration on human R-R interval power spectra is largely ignored. *J Appl Physiol* 75:2310–2317. https://doi.org/10.1152/jappl.1993.75.5.2310
- Saboul D, Pialoux V, Hautier C (2013). The impact of breathing on HRV measurements: implications for the longitudinal follow-up of athletes. *Eur J Sport Sci* 13:534–542. https://doi.org/10.1080/17461391.2013.767947
- Saboul D, Pialoux V, Hautier C (2014). The breathing effect of the LF/HF ratio in the heart rate variability measurements of athletes. *Eur J Sport Sci* 14(Suppl 1):S282–S288. https://doi.org/10.1080/17461391.2012.691116

Brown 1993 showed that both HF and LF power change strongly with breathing rate (6–24/min) and tidal volume, and
that most studies ignore this. Saboul 2014 found that athletes who breathe spontaneously below 0.15 Hz (9/min) all
had LF/HF > 4, a value "commonly interpreted as overtraining", purely because of their breathing. Saboul 2013
showed that day-to-day changes in RMSSD and SD1 track each other whether breathing is spontaneous or paced (r >
0.70). HF and LF/HF do not, and the authors judge them not reliable enough for daily monitoring.

**App today:** The working tree at the time of writing (uncommitted) already **matches** the evidence on breathing
rate. The peak is searched in 0.10–0.50 Hz (6–30/min), and an edge peak gives no value. The committed version
searched only 0.15–0.40 Hz (9–24/min), which misread slow breathers. Two gaps remain:

- **LF/HF is still shown without a warning when breathing is below 9/min.** That is exactly the case Saboul 2014
  shows to be misleading, so it **over-claims**.
- **The 0.50 Hz upper limit can exceed the mean Nyquist frequency at low HR** (Laguna 1998: HR/120 Hz, e.g.
  0.42 Hz at 50 bpm).

The verdict does not use LF/HF, which is correct.

## K. Measurement protocol and sensor

- Plews DJ, Scott B, Altini M, Wood M, Kilding AE (2017). Comparison of heart-rate-variability recording with smartphone photoplethysmography, Polar H7 chest strap, and electrocardiography. *Int J Sports Physiol Perform* 12:1324–1328. https://doi.org/10.1123/ijspp.2016-0668
- Schäfer A, Vagedes J (2013). How accurate is pulse rate variability as an estimate of heart rate variability? A review on studies comparing photoplethysmographic technology with an electrocardiogram. *Int J Cardiol* 166:15–29. https://doi.org/10.1016/j.ijcard.2012.03.119
- Buchheit 2014 (see A); Plews 2013 Sports Med (see A); Flatt & Esco 2016 (see D)
- Fagius J, Karhuvaara S (1989). Sympathetic activity and blood pressure increases with bladder distension in humans. *Hypertension* 14:511–517. https://doi.org/10.1161/01.HYP.14.5.511
- Koenig J, Jarczok MN, Kuhn W, et al. (2013). Impact of caffeine on heart rate variability: a systematic review. *J Caffeine Res* 3:22–37. https://doi.org/10.1089/jcr.2013.0009 (existence verified; conclusions not read, so **unverified**)

**Sensor.** Over 5 minutes at rest, PPG and chest-strap RMSSD agree with ECG to within a "trivial" difference
(TEE ≈ 6 % CV) (Plews 2017). Schäfer & Vagedes 2013 find pulse-rate variability accurate enough at rest, but it
tends to **overestimate short-term variability**, and it degrades with movement.

**Protocol.** Buchheit 2014 and Plews 2013 recommend the same conditions every day: on waking, supine or seated,
at the same time. Plews notes that in very fit athletes, supine HRV "saturates" (HRV falls although HR falls too),
and a standing measurement or the lnRMSSD:RR ratio can help. A full bladder raises muscle sympathetic activity
and blood pressure (Fagius 1989). That argues for voiding first, or at least doing the same thing every morning.

**App today:** On waking, supine, before coffee and fixed duration all **match**. The Elonga band is an optical
(PPG) armband, so the app measures pulse-rate variability, not HRV. That is acceptable at rest, but RMSSD may read
slightly high, and motion artefacts matter more (see F). *Applied 2026-10-09:* the Method page now mentions the
bladder, pulse-rate variability and the 60 s settle period.

## L. HRV-guided training outcomes

- Kiviniemi AM, Hautala AJ, Kinnunen H, Tulppo MP (2007). Endurance training guided individually by daily heart rate variability measurements. *Eur J Appl Physiol* 101:743–751. https://doi.org/10.1007/s00421-007-0552-2
- Vesterinen V, Nummela A, Heikura I, et al. (2016). Individual endurance training prescription with heart rate variability. *Med Sci Sports Exerc* 48:1347–1354. https://doi.org/10.1249/MSS.0000000000000910
- Javaloyes A, Sarabia JM, Lamberts RP, Moya-Ramon M (2019). Training prescription guided by heart-rate variability in cycling. *Int J Sports Physiol Perform* 14:23–32. https://doi.org/10.1123/ijspp.2018-0122
- Düking P, Zinner C, Trabelsi K, et al. (2021). Monitoring and adapting endurance training on the basis of heart rate variability monitored by wearable technologies: a systematic review with meta-analysis. *J Sci Med Sport* 24:1180–1192. https://doi.org/10.1016/j.jsams.2021.04.012
- Manresa-Rocamora A, Sarabia JM, Javaloyes A, Flatt AA, Moya-Ramón M (2021). Heart rate variability-guided training for enhancing cardiac-vagal modulation, aerobic fitness, and endurance performance: a methodological systematic review with meta-analysis. *Int J Environ Res Public Health* 18:10299. https://doi.org/10.3390/ijerph181910299

The guided-training studies used these decision rules:

- **Kiviniemi 2007:** high intensity unless HRV fell below the **10-day mean − 1 SD** or declined for 2 days.
- **Vesterinen 2016:** moderate or high intensity if HRV was within the individual SWC, otherwise easy. The thesis
  version uses the 7-day rolling average of morning RMSSD. The exact SD multiplier is reported as 0.5 SD only by
  secondary sources (**unverified**).
- **Javaloyes 2019:** a 4-week baseline (mean and SD) and a 7-day moving average. The exact multiplier is
  **unverified**.

In all three, the HRV-guided groups improved as much as or more than predefined training, usually with fewer hard
sessions. The meta-analyses temper this. Düking 2021 found a significant benefit only for submaximal physiology
(g ≈ 0.30), with no significant difference for performance or VO₂peak, but fewer non-responders. Manresa-Rocamora
2021 found HRV-guided training better for vagal HRV (SMD 0.50), with only small, non-significant advantages for
fitness and performance.

**App today:** The ready / moderate / rest advice **matches the spirit** of these protocols. It **over-claims
relative to them in one respect**: the trials acted on the 7-day rolling average, or on single-day drops of at
least 1 SD (Kiviniemi), not on −0.5 SD for a single day. *Applied 2026-10-09:* the single-day trigger is now −1 SD,
matching Kiviniemi. The likely benefit should be described as "fewer
unnecessary hard sessions, similar or slightly better gains", not as better performance.

---

## Recommendations

Ranked by strength of evidence, strongest first.

1. **Base the verdict on the 7-day rolling lnRMSSD against the ±0.5 SD range, and give single days a wider band**
   (Plews 2012/2013, Kiviniemi 2007, Vesterinen 2016, Javaloyes 2019; strong).
   - MODERATE should require either the 7-day average below range, or today's HRV at or below −1 SD (Kiviniemi's
     single-day rule). Change `moderate`'s HRV trigger from −0.5 to −1.0 SD.
   - Keep −0.5 SD only for the 7-day average.
   - This removes the roughly 1-in-3 false MODERATE days. **Applied 2026-10-09.**
2. **Stop reporting LF, LF/HF and breathing rate as if they were valid from 1–2 minutes**
   (Task Force via Shaffer & Ginsberg, Bourdillon 2017, Saboul 2013/2014, Brown 1993; strong).
   - Raise `spectral_metrics`' `min_span_s` to at least 120 s for HF.
   - Compute LF and LF/HF only when at least 240 s is available, or label them "indicative".
   - Keep the new 0.10–0.50 Hz breathing search (already in the working tree), and cap it at the mean Nyquist
     frequency (HR/120 Hz).
   - When the breathing peak is below 0.15 Hz, show "slow breathing – LF/HF not interpretable".
3. **Regeneration = z(lnRMSSD) only** (Ciccone 2017, Brennan 2001, Laborde 2017, Laborde/Altini/Mosley/Plews;
   strong for removing the redundancy, moderate for the final form).
   - Remove SD1, which is RMSSD/√2.
   - Remove mean RR, which is the reciprocal of HR.
   - Use ln, not raw ms.
   - Optionally show the 7-day average and the lnRMSSD:RR saturation flag (Plews 2013).
4. **Stress = z(resting HR)**, optionally with z(ln SS), where ln SS = −ln SD2, at ≤ 1/3 weight. Drop √SI.
   Rename or describe it as "strain/load", not "sympathetic" (Billman 2013, Goldstein 2011, Martelli 2014,
   Hayano & Yuda 2019, Naranjo 2015, Human Kinetics excerpt; moderate for HR, low for SS).
   - Update the README and the `readiness.py` docstrings that say "Kubios-style PNS/SNS" and "(sympathetic)".
5. **Fix the RMSSD-across-gaps artefact handling.** Drop successive differences that span a rejected beat, or
   interpolate it as Kubios and Lipponen do. Lower the low-confidence threshold from 15 % towards 5 %
   (Clifford 2005, Lipponen 2019, Shaffer 2020; moderate; the 5 % figure is common practice, not a validated
   cut-off). **Applied:** skipping the differences across a rejected beat earlier; the threshold lowered to 5 %
   on 2026-10-09.
6. **Change the CV note from "3–8 %" to "about 3–13 % (most people 4–8 %)"** and compute it as a weekly CV, as in
   the literature, not over the whole history (Bellenger 2022, Flatt & Esco 2015, Plews 2014; moderate).
7. **Reword the illness warning** (Mishra 2020, Alavi 2022, Altini & Plews 2021, Mason 2022; moderate).
   - Use something like: "HR up and HRV down together: often seen 1–3 days before a cold or infection, but alcohol,
     poor sleep, travel and stress cause the same pattern."
   - Consider requiring 2 consecutive flagged mornings before raising it from a note to a warning, as the published
     detectors use multi-day logic. **Applied 2026-10-09** (wording and the two-morning rule).
   - The specific SD and bpm thresholds have no published source. Label them as heuristics and tune them in
     `hrmon analyze` against `sick` tags.
8. **Require at least 3 of 7 mornings for the 7-day average to count, and at least 14 baseline days before giving
   a verdict** (Plews 2014 compliance, Flatt & Esco 2015; Plews used a 2-week baseline, Javaloyes 4 weeks;
   moderate). The current minimum is 7 days. *Partly applied 2026-10-09:* verdicts still start after 7 baseline
   mornings, but are marked provisional until the baseline holds 14.
9. **Protocol text** (Fagius 1989, Flatt & Esco 2016, Schäfer & Vagedes 2013; weak to moderate).
   - Add "empty your bladder first, or always do the same".
   - Lengthen the settle period from 15 s to about 60 s. **Applied 2026-10-09** (all three points of this item).
   - Mention that the band measures pulse-rate variability, which agrees with ECG at rest but is sensitive to
     arm movement.
10. **Present the 0.65/0.35 score weights and the 75 ± 15 scaling as a design choice**, not part of the published
    method (no source found; informational).
