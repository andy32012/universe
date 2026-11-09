import unittest
from tools.planet_catalog import build

class CatalogTests(unittest.TestCase):
    def test_filter_deduplicate_and_label(self):
        good = {"pl_name":"Example b","hostname":"Example","pl_rade":1.2,"pl_orbper":12,
                "sy_dist":5,"ra":30,"dec":-20,"pl_bmasse":2.1,"pl_orbsmax":0.1}
        bad = dict(good,pl_name="Missing period",pl_orbper=None)
        result = build([bad, good, good], 100)
        self.assertEqual(result["count"], 1)
        p = result["planets"][0]
        self.assertEqual(p["surface"], "illustrative")
        self.assertEqual(p["orbit_orientation"], "illustrative")
    def test_invalid_coordinates(self):
        row = {"pl_name":"Bad b","hostname":"Bad","pl_rade":1,"pl_orbper":3,
               "sy_dist":10,"ra":400,"dec":0}
        self.assertEqual(build([row])["count"], 0)

if __name__ == "__main__":
    unittest.main()
