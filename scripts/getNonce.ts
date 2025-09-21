import { ethers } from "hardhat";

async function main() {
  const [signer] = await ethers.getSigners();
  const nonce = await ethers.provider.getTransactionCount(signer.address);
  console.log("Current nonce:", nonce);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
