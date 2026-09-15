"""Record the completed root visual audit separately from candidate build gates."""
import json
from declare_split_legacy105_connected_region import REV, sha


def main():
    images = [
        *[f'105-v30-baseline-evidence-v1/page-{i:02d}.png' for i in range(1, 8)],
        *[f'105-v30-v31-evidence-v1/sheets/page-{i:02d}.png' for i in range(1, 8)],
        *[f'pipe-generator-v30-v31-evidence-v1/sheets/page-{i:02d}.png' for i in range(1, 4)],
        *[f'frozen-split-app-v30-v31-contact-review/{s}-changed-wall-native8x.png'
          for s in ['attack', 'defense']],
        *[f'frozen-split-app-scene-v31-run1/split-{s}-full1920.png'
          for s in ['attack', 'defense']],
    ]
    candidate = 'split-wall-family-normalized-candidate-v31-precise-v1'
    ledger = REV / 'root-v31-personal-render-review.json'
    data = dict(
        candidate=candidate,
        candidateSha256='0aa18743a5bda73e484f6cee7280a9f1e84564c9f448073e17fe9261affde5d2',
        personallyViewed=[dict(path=p, sha256=sha(REV / p)) for p in images],
        acceptedScope=[
            'Reviewed 105 corridor contacts and corners reach the SVG stroke on both sides.',
            'Generator paper notch removed on both sides; pipe opening and cover controls retain prior behavior.',
            'Frozen ten-agent scene preserves source queries. All 1278 changed native8x pixels per side are confined to the reviewed corridor contact crop.',
        ],
        supportingGates=[candidate + '/independent-profile-review.json',
                         'frozen-split-app-v30-v31-contact-review/report.json'],
        held=[
            'Current candidate uses provisional ground field. This is not acceptance of ramp or standing-target visibility.',
            'Original horizontal source ray lower-3-071 disagrees at pipe4860. Final descending head-target ray requires separate floor policy evaluation.',
            'Vent room, A-site building and sewer108 connected boundaries are still under source review.',
            'Other maps, production integration, whole-frame performance and data size remain unfinished.',
        ],
        productionPromotion=False,
    )
    ledger.write_text(json.dumps(data, indent=2) + '\n')
    checkpoint = REV / 'resume-wall-contact-priority-v29.json'
    state = json.loads(checkpoint.read_text())
    state['rootV31VisualReview'] = dict(path=str(ledger), sha256=sha(ledger), productionPromotion=False)
    state['v31PreciseBuild'] = dict(candidate=candidate,
        stage='split-connected-contact-stage-v31-precise-v1',
        failedStagePreserved='split-connected-contact-stage-v31',
        numericalFix='Use already-proved rational source weights instead of re-inverting rounded coordinates in thin cells. No geometry tolerance changed.',
        rootRegressionTests=20, frozenRegressionTests=21,
        sourceGate='Passed source partition, continuous XY, original Z and UV preservation checks.')
    state['bin7852Latest']['pending'] = 'Cumulative V31 source/UV gate passed; root both-side pixel review accepted within ledger scope.'
    state['preparedShadowExperiment'] = dict(report='prepared-shadow-reuse-review-v1/report.json',
        bitwiseEquivalentWorkloads=23, promoted=False,
        finding='No consistent timing improvement. Keep experiment out of app.')
    state['activeAgentTasks'] = dict(
        paper_attachment='Connected sewer108 building and finite doorway source review.',
        vent_corner='Vent V5 held; remaining mounted wall members and complete172 termination.',
        asite_corner='Building17..25 V3 held; mounted details and finite doorway profiles.')
    state['rootSewerSourceReview'] = dict(
        personallyViewed=['split-sewer108-connected-source-review-v1',
                          'split-sewer108-connected-source-review-v2',
                          'split-sewer108-connected-source-review-v3'],
        status='Source sections only. No field declared or correction accepted.')
    state['activeRootSessions'] = []
    state['rootV31StraightPixelCheck'] = dict(
        path='split105-native-pixel-contact-review-v1/report.json',
        findings='577 actual raster profiles on source-confirmed straight wall contacts, 2x and8x, both sides. Zero blank runs and zero coverage-contact failures. V30 also passes these straight profiles. Forty corner/range/unmatched side cases are explicitly excluded and separately reviewed.',
        noWholeMapClaim=True)
    state['rootVentV6SourceReview'] = dict(
        declaration='split-vent-room-finite-field-experiment-v6/sealed-held-region-declaration.json',
        gate='split-vent-room-finite-field-experiment-v6/independent-room-gate.json',
        personallyViewedSource3dObjects=[4776,7814,7789],
        personallyViewedAll18Native8xImages='split-vent-room-receiver-contacts-native8x-v4',
        acceptedScope='Bounded room source membership and contact alignment accepted for staging. Actual cones require a cumulative bake. Upper172 remains held for separate169..172 continuation.',
        productionPromotion=False)
    state['rootSewerV3ProposalReview'] = dict(
        personallyViewed=['split-sewer108-connected-source-review-v4/original-height-six-sections.png',
            'split-sewer108-full-assembly-review-v1/full-source-four-views.png',
            *[f'split-sewer108-connected-proposal-v3/{name}-source-height-preview.png'
              for name in ['paired-opening','rear-transition','whole']]],
        finding='Outer diagonal/notches align; finite arch intrusions/header closure and deeper rear grate retained. Await exact partition/interface/source rays and both-side native8x overlays.',
        productionPromotion=False)
    state['rootNativeReceiverCompaction'] = dict(
        path='all-map-native-nav-receivers-v1/report.json',
        scope='All13 coarse original navigation meshes compacted with per-plane footprint/height gates and source-triangle provenance. Separate levels retained. Not rendered-floor refinement or final SVG receiver domain.',
        unitTests=2, productionPromotion=False)
    state['rootSourceFloorCandidateAudit'] = dict(
        candidates='all-map-nav-source-floor-candidates-v1/report.json',
        columns=[f'{name}-nav-source-floor-clearance-v1/report.json' for name in
            'abyss ascent bind breeze corrode fracture haven icebox lotus pearl split summit sunset'.split()],
        iceboxCorrected='icebox-nav-source-floor-clearance-v2/report.json',
        iceboxIndependentReplay='icebox-nav-source-floor-clearance-v2/independent-exclusion-replay.json',
        originalCompilerSnapshot='receiver-floor-clearance-compiler-v1/manifest.json',
        finding='At frozen native-nav interior samples, upward optical center-column rays remove all candidate height disagreements above1mm across13 maps. Missing support and blocked columns remain unresolved. This is not Pawn capsule/collision certification.',
        iceboxFinding='Exact24 previously-audited Wind effect face exclusions remove1538 Wind first hits; one retains another obstruction. All4913 unrelated candidate columns exactly unchanged. No production pack changed.',
        productionPromotion=False)
    state['rootStandingTargetGrid'] = dict(
        path='split-standing-target-grid-v1/report.json',
        personallyViewedAllThreeAgentPlots=True,
        finding='FrozenV29 Clove804 andViper762 qualified point outcomes unchanged; Iso739 unchanged and1 newly clear.415 cone-contained points lack qualified support and are omitted. This is not evidence that changing height policy alone repairs the annotated wall gaps.',
        productionPromotion=False)
    checkpoint.write_text(json.dumps(state, indent=2) + '\n')
    print(ledger)


if __name__ == '__main__':
    main()
