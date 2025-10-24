# MyTube Product Requirements

## Vision
Create a private, offline-first video journal tailored for kids on iPad. MyTube empowers children to capture memories, replay their favorites, and remix creations while giving parents tight control over access, storage, and curation.

## Target Users
- **Primary:** Kids aged 6–12 who want to record and revisit personal videos without social sharing.
- **Secondary:** Parents/guardians managing content safety, storage limits, and access permissions.

## Success Metrics
- Daily active kid sessions ≥ 2 per device within 30 days of install.
- ≥ 90% of videos saved without export/import failures.
- Parent Zone PIN adoption at 100% for active households.
- Zero crash rate during 7-day TestFlight soak.

## Experience Pillars
- **Privacy-first:** No external sync or network calls.
- **Kid-friendly flow:** Minimal text, large touch targets, accessible themes.
- **Creative flexibility:** Filters, stickers, and music overlays at launch.
- **Smart discovery:** Ranking engine that adapts to engagement without parental tuning.

## Task Tracker
- [ ] Establish Core Data schema (Profile, Video, Feedback, RankingState) with migrations.
- [ ] Implement persistence utilities (`PersistenceController`, storage paths, file protection).
- [ ] Build dummy seed data for Home Feed development.
- [ ] Implement Home Feed UI (shelves, hero card, ranking integration).
- [ ] Capture pipeline (AVCaptureSession setup, recording controls, save to AppSupport).
- [ ] Thumbnail generation service with background processing.
- [ ] Player module (AVPlayer wrapper, telemetry logging, feedback entities).
- [ ] Ranking engine algorithm (scoring, diversity penalty, explore mode).
- [ ] Editor feature (trim UI, filters, overlays, music mix, export workflow).
- [ ] Parent Zone (PIN setup/verify, storage meter, bulk management, Calm mode).
- [ ] On-device ML tagging optional module (Vision, SoundAnalysis hooks).
- [ ] Accessibility & theming (Dynamic Type, color contrast, multi-profile themes).
- [ ] QA automation (unit, UI tests, coverage thresholds, performance benchmarks).
- [ ] Compliance review (Kids Category checklist, privacy statements, consent flows).

## Milestone Outline
| Sprint | Duration | Focus |
| --- | --- | --- |
| 1 | Weeks 1–3 | Core Data stack, VideoLibrary, Feed UI, playback telemetry |
| 2 | Weeks 4–6 | Editor end-to-end, export pipeline, ranking engine v1 |
| 3 | Weeks 7–9 | Parent Zone, storage tooling, accessibility, QA regression |

## Open Questions
- Preferred approach for Core Data migrations on first release?
- Do we preload sample stickers/music or ship a download-on-demand flow?
- Should Calm mode surface in kid UI or remain parent-only toggle?
