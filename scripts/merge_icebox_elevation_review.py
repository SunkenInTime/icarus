"""Combine the reviewed Icebox corrections without changing other map assets."""
import copy
import json


from audit_svg_source_height_associations import REV


def main():
    mid = REV / 'icebox-mid-elevation-audit-v2'
    site = REV / 'icebox-site-elevation-audit-v2'
    output = REV / 'icebox-elevation-reviewed-v2'
    output.mkdir(exist_ok=True)
    decisions = json.loads((mid / 'icebox-mid-decisions.json').read_text())
    patch = json.loads((site / 'proposed-patch.json').read_text())
    names = {
        'icebox-b-site-upper-floor': 'B Site upper floor',
        'icebox-b-shipping-d18-top': 'B approach container top',
        'icebox-a-stacked-interior-floor': 'A defender nest floor',
        'icebox-a-stacked-b-interior-floor': 'A attacker nest floor',
        'icebox-a-warehouse-boost-top': 'A Site boost platform',
        'icebox-a-boost-pipes-top': 'A Site pipes',
    }
    added = []
    for support in patch['addSupports']:
        if support['id'] not in names:
            continue
        support = copy.deepcopy(support)
        support['label'] = names[support['id']]
        decisions['supports'].append(support)
        added.append(support)
    removed = {s['id'] for s in patch['removeSupports']}
    decisions['supports'] = [s for s in decisions['supports'] if s['id'] not in removed]
    decisions.setdefault('rejectedSupports', []).extend(patch['removeSupports'])
    rows = decisions['walls']
    by_id = {w['wallId']: w for w in rows}
    for change in patch['wallPatches']:
        w = by_id[change['wallId']]
        if change.get('operation') == 'prepend-part-before-existing-parts':
            w['parts'].insert(0, change['part'])
        else:
            w.pop('parts', None)
            w.pop('bandsAboveFloor', None)
            w.update(change)

    # The existing primary field contains the lower floor beneath each site
    # surface. Keep it; these are explicit upper choices, not replacement ground.
    gp = output / 'icebox-ground.json.gz'
    gp.write_bytes((mid / 'icebox-ground.json.gz').read_bytes())
    decisions.update(groundModel=str(gp), groundReviewStatus='reviewed')
    decisions['siteReview'] = dict(patch=str(site / 'proposed-patch.json'),
        addedSupportIds=[s['id'] for s in added], removedSupportIds=sorted(removed),
        excludedProposal='B balcony 3917 lacks detailed navigation corroboration; not promoted in this pass.')
    path = output / 'icebox-decisions.json'
    path.write_text(json.dumps(decisions, separators=(',', ':')))
    print(json.dumps(dict(decisions=str(path), supports=len(decisions['supports']))))


if __name__ == '__main__':
    main()
