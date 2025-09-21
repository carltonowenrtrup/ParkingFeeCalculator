# ParkingFeeCalculator — Privacy‑Preserving Parking Fee 🅿️🔒

A minimal dApp + Solidity contract that privately computes a parking fee from **encrypted minutes** using Zama FHEVM. Input minutes are never revealed; only the **final fee (in cents)** is decryptable **by the user** via the Relayer SDK.

---

## ✨ Features

* 🔐 **Encrypted input** — user submits minutes as `externalEuint64` with attestation; contract imports with `FHE.fromExternal`.
* 🧮 **On‑chain FHE math** — rounds **up** to 30‑min blocks *without division* (binary chunk subtraction) and multiplies by `pricePerBlock`.
* 🧑‍💼 **Owner‑set tariff** — `pricePerBlock` (cents) and `maxBlocks` (cap) are configurable by the contract owner.
* 🔑 **User‑only reveal** — fee is stored as `euint64` and granted to the caller; decrypt client‑side with **userDecrypt** (EIP‑712).
* 🔔 **Event handle** — `Quoted(user, feeHandle)` emits a bytes32 handle the UI can immediately decrypt.

---

## 🛠️ Tech Stack

* **Solidity** `^0.8.24`
* **Zama FHEVM** `@fhevm/solidity/lib/FHE.sol` + `SepoliaConfig`
* **Relayer SDK (JS)** `@zama-fhe/relayer-sdk` (CDN)
* **Ethers** v6.15.0 (ESM)
* **Network** Sepolia testnet (`11155111`)
* **Relayer** `https://relayer.testnet.zama.cloud`
* **KMS (Sepolia)** `0x1364cBBf2cDF5032C47d8226a6f6FBD2AFCDacAC`

> Uses only official Zama libraries/SDK (no deprecated packages).

---

## 🚀 Quick Start

### Prerequisites

* Node.js 18+
* MetaMask (Sepolia + test ETH)
* Static dev server **with COOP/COEP** headers (for WASM workers)

### Install & Compile

```bash
npm install
npx hardhat compile
```

### Deploy (Sepolia example)

```bash
npx hardhat run scripts/deploy.ts --network sepolia
```

Update `CONTRACT_ADDRESS` in your `index.html` after deployment.

### Run Frontend

```bash
node server.js
# open http://localhost:3000
```

---

## 🧩 Usage

1. **Connect** MetaMask → auto‑switch to Sepolia if needed.
2. **Quote fee** — enter parking minutes; the SPA encrypts with Relayer `createEncryptedInput`, calls `quote(...)`.
3. **Get handle** — read `Quoted` event or call `getMyFeeHandle()`.
4. **Decrypt privately** — use Relayer `userDecrypt` (EIP‑712 signing) to reveal the **fee in cents** client‑side.

> No public decryption is exposed; only the submitting user (or addresses granted in code) can decrypt the result.

---

## 🔌 Frontend Flow (Relayer SDK)

* **Init**: `await initSDK(); const relayer = await createInstance({...SepoliaConfig, relayerUrl})`.
* **Encrypt**: `const buf = relayer.createEncryptedInput(CONTRACT_ADDRESS, user); buf.add64(minutes); const { handles, inputProof } = await buf.encrypt();`
* **Call**: `await contract.quote(handles[0], inputProof)` → emits `Quoted(user, feeHandle)`.
* **Decrypt**: ephemeral keypair → EIP‑712 signature → `relayer.userDecrypt([{handle: feeHandle, contractAddress: CONTRACT_ADDRESS}], ...)` → plaintext cents for display.

---

## 🧠 Smart Contract Overview

**File:** `contracts/ParkingFeeCalculator.sol`

* **State**

  * `uint64 public constant BLOCK_MINUTES = 30` — block size for rounding.
  * `uint64 public pricePerBlock` — tariff per block (cents).
  * `uint16 public maxBlocks` — upper cap on billable blocks.
  * `address public owner` — admin for tariff updates.
  * `mapping(address => euint64) _lastFee` — encrypted last fee per user.

* **Key FHE flow**

  1. Import minutes: `euint64 rem = FHE.fromExternal(minutesExt, proof);`
  2. Compute `blocks = ceil(minutes / 30)` **without division** using binary chunk subtraction over `30 * 2^k` with `FHE.gt`, `FHE.sub`, `FHE.select`.
  3. Cap to `maxBlocks` via `FHE.select`.
  4. Compute fee: `fee = FHE.mul(blocks, FHE.asEuint64(pricePerBlock));`
  5. ACL: `FHE.allowThis(fee); FHE.allow(fee, msg.sender);` → store & emit handle.

> Note: Avoids FHE ops in `view` functions; uses euint64 arithmetic ops supported by FHEVM.

### Public API

```solidity
function version() external pure returns (string memory);
function pricePerBlock() external view returns (uint64);
function maxBlocks() external view returns (uint16);
function owner() external view returns (address);
function setPricePerBlock(uint64 newPrice) external;
function setMaxBlocks(uint16 newMax) external;
function getMyFeeHandle() external view returns (bytes32);
function quote(externalEuint64 minutesExt, bytes calldata proof) external returns (bytes32 feeHandle);
```

### Events

* `Quoted(address indexed user, bytes32 feeHandle)` — emitted on each quote.

---

## 🧪 Test & Dev Tips

* Try small inputs first: `minutes = 0, 1, 29, 30, 31, 59, 60` to verify rounding.
* If `userDecrypt` returns no value for the handle:

  * Ensure you signed a fresh EIP‑712 token including the contract address.
  * The handle matches (case‑insensitive) the key in the decrypt output.
  * You are the caller who received `FHE.allow(fee, msg.sender)`.
* `maxBlocks` caps the fee (e.g., `96 → 48h`).
* COOP/COEP headers are **required** for Relayer WASM workers.

---

## 📁 Project Structure

```bash
.
├─ index.html                         # SPA (frontend)
├─ contracts/
│  └─ ParkingFeeCalculator.sol       # FHEVM smart contract
├─ server.js                          # Dev server with COOP/COEP headers
├─ scripts/, tasks/, test/            # Optional Hardhat helpers
├─ package.json
└─ README.md
```

---

## 🔒 Security Notes

* Minutes and fee remain encrypted on chain; plaintext is revealed **only** to authorized users client‑side.
* No public decryption is used in this contract.
* Demo code; not audited for production. Do not commit private keys/mnemonics.

---

## 🔧 Frontend Constants (in `index.html`)

* `CONTRACT_ADDRESS` — deployed `ParkingFeeCalculator`
* `RELAYER_URL` — e.g., `https://relayer.testnet.zama.cloud`
* `KMS_ADDRESS` — Sepolia KMS (`0x1364...cAC`)
* Chain ID enforced to **Sepolia (11155111)**

---

## 📚 References

* Zama **FHEVM Solidity** Library
* Zama **Relayer SDK** Guides (EIP‑712 `userDecrypt`)
* Zama Protocol & Whitepaper
* Ethers v6 (ESM)

---

## 📄 License

MIT — see `LICENSE`.

