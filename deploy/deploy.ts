// deploy/deploy.ts
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network, ethers } = hre;
  const { deploy, read, log, getArtifact } = deployments;
  const { deployer } = await getNamedAccounts();

  const envFQN = process.env.FQN?.trim();
  const waitConfirmations = Number(process.env.WAIT_CONFIRMATIONS ?? 1);

  // ── 0) Санити-чек сети (Sepolia = 11155111)
  try {
    const chainId = await hre.getChainId();
    if (chainId !== "11155111") {
      log(
        `⚠️  Warning: current chainId=${chainId} (${network.name}). Contract uses SepoliaConfig; make sure this is intended.`,
      );
    }
  } catch {}

  // ── 1) Ищем артефакт контракта
  const candidates: string[] = [
    ...(envFQN ? [envFQN] : []),
    "ParkingFeeCalculator",
    "contracts/ParkingFeeCalculator.sol:ParkingFeeCalculator",
    "contracts/parking/ParkingFeeCalculator.sol:ParkingFeeCalculator",
    "src/ParkingFeeCalculator.sol:ParkingFeeCalculator",
  ];

  let contractId: string | null = null;
  for (const c of candidates) {
    try {
      await getArtifact(c);
      contractId = c;
      break;
    } catch {}
  }
  if (!contractId) {
    throw new Error(
      `Cannot find artifact for ParkingFeeCalculator. Try one of: ${candidates.join(", ")}. Make sure the contract is compiled.`,
    );
  }

  // ── 2) Параметры конструктора из ENV
  // Цена за 30 минут в центах (uint64)
  const PRICE_RAW = process.env.PRICE_PER_BLOCK ?? "200"; // 2.00$
  // Макс. число 30-минутных блоков (uint16)
  const MAX_RAW = process.env.MAX_BLOCKS ?? "96"; // 48 часов

  let price: bigint;
  try {
    price = BigInt(PRICE_RAW);
  } catch {
    throw new Error(`PRICE_PER_BLOCK must be uint64, got: ${PRICE_RAW}`);
  }
  const U64_MAX = (1n << 64n) - 1n;
  if (price <= 0n || price > U64_MAX) {
    throw new Error(`PRICE_PER_BLOCK must be in [1..2^64-1], got: ${PRICE_RAW}`);
  }

  const maxBlocksNum = Number(MAX_RAW);
  if (!Number.isInteger(maxBlocksNum) || maxBlocksNum < 1 || maxBlocksNum > 65535) {
    throw new Error(`MAX_BLOCKS must be integer in [1..65535], got: ${MAX_RAW}`);
  }

  log(
    `🅿️  Deploying ParkingFeeCalculator with pricePerBlock=${price} (cents), maxBlocks=${maxBlocksNum}… (artifact: ${contractId})`,
  );

  // ── 3) Деплой
  const d = await deploy("ParkingFeeCalculator", {
    from: deployer,
    contract: contractId,
    args: [price.toString(), maxBlocksNum], // uint64, uint16
    log: true,
    waitConfirmations,
  });

  // ── 4) Быстрая проверка и вывод версии/параметров
  try {
    const ver: string = await read("ParkingFeeCalculator", "version");
    const p: bigint = await read("ParkingFeeCalculator", "pricePerBlock");
    const m: number = await read("ParkingFeeCalculator", "maxBlocks");
    log(
      `✅ Deployed at ${d.address} on ${network.name} (version: ${ver}, pricePerBlock=${p.toString()}, maxBlocks=${m})`,
    );
  } catch {
    log(`✅ Deployed at ${d.address} on ${network.name}`);
  }

  console.log(`ParkingFeeCalculator contract: ${d.address}`);
};

export default func;
func.id = "deploy_parking_fee_calculator";
func.tags = ["ParkingFeeCalculator"];
