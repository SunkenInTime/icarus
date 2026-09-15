"""Save the root review state without modifying frozen source evidence."""
import json
from pathlib import Path
from declare_split_legacy105_connected_region import REV, sha


def main():
    ledger=REV/'root-v30-personal-render-review.json'
    if not ledger.exists():
        ledger.write_text(json.dumps(dict(
            candidate='split-wall-family-normalized-candidate-v30-cached-v1',
            candidateSha256='52dde0032296ffada5f1a003a8280e5a0ca4d693835924acef34fd9e0089cbf6',
            personallyViewed=['plank-v29-v30-evidence/sheets/page-01.png',
                'pipe-generator-v29-v30-evidence/sheets/page-01.png',
                'pipe-generator-v29-v30-evidence/sheets/page-02.png',
                'pipe-generator-v29-v30-evidence/sheets/page-03.png',
                'pipe-generator-v29-v30-evidence/attack-generator-generator-curved-front-focus-native8x.png',
                'pipe-generator-v29-v30-evidence/defense-generator-generator-curved-front-focus-native8x.png',
                'frozen-split-app-scene-v30-run1/split-attack-full1920.png',
                'frozen-split-app-scene-v30-run1/split-defense-full1920.png',
                *[f'frozen-split-app-v29-v30-review/{side}-isolated-{agent}-native8x.png' for side in ['attack','defense'] for agent in ['clove','viper']]],
            acceptedScope='The reviewed pipe contacts and standing plank notch meet the SVG on both sides. Above-plank and opening controls are unchanged.',
            held='Generator curved-front step still contains unbound paper1640. Source attachment correction pending. Remaining corner and ramp policy changes are unfinished.',
            caveats=['Forty side cases, not every Split point or every map.',
                'Current packs still use provisional ground field.',
                'Full-scene frame0 has no B-site generator agent; dedicated generator poses cover that region.'],
            productionPromotion=False),indent=2)+'\n')
    path=REV/'resume-wall-contact-priority-v29.json'
    data=json.loads(path.read_text())
    data['rootV30VisualReview']={'path':str(ledger),'sha256':sha(ledger),'productionPromotion':False}
    data['bin7852Latest']={
        'attachment':'split-wall-bin7852-attachment-proposal-v1',
        'sourceImagePersonallyViewed':True,
        'proposal':'split-legacy105-connected-region-proposal-v7/combined-declarations.json',
        'proposalSha256':'e52553ad96b84e16bd0750c0e134285d4f827879a4706eb5806e947d0fb18c00',
        'finiteProof':'split-wall-bin7852-finite-review-v1/report.json',
        'frozenQueries':'split-wall-bin7852-finite-review-v1/frozen-standing-controls.json',
        'findings':'Complete904-face bin intersects literal7899 wall plane on188 faces and protrudes13.16mm. Unchanged200105 field maps all2008 fragments on or behind exactX279.074. Every source partition passed; Z error8.88e-16m. Three premature bin hits removed,84 other top and108 lower contacts unchanged.',
        'pending':'Cumulative candidate source/UV gates and actual both-side rendered contacts.'}
    data['cachePromotionLatest']={
        'manifest':'v30-cache-workspace-promotion-v1',
        'checkpointHelperNowBound':True,
        'checkpointTests':3,
        'note':'Offline owner cache promoted. Root added finite_edge_owners.py to checkpoint generator hashes, including changed-hash resume rejection. Frozen V30 compiler remains unchanged.'}
    data['activeRootSessions']=[]
    data['activeAgentTasks']={'paper_attachment':'1640 attachment plus curl band to exact generator cubic',
        'vent_corner':'Connected173/174 original standing source geometry',
        'asite_corner':'17/18/19 shared source corner and attached details'}
    path.write_text(json.dumps(data,indent=2)+'\n')
    print('Saved latest additive checkpoint and root personal render review.')


if __name__=='__main__':main()
