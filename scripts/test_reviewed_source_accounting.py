import copy
import unittest

from verify_icebox_physical_delivery import source_accounting


class ReviewedSourceAccountingTests(unittest.TestCase):
    def setUp(self):
        self.inventory = dict(requiredSourceObjects=[0,1], inventory=[
            dict(sourceObject=0, path='prop', status='excluded', reason='Pawn nonblocking'),
            dict(sourceObject=1, path='floor', status='unresolved', reason='Declared blocking')],
            collisionBodies=[dict(collision='ceiling')])
        self.source = dict(sourceRows=[dict(sourceObject=1, status='no-clear-standing-domain'),
            dict(sourceCollision='ceiling', status='standing-domains-measured', domains=1)],
            domains=[dict(id='reviewed-prop', sourceObject=0, eligibilityBasis='Dara gameplay review')],
            gameplayReviewApplicationSha256='review', sourceExclusionsApplicationSha256='exclusion',
            unresolvedInfluencingCollision=[])
        self.exclusions = [dict(id='ceiling-top', sourceCollision='ceiling')]
        self.comparison = dict(rows=[dict(id='reviewed-prop', side=side, sourceObject=0,
            status='passed', defaultStatus='passed', applicableAreaSvg=1.) for side in ['attack','defense']])

    def test_gameplay_admission_and_ceiling_exclusion_keep_physical_decisions(self):
        result, dispositions = source_accounting(self.inventory, self.source, self.comparison, self.exclusions)
        self.assertTrue(result['complete'])
        self.assertEqual(dispositions[0]['status'], 'represented')
        self.assertEqual(dispositions[0]['physicalCollisionDecision']['status'], 'excluded')
        self.assertEqual(dispositions[0]['physicalCollisionDecision']['reason'], 'Pawn nonblocking')
        self.assertEqual(result['collisionBodyDecisions'][0]['standingStatus'], 'excluded')
        self.assertEqual(result['collisionBodyDecisions'][0]['physicalMeasurement']['status'], 'standing-domains-measured')
        self.assertFalse(source_accounting(self.inventory, self.source, self.comparison)[0]['complete'])

    def test_missing_comparison_or_missing_measurement_prevents_completion(self):
        incomplete = copy.deepcopy(self.comparison)
        incomplete['rows'].pop()
        self.assertFalse(source_accounting(self.inventory, self.source, incomplete, self.exclusions)[0]['complete'])
        source = copy.deepcopy(self.source)
        source['sourceRows'] = source['sourceRows'][1:]
        self.assertFalse(source_accounting(self.inventory, source, self.comparison, self.exclusions)[0]['complete'])
        source = copy.deepcopy(self.source)
        source['domains'][0].pop('eligibilityBasis')
        self.assertFalse(source_accounting(self.inventory, source, self.comparison, self.exclusions)[0]['complete'])


if __name__ == '__main__':
    unittest.main()
