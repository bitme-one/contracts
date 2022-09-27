import { ethers } from "hardhat";
import { BaiController, MyProxy } from "../typechain";
import helperDeploy from './001_arrayHelper'

// const WBTC = { optimism: '0x68f180fcCe6836688e9084f035309E29Bf0A2095' }
// const USDC = { optimism: '0x68f180fcCe6836688e9084f035309E29Bf0A2095' }
// const ROUTER = { optimism: '0xE592427A0AEce92De3Edee1F18E0157C05861564' }
// const QUOTER = { optimism: '0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6' }

// await bai.initialize(
//   admin.address,
//   WBTC,
//   USDC,
//   ROUTER,
//   QUOTER
// )

async function main() {
  const [deployer, admin] = await ethers.getSigners();
  console.log("deployer:", deployer.address);
  console.log("admin:", admin.address);

  const Proxy = await ethers.getContractFactory("MyProxy", { signer: deployer });
  const proxyAddr = '0x92c22e13B638c81227ae9316980ba649216EeD1A'
  const proxy = (await Proxy.attach(proxyAddr)) as MyProxy

  const implAddr = '0x' + (await ethers.provider.getStorageAt(proxyAddr, '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc')).substr(-40)
  console.log(`Proxy deployed to: ${proxyAddr} with impl: ${implAddr}`)

  const arrayHelper = await helperDeploy()
  const BAI = await ethers.getContractFactory("BaiController", {
    signer: admin,
    libraries: {
      ArrayHelper: arrayHelper.address
    }
  })

  const reDeployImpl = false
  let bai: BaiController
  if (reDeployImpl) {
    bai = (await BAI.deploy()) as BaiController //unsafeAllowLinkedLibraries: true
    await bai.deployed()
    console.log(`BAIImpl deployed to: ${bai.address}.`)
    const tx = await proxy.upgradeTo(bai.address)
    await tx.wait()
    console.log(`BAIProxy upgraded to: ${bai.address}.`)
  }

  bai = (await BAI.attach(proxyAddr)) as BaiController
  console.log(`BAI deployed to: ${bai.address}.`)

  const needUpgrade = false
  if (needUpgrade) {
    const tx = await bai.upgradeOnce()
    await tx.wait()
  }

  const totalInvestors = await bai.totalInvestors()
  console.log(`Total investors: ${totalInvestors}`)

  return
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });