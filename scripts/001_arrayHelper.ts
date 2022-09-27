import { ethers } from "hardhat";

export default async function () {
  const ArrayHelper = await ethers.getContractFactory("ArrayHelper")
  const libraryAddr = '0x650A18C8245e0336784725738789712eFD5f6B59'
  let arrayHelper
  if (!libraryAddr) {
    arrayHelper = await ArrayHelper.deploy()
    await arrayHelper.deployed()
  }
  else
    arrayHelper = await ArrayHelper.attach(libraryAddr)
  console.log("ArrayHelper deployed to:", arrayHelper.address)

  return arrayHelper
}
