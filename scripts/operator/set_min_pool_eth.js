const { ethers } = require('hardhat');
const addresses = require('./addresses.json');

const hex = string => '0x' + Buffer.from(string).toString('hex');

const minPoolEth = '0.1';

const main = async () => {
  console.log('setting minPoolEth');
  const poolContract = await ethers.getContractAt('Pool', addresses.pool);
  await (await poolContract.updateUintParameters(hex('MIN_ETH'.padEnd(8, '\0')), ethers.utils.parseEther(minPoolEth))).wait();
  console.log('done');
};
main()
  .then(() => process.exit())
  .catch(e => {
    console.error(e);
    process.exit(1);
  });
