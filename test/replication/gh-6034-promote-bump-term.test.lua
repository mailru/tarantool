test_run = require('test_run').new()

-- gh-6034: test that every box.ctl.promote() bumps
-- the instance's term. Even when elections are disabled. Even for consequent
-- promotes on the same instance.
election_mode = box.cfg.election_mode
box.cfg{election_mode='off'}

term = box.info.election.term
box.ctl.promote()
assert(box.info.election.term == term + 1)
box.ctl.promote()
assert(box.info.election.term == term + 2)

-- Cleanup.
box.ctl.demote()
box.cfg{election_mode=election_mode}
