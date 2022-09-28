import { ethers } from "hardhat";
import { ArrayHelper } from "../typechain";

export default async function () {
  const ContractFactory = await ethers.getContractFactory("ArrayHelper")
  const libraryAddr = '0x650A18C8245e0336784725738789712eFD5f6B59'
  let arrayHelper
  if (!libraryAddr) {
    arrayHelper = (await ContractFactory.deploy()) as ArrayHelper
    await arrayHelper.deployed()
  }
  else
    arrayHelper = (await ContractFactory.attach(libraryAddr)) as ArrayHelper
  console.log("ArrayHelper deployed to:", arrayHelper.address)

  return arrayHelper
}
