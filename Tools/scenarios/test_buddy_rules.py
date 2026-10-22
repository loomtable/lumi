#!/usr/bin/env python3
"""Unit tests for buddy_rules (run: python3 -I Tools/scenarios/test_buddy_rules.py)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import buddy_rules as r  # noqa: E402


class Headline(unittest.TestCase):
    def check(self, say, words):
        self.assertEqual(r.headline_words(say), words, r.first_sentence(say))

    def test_milliseconds_end_a_sentence_but_ms_title_does_not(self):
        self.assertEqual(r.headline_words("Use rg: it's the fastest, at 38 ms. It's 1.6 times faster than git grep."), 8)
        self.assertEqual(r.first_sentence("Ask Ms. Lee about it. Then wait."), "Ask Ms. Lee about it.")
        self.assertEqual(r.first_sentence("It took 38 ms. and then stopped."), "It took 38 ms. and then stopped.")

    def test_decimals_and_files_stay_whole(self):
        self.check("Revenue hit 3.5 million in Q3, up from 3.1 million.", 10)
        self.check("Open index.ts and rename the export. Then rebuild.", 6)

    def test_abbreviations(self):
        self.check("Use a fixture, e.g. the one in tests. Then run it.", 8)
        self.check("Dr. Ortiz signed it. Nobody else did.", 4)
        self.check("The call is at 5 p.m. tomorrow. Bring notes.", 7)
        self.check("The call ends at 5 p.m. Then the review starts.", 6)
        self.check("Pack shirts, socks, etc. Then leave.", 4)
        self.check("Pack shirts, socks, etc. and go.", 6)

    def test_acronyms_are_one_word(self):
        self.check("The I.R.S. sent a letter about it. Pay soon.", 7)
        self.check("She has a Ph.D. in physics. It shows.", 6)
        self.check("Prices in the U.S. Then Europe.", 4)

    def test_initials_and_single_letters(self):
        self.check("It was written by J. R. R. Tolkien in 1954. Read it.", 10)
        self.check("Ask J. Smith about the budget. Today.", 6)
        self.check("Go with Plan A. It is cheaper.", 4)
        self.check("Run npm i. Then start the server.", 3)

    def test_other_endings(self):
        self.check("It's \"done.\" Next sentence.", 2)
        self.check("Is it ready? Almost.", 3)
        self.check("No punctuation at all", 4)
        self.check("One. Two three.", 1)


class Blocks(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(r.parse_block('x\n```Buddy\n{"say": "Hi.", "shape": "Chip"}\n```\n')["say"], "Hi.")
        self.assertIsNone(r.parse_block('```buddy\n{"shape": "chip"}\n```'))
        self.assertIsNone(r.parse_block('```buddy\n{"say": "x", "card_html": 3}\n```'))
        self.assertIsNone(r.parse_block("no block"))

    def test_lane_and_shape_ignore_case(self):
        self.assertEqual(r.lane({"say": "x", "handoff": "Deep"}), "deep")
        self.assertEqual(r.lane({"say": "x", "handoff": None}), "quick")
        self.assertEqual(r.lane({"say": "x", "handoff": "nope"}), "quick")
        self.assertEqual(r.shape({"say": "x", "shape": "RICH"}), "rich")


class Router(unittest.TestCase):
    def test_overrides(self):
        self.assertEqual(r.start("Research quantitative tightening"), "research")
        self.assertEqual(r.start("researchers say it's wrong"), "quick")
        self.assertEqual(r.start("Quick answer: what's this?"), "quick-noh")
        self.assertEqual(r.start("Go deeper."), "deeper")
        self.assertEqual(r.start("go deep, why is it empty"), "deep")
        self.assertEqual(r.start("Think hard about this"), "deep")
        self.assertEqual(r.start("«Research» this"), "research")
        self.assertEqual(r.start("what is this"), "quick")


if __name__ == "__main__":
    unittest.main()
