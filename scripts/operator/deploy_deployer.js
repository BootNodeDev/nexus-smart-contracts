const { ethers } = require('hardhat');

const main = async () => {
  console.log('deploying deployer');
  const args = [];
  const deployerContract = await (await ethers.getContractFactory('Deployer')).deploy(...args);
  await deployerContract.deployTransaction.wait();
  console.log(`Deployer: ${deployerContract.address}`);
};

main()
  .then(() => process.exit())
  .catch(e => {
    console.error(e);
    process.exit(1);
  });
