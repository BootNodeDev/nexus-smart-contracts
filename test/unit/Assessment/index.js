const { takeSnapshot, revertToSnapshot } = require('../utils').evm;
const { setup } = require('./setup');

describe('Assessment', function () {
  before(setup);

  beforeEach(async function () {
    this.snapshotId = await takeSnapshot();
  });

  afterEach(async function () {
    await revertToSnapshot(this.snapshotId);
  });

  require('./stake');
  require('./unstake');
  require('./getRewards');
  require('./getPoll');
  require('./getAssessmentsCount');
  require('./getVoteCountOfAssessor');
  require('./withdrawRewards');
  require('./startAssessment');
  require('./castVote');
  require('./submitFraud');
  require('./processFraud');
  require('./updateUintParameters');
});
